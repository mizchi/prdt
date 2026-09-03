///|
/// Runtime replica: a replicated domain object plus an outbox and a durable
/// checkpoint store. A replica holding a `ClosureAuthority` can close ticks.
pub struct Replica[S, C, E, R] {
  id : String
  protocol : @prdt.Protocol[S, C, E, R]
  store : &CheckpointStore
  authority : @prdt.ClosureAuthority[C]?
  late_policy : LateCommandPolicy
  mut object : @prdt.ReplicatedDomain[S, C, E, R]
  mut outbox : Array[@prdt.Delta[C]]
  /// Own late command id -> id of the re-issued command.
  mut moved : Map[String, String]
  /// Re-issued command id -> how many times its lineage has been moved.
  mut move_depth : Map[String, Int]
}

///|
/// What a replica does with its own command once the tick it targeted closed
/// without it. `RejectAsLate` keeps the protocol verdict. `MoveToNextTick`
/// re-issues the same command (a fresh envelope id) at the earliest tick the
/// replica does not know to be closed, at most `max_moves` times per
/// lineage. Re-issuing is a runtime decision layered on top of the protocol;
/// the original command stays `DecisionLate` forever.
pub(all) enum LateCommandPolicy {
  RejectAsLate
  MoveToNextTick(max_moves~ : Int)
} derive(Eq, Debug)

///|
fn[
  S : ToJson + @json.FromJson,
  C : Eq + @json.FromJson,
  E : ToJson + @json.FromJson,
  R : ToJson + @json.FromJson,
] load_object(
  protocol : @prdt.Protocol[S, C, E, R],
  id : String,
  store : &CheckpointStore,
) -> (@prdt.ReplicatedDomain[S, C, E, R], Map[String, String], Map[String, Int]) raise @prdt.ProtocolError {
  match store.load() {
    Some(snapshot) => {
      guard snapshot is Object(fields) else {
        raise @prdt.SnapshotMismatch("replica checkpoint: expected object")
      }
      let object_json = match fields.get("object") {
        Some(value) => value
        None => snapshot // a bare ReplicatedDomain snapshot
      }
      let moved : Map[String, String] = Map([])
      let move_depth : Map[String, Int] = Map([])
      match fields.get("moved") {
        Some(Array(entries)) =>
          for entry in entries {
            guard entry is Array([String(old), String(new), Number(depth, ..)]) else {
              raise @prdt.SnapshotMismatch("replica checkpoint: bad move entry")
            }
            moved[old] = new
            move_depth[new] = depth.to_int()
          }
        Some(_) => raise @prdt.SnapshotMismatch("replica checkpoint: bad moves")
        None => ()
      }
      (
        @prdt.ReplicatedDomain::restore(protocol, object_json),
        moved,
        move_depth,
      )
    }
    None => (@prdt.ReplicatedDomain::new(protocol, id), Map([]), Map([]))
  }
}

///|
pub fn[
  S : ToJson + @json.FromJson,
  C : Eq + @json.FromJson,
  E : ToJson + @json.FromJson,
  R : ToJson + @json.FromJson,
] Replica::new(
  protocol : @prdt.Protocol[S, C, E, R],
  id : String,
  store : &CheckpointStore,
  authority? : @prdt.ClosureAuthority[C],
  late_policy? : LateCommandPolicy = RejectAsLate,
) -> Replica[S, C, E, R] raise @prdt.ProtocolError {
  let (object, moved, move_depth) = load_object(protocol, id, store)
  {
    id,
    protocol,
    store,
    authority,
    late_policy,
    object,
    outbox: [],
    moved,
    move_depth,
  }
}

///|
pub fn[S, C, E, R] Replica::id(self : Replica[S, C, E, R]) -> String {
  self.id
}

///|
pub fn[S, C, E, R] Replica::protocol(
  self : Replica[S, C, E, R],
) -> @prdt.Protocol[S, C, E, R] {
  self.protocol
}

///|
pub fn[S, C, E, R] Replica::object(
  self : Replica[S, C, E, R],
) -> @prdt.ReplicatedDomain[S, C, E, R] {
  self.object
}

///|
pub fn[S, C, E, R] Replica::is_authority(self : Replica[S, C, E, R]) -> Bool {
  self.authority is Some(_)
}

///|
pub fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] Replica::propose(
  self : Replica[S, C, E, R],
  tick : Int,
  command : C,
) -> @prdt.Envelope[C] raise @prdt.ProtocolError {
  let proposal = self.object.propose(tick, command)
  let _ = self.checkpoint() // write-ahead: own proposals are durable before they leave
  self.outbox.push(proposal.delta)
  proposal.envelope
}

///|
pub fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] Replica::receive(
  self : Replica[S, C, E, R],
  delta : @prdt.Delta[C],
) -> Unit raise @prdt.ProtocolError {
  self.object.merge(delta)
  let _ = self.reissue_late()
}

///|
/// Own commands that became `DecisionLate` and were re-issued, as
/// `(late id, new id)` pairs.
pub fn[S, C, E, R] Replica::moves(
  self : Replica[S, C, E, R],
) -> Array[(String, String)] {
  let ids = self.moved.keys().to_array()
  ids.sort()
  ids.map(fn(id) { (id, self.moved.get(id).unwrap()) })
}

///|
/// Earliest tick at or after `next_tick` that this replica does not know to
/// be closed.
fn[S, C, E, R] Replica::earliest_open_tick(self : Replica[S, C, E, R]) -> Int {
  let closures = self.object.state().closures()
  let mut tick = self.next_tick()
  while closures.for_tick(tick) is Closed(_) {
    tick += 1
  }
  tick
}

///|
/// Apply the late policy to own commands. Returns the re-issued envelopes;
/// their deltas are queued in the outbox.
pub fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] Replica::reissue_late(
  self : Replica[S, C, E, R],
) -> Array[@prdt.Envelope[C]] raise @prdt.ProtocolError {
  let max_moves = match self.late_policy {
    RejectAsLate => return []
    MoveToNextTick(max_moves~) => max_moves
  }
  let decision = self.decision()
  let out = []
  for id in decision.command_ids() {
    if !(decision.of(id) is @prdt.DecisionLate(_)) || self.moved.contains(id) {
      continue
    }
    let envelope = match self.find_own(id) {
      Some(envelope) => envelope
      None => continue
    }
    let depth = self.move_depth.get(id).unwrap_or(0)
    if depth >= max_moves {
      continue
    }
    let reissued = self.propose(self.earliest_open_tick(), envelope.command)
    self.moved[id] = reissued.id
    self.move_depth[reissued.id] = depth + 1
    let _ = self.checkpoint()
    out.push(reissued)
  }
  out
}

///|
fn[S, C, E, R] Replica::find_own(
  self : Replica[S, C, E, R],
  id : String,
) -> @prdt.Envelope[C]? {
  for envelope in self.object.state().proposals().list() {
    if envelope.id == id && envelope.submitted_by == self.id {
      return Some(envelope)
    }
  }
  None
}

///|
/// Full knowledge for anti-entropy.
pub fn[S, C, E, R] Replica::full_delta(
  self : Replica[S, C, E, R],
) -> @prdt.Delta[C] {
  self.object.delta()
}

///|
pub fn[S, C, E, R] Replica::drain_outbox(
  self : Replica[S, C, E, R],
) -> Array[@prdt.Delta[C]] {
  let out = self.outbox
  self.outbox = []
  out
}

///|
pub fn[S, C, E, R] Replica::decision(
  self : Replica[S, C, E, R],
) -> @prdt.Decision[E, R] {
  self.object.decision()
}

///|
pub fn[S, C, E, R] Replica::domain_state(self : Replica[S, C, E, R]) -> S {
  self.object.domain_state()
}

///|
pub fn[S, C, E, R] Replica::next_tick(self : Replica[S, C, E, R]) -> Int {
  self.object.next_tick()
}

///|
pub fn[S, C : ToJson, E, R] Replica::state_hash(
  self : Replica[S, C, E, R],
) -> String {
  self.object.state_hash()
}

///|
pub fn[S : ToJson, C : ToJson, E : ToJson, R : ToJson] Replica::checkpoint(
  self : Replica[S, C, E, R],
) -> Json {
  let moves = self
    .moves()
    .map(fn(entry) {
      Json::array([
        entry.0.to_json(),
        entry.1.to_json(),
        self.move_depth.get(entry.1).unwrap_or(0).to_json(),
      ])
    })
  let snapshot : Json = {
    "object": self.object.snapshot(),
    "moved": Json::array(moves),
  }
  self.store.save(snapshot)
  snapshot
}

///|
/// Simulate a crash: drop in-memory state and the outbox, reload the last checkpoint.
pub fn[
  S : ToJson + @json.FromJson,
  C : Eq + @json.FromJson,
  E : ToJson + @json.FromJson,
  R : ToJson + @json.FromJson,
] Replica::restart(
  self : Replica[S, C, E, R],
) -> Unit raise @prdt.ProtocolError {
  let (object, moved, move_depth) = load_object(
    self.protocol,
    self.id,
    self.store,
  )
  self.object = object
  self.moved = moved
  self.move_depth = move_depth
  self.outbox = []
}

///|
/// Close the next tick with every proposal currently known for it.
/// Returns `None` when this replica holds no closure authority.
pub fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] Replica::close_next_tick(
  self : Replica[S, C, E, R],
) -> @prdt.ClosureCertificate? raise @prdt.ProtocolError {
  let authority = match self.authority {
    Some(authority) => authority
    None => return None
  }
  let tick = self.next_tick()
  let known = self.object.state().proposals().for_tick(tick).values().to_array()
  let certificate = authority.close(
    tick,
    self.decision().head_decision_hash(),
    known,
  ) catch {
    @prdt.BatchTickMismatch(_, _, id) => raise @prdt.InvalidTick(id)
    @prdt.DuplicateCommandId(id) => raise @prdt.ConflictingProposal(id)
  }
  self.object.close_tick(certificate)
  // The authority also certifies the new head so replicas may compact to it
  // and hand it to peers as a base.
  let decision = self.decision()
  let base_certificate = authority.certify_base(
    self.next_tick(),
    decision.head_decision_hash(),
    @prdt.hash_value(self.protocol.hasher(), self.domain_state()),
  )
  let delta : @prdt.Delta[C] = {
    proposals: [],
    closures: [certificate],
    base_certificates: [base_certificate],
  }
  self.object.merge({
    proposals: [],
    closures: [],
    base_certificates: [base_certificate],
  })
  let _ = self.checkpoint() // certificates are durable before they leave
  self.outbox.push(delta)
  Some(certificate)
}

///|
pub fn[S, C, E, R] Replica::digest(
  self : Replica[S, C, E, R],
) -> @prdt.KnowledgeDigest {
  self.object.digest()
}

///|
/// Everything a peer with `digest` is missing, including our base if the peer
/// is behind it.
pub fn[S, C, E, R] Replica::catchup_since(
  self : Replica[S, C, E, R],
  digest : @prdt.KnowledgeDigest,
) -> @prdt.Catchup[S, C] {
  self.object.catchup_since(digest)
}

///|
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] Replica::receive_catchup(
  self : Replica[S, C, E, R],
  catchup : @prdt.Catchup[S, C],
) -> Unit raise @prdt.ProtocolError {
  self.object.apply_catchup(catchup)
}

///|
/// Fold finalized history into the base and persist the smaller snapshot.
pub fn[S : ToJson, C : ToJson, E : ToJson, R : ToJson] Replica::compact(
  self : Replica[S, C, E, R],
  retain_ticks~ : Int,
) -> Unit raise @prdt.ProtocolError {
  self.object.compact(retain_ticks~)
  let _ = self.checkpoint()
}
