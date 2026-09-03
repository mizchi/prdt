///|
/// Replicated Domain Object
///
///   Pure Domain State Machine + Replicated Finalization Protocol
///
/// The replicated state is the triple (proposals, closures, committed). The
/// first two are what replicas exchange; the committed prefix is derived
/// deterministically from them and kept only as a materialization.
///
///   Knowledge state  ->  Speculative view  ->  Final decision
///   append/join          (client side)        never reverts
///
/// Every `Protocol` method is pure: it returns fresh values and never mutates
/// its inputs. `ReplicatedDomain` is a small mutable wrapper.
pub struct Protocol[S, C, E, R] {
  domain : Domain[S, C, E, R]
  order : CommandOrder[C]
  finalizer : &Finalizer
  hasher : &Hasher
  genesis_tick : Int
  genesis_hash : String
}

///|
/// Compacted history: the decision hash and domain state at `next_tick - 1`.
/// The genesis base carries the initial state and the genesis hash. Every
/// tick below `next_tick` has been finalized and may have been forgotten.
pub(all) struct Base[S] {
  next_tick : Int
  decision_hash : String
  state : S
} derive(Eq, Debug, ToJson, FromJson)

///|
pub struct State[S, C, E, R] {
  base : Base[S]
  /// Certificate for `base`; `None` only for the genesis base.
  base_certificate : BaseCertificate?
  /// Certified bases at or above `base.next_tick`, keyed by `next_tick`.
  /// A replica may compact only to a certified boundary.
  certified_bases : Map[Int, BaseCertificate]
  proposals : ProposalState[C]
  closures : ClosureMap
  committed : CommittedLog[ResolvedBatch[S, C, E, R]]
}

///|
/// What one replica already knows, so a peer can send only the rest.
/// Ticks below `next_tick` are finalized on the requester and never needed.
pub(all) struct KnowledgeDigest {
  /// Ticks below this were compacted on the requester; it cannot store them.
  base_next_tick : Int
  /// Ticks below this are finalized on the requester.
  next_tick : Int
  /// Ids known for ticks at or above `base_next_tick` (late ones included).
  known_ids : Array[String]
  /// Closed ticks at or above `next_tick`.
  closed_ticks : Array[Int]
  /// Certified base ticks at or above `base_next_tick`.
  certified_ticks : Array[Int]
} derive(Eq, Debug, ToJson, FromJson)

///|
/// What replicas exchange. The committed prefix is never transported.
pub(all) struct Delta[C] {
  proposals : Array[Envelope[C]]
  closures : Array[ClosureCertificate]
  base_certificates : Array[BaseCertificate]
} derive(Eq, Debug, ToJson, FromJson)

///|
pub fn[C] Delta::empty() -> Delta[C] {
  { proposals: [], closures: [], base_certificates: [] }
}

///|
/// Decision order: `DecisionPending <= anything`; a final decision is only
/// `<=` itself. `DecisionLate` is a protocol-level rejection: the tick closed
/// without this command. It is final because closure is final.
pub(all) enum CommandDecision[E, R] {
  DecisionPending
  DecisionAccepted(Int, E)
  DecisionRejected(Int, R)
  DecisionLate(Int)
} derive(Eq, Debug)

///|
pub struct Decision[E, R] {
  commands : Map[String, CommandDecision[E, R]]
  committed_ticks : Array[Int]
  head_decision_hash : String
}

///|
pub fn[E, R] Decision::of(
  self : Decision[E, R],
  id : String,
) -> CommandDecision[E, R] {
  match self.commands.get(id) {
    Some(decision) => decision
    None => DecisionPending
  }
}

///|
pub fn[E, R] Decision::command_ids(self : Decision[E, R]) -> Array[String] {
  let ids = self.commands.keys().to_array()
  ids.sort()
  ids
}

///|
pub fn[E, R] Decision::committed_ticks(self : Decision[E, R]) -> Array[Int] {
  self.committed_ticks.copy()
}

///|
pub fn[E, R] Decision::head_decision_hash(self : Decision[E, R]) -> String {
  self.head_decision_hash
}

///|
pub fn[S : ToJson, C, E, R] Protocol::new(
  domain : Domain[S, C, E, R],
  order : CommandOrder[C],
  finalizer : &Finalizer,
  hasher : &Hasher,
  genesis_tick? : Int = 0,
) -> Protocol[S, C, E, R] {
  let initial_state_hash = hash_value(hasher, (domain.initial_state)())
  let genesis_hash = hash_json(hasher, {
    "genesis": "prdt/genesis/v1",
    "genesis_tick": genesis_tick.to_json(),
    "initial_state_hash": initial_state_hash.to_json(),
  })
  { domain, order, finalizer, hasher, genesis_tick, genesis_hash }
}

///|
pub fn[S, C, E, R] Protocol::genesis_hash(
  self : Protocol[S, C, E, R],
) -> String {
  self.genesis_hash
}

///|
pub fn[S, C, E, R] Protocol::genesis_tick(self : Protocol[S, C, E, R]) -> Int {
  self.genesis_tick
}

///|
pub fn[S, C, E, R] Protocol::hasher(self : Protocol[S, C, E, R]) -> &Hasher {
  self.hasher
}

///|
pub fn[S, C, E, R] Protocol::order(
  self : Protocol[S, C, E, R],
) -> CommandOrder[C] {
  self.order
}

///|
pub fn[S, C, E, R] Protocol::domain(
  self : Protocol[S, C, E, R],
) -> Domain[S, C, E, R] {
  self.domain
}

///|
pub fn[S, C, E, R] Protocol::initial(
  self : Protocol[S, C, E, R],
) -> State[S, C, E, R] {
  {
    base: {
      next_tick: self.genesis_tick,
      decision_hash: self.genesis_hash,
      state: (self.domain.initial_state)(),
    },
    base_certificate: None,
    certified_bases: Map([]),
    proposals: ProposalState::empty(),
    closures: ClosureMap::empty(),
    committed: CommittedLog::empty(),
  }
}

///|
pub fn[S, C, E, R] State::base(self : State[S, C, E, R]) -> Base[S] {
  self.base
}

///|
pub fn[S, C, E, R] State::base_certificate(
  self : State[S, C, E, R],
) -> BaseCertificate? {
  self.base_certificate
}

///|
/// Certified bases in `next_tick` order.
pub fn[S, C, E, R] State::certified_bases(
  self : State[S, C, E, R],
) -> Array[BaseCertificate] {
  let ticks = self.certified_bases.keys().to_array()
  ticks.sort()
  ticks.map(fn(tick) { self.certified_bases.get(tick).unwrap() })
}

///|
pub fn[S, C, E, R] State::proposals(
  self : State[S, C, E, R],
) -> ProposalState[C] {
  self.proposals
}

///|
pub fn[S, C, E, R] State::closures(self : State[S, C, E, R]) -> ClosureMap {
  self.closures
}

///|
pub fn[S, C, E, R] State::committed(
  self : State[S, C, E, R],
) -> CommittedLog[ResolvedBatch[S, C, E, R]] {
  self.committed
}

///|
pub fn[S, C, E, R] Protocol::domain_state(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> S {
  ignore(self)
  match state.committed.last() {
    Some(batch) => batch.result.resulting_state
    None => state.base.state
  }
}

///|
pub fn[S, C, E, R] Protocol::next_tick(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> Int {
  ignore(self)
  state.base.next_tick + state.committed.length()
}

///|
fn[S, C, E, R] Protocol::validate_certificate_shape(
  self : Protocol[S, C, E, R],
  certificate : ClosureCertificate,
) -> Unit raise ProtocolError {
  if !is_valid_tick(certificate.tick) || certificate.tick < self.genesis_tick {
    raise MalformedCertificate(certificate.tick, "tick before genesis")
  }
  let seen : Map[String, Unit] = Map([])
  for id in certificate.ordered_command_ids {
    if seen.contains(id) {
      raise MalformedCertificate(certificate.tick, "duplicate command id " + id)
    }
    seen[id] = ()
  }
  if !certificate_shape_ok(self.hasher, certificate) {
    raise MalformedCertificate(
      certificate.tick,
      "ordered_commands_hash does not match ids",
    )
  }
}

///|
/// Extend the committed prefix as far as closures and known commands allow.
fn[S : ToJson, C, E : ToJson, R : ToJson] Protocol::advance(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> State[S, C, E, R] raise ProtocolError {
  let mut log = state.committed
  let mut domain_state = self.domain_state(state)
  while true {
    let tick = state.base.next_tick + log.length()
    let certificate = match state.closures.for_tick(tick) {
      Closed(certificate) => certificate
      ClosurePending => break
    }
    let parent = log.head_decision_hash(state.base.decision_hash)
    if certificate.parent_decision_hash != parent {
      raise ChainMismatch(tick)
    }
    let known = state.proposals.for_tick(tick)
    let envelopes : Array[Envelope[C]] = []
    let mut complete = true
    for id in certificate.ordered_command_ids {
      match known.get(id) {
        Some(envelope) => envelopes.push(envelope)
        None => {
          complete = false
          break
        }
      }
    }
    if !complete {
      break
    }
    let batch = resolve_batch(
      tick,
      domain_state,
      envelopes,
      self.domain,
      self.order,
      self.hasher,
    ) catch {
      BatchTickMismatch(_, _, id) =>
        raise MalformedCertificate(
          tick,
          "command " + id + " is for another tick",
        )
      DuplicateCommandId(id) =>
        raise MalformedCertificate(tick, "duplicate command id " + id)
    }
    let resolved_ids = batch.results.map(fn(r) { r.envelope.id })
    if resolved_ids != certificate.ordered_command_ids {
      raise OrderMismatch(tick)
    }
    let verdicts = Json::array(
      batch.results.map(fn(r) {
        { "id": r.envelope.id.to_json(), "verdict": r.verdict.to_json() }
      }),
    )
    let result_hash = hash_json(self.hasher, {
      "tick": tick.to_json(),
      "parent_decision_hash": parent.to_json(),
      "ordered_commands_hash": certificate.ordered_commands_hash.to_json(),
      "resulting_state_hash": batch.resulting_state_hash.to_json(),
      "verdicts": verdicts,
    })
    domain_state = batch.resulting_state
    log = log.append({
      tick,
      parent_decision_hash: parent,
      ordered_commands_hash: certificate.ordered_commands_hash,
      result_hash,
      result: batch,
    })
  }
  { ..state, committed: log }
}

///|
/// Verify every certificate, join, and extend the committed prefix.
/// Raises `ProtocolError` and leaves `state` untouched on failure.
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] Protocol::apply_delta(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  delta : Delta[C],
) -> State[S, C, E, R] raise ProtocolError {
  let mut proposals = state.proposals
  for envelope in delta.proposals {
    if !is_valid_tick(envelope.tick) {
      raise InvalidTick(envelope.id)
    }
    // Ticks below the base were finalized and compacted; nothing about them
    // can change, so their proposals are not retained.
    if envelope.tick < state.base.next_tick {
      continue
    }
    proposals = proposals.add(envelope)
  }
  let retained : Array[ClosureCertificate] = []
  for certificate in delta.closures {
    if certificate.tick < state.base.next_tick {
      continue
    }
    self.validate_certificate_shape(certificate)
    if !self.finalizer.verify_closure(certificate) {
      raise InvalidCertificate(certificate.tick)
    }
    retained.push(certificate)
  }
  let closures = state.closures.merge(ClosureMap::from_certificates(retained))
  let with_knowledge = self.advance({ ..state, proposals, closures })
  self.admit_base_certificates(with_knowledge, delta.base_certificates)
}

///|
/// Verify base certificates, check them against local history, and record
/// them. A certificate for the current base fills `base_certificate`.
fn[S : ToJson, C, E, R] Protocol::admit_base_certificates(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  certificates : Array[BaseCertificate],
) -> State[S, C, E, R] raise ProtocolError {
  if certificates.length() == 0 {
    return state
  }
  let certified : Map[Int, BaseCertificate] = Map([])
  for tick, certificate in state.certified_bases {
    certified[tick] = certificate
  }
  let mut base_certificate = state.base_certificate
  for certificate in certificates {
    if certificate.next_tick < state.base.next_tick {
      continue
    }
    if !self.finalizer.verify_base(certificate) {
      raise InvalidCertificate(certificate.next_tick)
    }
    self.check_base_consistency(state, certificate)
    match certified.get(certificate.next_tick) {
      Some(existing) =>
        if !existing.same_base(certificate) {
          raise ConflictingBase(certificate.next_tick)
        }
      None => certified[certificate.next_tick] = certificate
    }
    if certificate.next_tick == state.base.next_tick && base_certificate is None {
      base_certificate = Some(certificate)
    }
  }
  { ..state, base_certificate, certified_bases: certified }
}

///|
/// A certificate that overlaps local finalized history must agree with it.
fn[S : ToJson, C, E, R] Protocol::check_base_consistency(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  certificate : BaseCertificate,
) -> Unit raise ProtocolError {
  if certificate.next_tick == state.base.next_tick {
    if certificate.decision_hash != state.base.decision_hash ||
      certificate.state_hash != hash_value(self.hasher, state.base.state) {
      raise ConflictingBase(certificate.next_tick)
    }
    return
  }
  let index = certificate.next_tick - 1 - state.base.next_tick
  let batches = state.committed.batches()
  if index >= 0 && index < batches.length() {
    let batch = batches[index]
    if batch.result_hash != certificate.decision_hash ||
      batch.result.resulting_state_hash != certificate.state_hash {
      raise ConflictingBase(certificate.next_tick)
    }
  }
}

///|
/// Whole-state join. Verifies nothing; use `apply_delta` for untrusted input.
///
/// The join adopts the later base. The other side's committed prefix must
/// agree with that base where it overlaps (`PrefixConflict` otherwise), and
/// everything below the adopted base is pruned.
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] Protocol::join(
  self : Protocol[S, C, E, R],
  left : State[S, C, E, R],
  right : State[S, C, E, R],
) -> State[S, C, E, R] raise ProtocolError {
  let (lead, other) = if left.base.next_tick >= right.base.next_tick {
    (left, right)
  } else {
    (right, left)
  }
  let other_log = self.rebase_log(other, lead.base)
  let committed = lead.committed.merge(other_log)
  let proposals = lead.proposals
    .merge(other.proposals)
    .prune_below(lead.base.next_tick)
  let closures = lead.closures
    .merge(other.closures)
    .prune_below(lead.base.next_tick)
  let certified : Map[Int, BaseCertificate] = Map([])
  for tick, certificate in lead.certified_bases {
    certified[tick] = certificate
  }
  for tick, certificate in other.certified_bases {
    if tick < lead.base.next_tick {
      continue
    }
    match certified.get(tick) {
      Some(existing) =>
        if !existing.same_base(certificate) {
          raise ConflictingBase(tick)
        }
      None => certified[tick] = certificate
    }
  }
  let base_certificate = match lead.base_certificate {
    Some(certificate) => Some(certificate)
    None =>
      if other.base.next_tick == lead.base.next_tick {
        other.base_certificate
      } else {
        certified.get(lead.base.next_tick)
      }
  }
  self.advance({
    base: lead.base,
    base_certificate,
    certified_bases: certified,
    proposals,
    closures,
    committed,
  })
}

///|
/// Express `state`'s committed log relative to `base`, checking that the
/// overlap agrees with the base decision hash.
fn[S, C, E, R] Protocol::rebase_log(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  base : Base[S],
) -> CommittedLog[ResolvedBatch[S, C, E, R]] raise ProtocolError {
  ignore(self)
  if state.base.next_tick == base.next_tick {
    if state.base.decision_hash != base.decision_hash {
      raise PrefixConflict(0)
    }
    return state.committed
  }
  if state.base.next_tick > base.next_tick {
    abort("rebase_log: state base is ahead of the target base")
  }
  // Position of the batch that produced `base` inside `state`'s log.
  let index = base.next_tick - 1 - state.base.next_tick
  let batches = state.committed.batches()
  if index < batches.length() {
    if batches[index].result_hash != base.decision_hash {
      raise PrefixConflict(index)
    }
    { batches: batches[index + 1:].to_owned() }
  } else {
    // `state` has not reached the base yet; it contributes nothing beyond it.
    CommittedLog::empty()
  }
}

///|
/// Fold committed batches into the base, keeping at least `retain_ticks`
/// materialized batches, and forget proposals, closures, and certificates
/// below the new base. Only a *certified* boundary can become the base, so
/// compaction moves to the latest certified boundary that keeps the
/// retention window; without one it is a no-op.
///
/// Compaction is an administrative operation, not a lattice join: it forgets
/// finalized history, so `decision` no longer reports commands of compacted
/// ticks. It never changes a verdict.
pub fn[S, C, E, R] Protocol::compact(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  retain_ticks~ : Int,
) -> State[S, C, E, R] raise ProtocolError {
  ignore(self)
  if retain_ticks < 0 {
    abort("retain_ticks must be non-negative")
  }
  let batches = state.committed.batches()
  let mut drop = @contracts.compaction_drop(batches.length(), retain_ticks)
  while drop > 0 {
    let boundary = batches[drop - 1]
    match state.certified_bases.get(boundary.tick + 1) {
      Some(certificate) => {
        if certificate.decision_hash != boundary.result_hash ||
          certificate.state_hash != boundary.result.resulting_state_hash {
          raise ConflictingBase(boundary.tick + 1)
        }
        let base : Base[S] = {
          next_tick: boundary.tick + 1,
          decision_hash: boundary.result_hash,
          state: boundary.result.resulting_state,
        }
        let certified : Map[Int, BaseCertificate] = Map([])
        for tick, known in state.certified_bases {
          if tick >= base.next_tick {
            certified[tick] = known
          }
        }
        return {
          base,
          base_certificate: Some(certificate),
          certified_bases: certified,
          proposals: state.proposals.prune_below(base.next_tick),
          closures: state.closures.prune_below(base.next_tick),
          committed: { batches: batches[drop:].to_owned() },
        }
      }
      None => drop -= 1
    }
  }
  state
}

///|
pub fn[S, C, E, R] Protocol::digest(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> KnowledgeDigest {
  let next_tick = self.next_tick(state)
  {
    base_next_tick: state.base.next_tick,
    next_tick,
    known_ids: state.proposals.ids_from(state.base.next_tick),
    closed_ticks: state.closures.closed_ticks_from(next_tick),
    certified_ticks: state.certified_bases().map(fn(c) { c.next_tick }),
  }
}

///|
/// The part of `state` a peer with `digest` is missing: proposals and
/// closures for ticks the peer has not finalized, minus what it already knows.
pub fn[S, C, E, R] Protocol::delta_since(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  digest : KnowledgeDigest,
) -> Delta[C] {
  ignore(self)
  let known : Map[String, Unit] = Map([])
  for id in digest.known_ids {
    known[id] = ()
  }
  let closed : Map[Int, Unit] = Map([])
  for tick in digest.closed_ticks {
    closed[tick] = ()
  }
  let proposals = state.proposals
    .list()
    .filter(fn(e) { e.tick >= digest.base_next_tick && !known.contains(e.id) })
  let closures = state.closures
    .list()
    .filter(fn(c) { c.tick >= digest.next_tick && !closed.contains(c.tick) })
  let certified : Map[Int, Unit] = Map([])
  for tick in digest.certified_ticks {
    certified[tick] = ()
  }
  let base_certificates = state
    .certified_bases()
    .filter(fn(c) {
      c.next_tick >= digest.base_next_tick && !certified.contains(c.next_tick)
    })
  { proposals, closures, base_certificates }
}

///|
pub fn[S, C : Eq, E, R] Protocol::states_equal(
  self : Protocol[S, C, E, R],
  left : State[S, C, E, R],
  right : State[S, C, E, R],
) -> Bool {
  ignore(self)
  left.base.next_tick == right.base.next_tick &&
  left.base.decision_hash == right.base.decision_hash &&
  left.certified_bases().map(fn(c) { c.payload_json() }) ==
  right.certified_bases().map(fn(c) { c.payload_json() }) &&
  left.proposals.equals(right.proposals) &&
  left.closures.equals(right.closures) &&
  left.committed.equals(right.committed)
}

///|
/// Full knowledge as a delta, for anti-entropy.
pub fn[S, C, E, R] Protocol::delta_of(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> Delta[C] {
  ignore(self)
  {
    proposals: state.proposals.list(),
    closures: state.closures.list(),
    base_certificates: state.certified_bases(),
  }
}

///|
pub fn[S, C, E, R] Protocol::decision(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> Decision[E, R] {
  ignore(self)
  let commands : Map[String, CommandDecision[E, R]] = Map([])
  let verdict_by_tick : Map[Int, Map[String, Verdict[E, R]]] = Map([])
  for batch in state.committed.batches {
    let verdicts : Map[String, Verdict[E, R]] = Map([])
    for resolved in batch.result.results {
      verdicts[resolved.envelope.id] = resolved.verdict
    }
    verdict_by_tick[batch.tick] = verdicts
  }
  for tick in state.proposals.ticks() {
    let included : Map[String, Unit]? = match state.closures.for_tick(tick) {
      Closed(certificate) => {
        let set : Map[String, Unit] = Map([])
        for id in certificate.ordered_command_ids {
          set[id] = ()
        }
        Some(set)
      }
      ClosurePending => None
    }
    let known = state.proposals.for_tick(tick)
    let ids = known.keys().to_array()
    ids.sort()
    for id in ids {
      let verdict = match verdict_by_tick.get(tick) {
        Some(verdicts) => verdicts.get(id)
        None => None
      }
      commands[id] = match verdict {
        Some(Accepted(event~)) => DecisionAccepted(tick, event)
        Some(Rejected(reason~)) => DecisionRejected(tick, reason)
        None =>
          match included {
            Some(set) =>
              if set.contains(id) {
                DecisionPending
              } else {
                DecisionLate(tick)
              }
            None => DecisionPending
          }
      }
    }
  }
  {
    commands,
    committed_ticks: state.committed.batches.map(fn(b) { b.tick }),
    head_decision_hash: state.committed.head_decision_hash(
      state.base.decision_hash,
    ),
  }
}

///|
/// Hash of the whole replicated state; equal hashes mean converged replicas.
pub fn[S, C : ToJson, E, R] Protocol::state_hash(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> String {
  hash_json(self.hasher, {
    "base": {
      "next_tick": state.base.next_tick.to_json(),
      "decision_hash": state.base.decision_hash.to_json(),
    },
    "proposals": state.proposals.list().to_json(),
    "closures": Json::array(
      state.closures.list().map(fn(c) { c.payload_json() }),
    ),
    "certified_bases": Json::array(
      state.certified_bases().map(fn(c) { c.payload_json() }),
    ),
    "committed": state.committed.result_hashes().to_json(),
  })
}

///|
pub let snapshot_version : Int = 3

///|
/// Persisted form of a `State`. The committed prefix is stored for speed but
/// never trusted: `restore_snapshot` re-derives it from the knowledge and
/// rejects the snapshot when they differ.
pub(all) struct Snapshot[S, C, E, R] {
  version : Int
  genesis_tick : Int
  base : Base[S]
  /// Absent only for the genesis base.
  base_certificate : BaseCertificate?
  certified_bases : Array[BaseCertificate]
  proposals : Array[Envelope[C]]
  closures : Array[ClosureCertificate]
  committed : Array[CommittedBatch[ResolvedBatch[S, C, E, R]]]
} derive(ToJson, FromJson)

///|
pub fn[S, C, E, R] Protocol::snapshot_of(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> Snapshot[S, C, E, R] {
  {
    version: snapshot_version,
    genesis_tick: self.genesis_tick,
    base: state.base,
    base_certificate: state.base_certificate,
    certified_bases: state.certified_bases(),
    proposals: state.proposals.list(),
    closures: state.closures.list(),
    committed: state.committed.batches,
  }
}

///|
pub fn[S : ToJson, C : ToJson, E : ToJson, R : ToJson] Protocol::snapshot(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
) -> Json {
  self.snapshot_of(state).to_json()
}

///|
fn[T : @json.FromJson] snapshot_decode(
  json : Json,
  what : String,
) -> T raise ProtocolError {
  @json.from_json(json) catch {
    @json.JsonDecodeError((path, message)) =>
      raise SnapshotMismatch(what + ": " + message + " at " + path.to_string())
  }
}

///|
/// Restore a snapshot from its JSON encoding. See `restore_snapshot`.
pub fn[
  S : ToJson + @json.FromJson,
  C : Eq + @json.FromJson,
  E : ToJson + @json.FromJson,
  R : ToJson + @json.FromJson,
] Protocol::restore(
  self : Protocol[S, C, E, R],
  json : Json,
) -> State[S, C, E, R] raise ProtocolError {
  self.restore_snapshot(snapshot_decode(json, "snapshot"))
}

///|
/// Restore a snapshot. The persisted committed prefix is re-derived from the
/// persisted knowledge and must match it exactly; a snapshot is never trusted
/// blindly.
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] Protocol::restore_snapshot(
  self : Protocol[S, C, E, R],
  snapshot : Snapshot[S, C, E, R],
) -> State[S, C, E, R] raise ProtocolError {
  if snapshot.version != snapshot_version {
    raise SnapshotMismatch("unsupported snapshot version")
  }
  if snapshot.genesis_tick != self.genesis_tick {
    raise SnapshotMismatch("genesis tick mismatch")
  }
  let base = snapshot.base
  if base.next_tick == self.genesis_tick &&
    base.decision_hash != self.genesis_hash {
    raise SnapshotMismatch("genesis base hash mismatch")
  }
  match snapshot.base_certificate {
    Some(certificate) =>
      if certificate.next_tick != base.next_tick ||
        certificate.decision_hash != base.decision_hash {
        raise SnapshotMismatch("base certificate does not match base")
      }
    None =>
      if base.next_tick != self.genesis_tick {
        raise SnapshotMismatch("compacted base without certificate")
      }
  }
  let certified_bases : Map[Int, BaseCertificate] = Map([])
  for certificate in snapshot.certified_bases {
    certified_bases[certificate.next_tick] = certificate
  }
  let mut proposal_state : ProposalState[C] = ProposalState::empty()
  for envelope in snapshot.proposals {
    proposal_state = proposal_state.add(envelope)
  }
  let closure_map = ClosureMap::from_certificates(snapshot.closures)
  let recomputed = self.advance({
    base,
    base_certificate: snapshot.base_certificate,
    certified_bases,
    proposals: proposal_state.prune_below(base.next_tick),
    closures: closure_map.prune_below(base.next_tick),
    committed: CommittedLog::empty(),
  }) catch {
    error => raise SnapshotMismatch("recomputation failed: " + error.kind())
  }
  let persisted_log : CommittedLog[ResolvedBatch[S, C, E, R]] = {
    batches: snapshot.committed,
  }
  let compatible = recomputed.committed.equals(
    recomputed.committed.merge(persisted_log),
  ) catch {
    _ => false
  }
  if !compatible {
    raise SnapshotMismatch("committed prefix does not match recomputation")
  }
  recomputed
}

///|
/// Mutable convenience wrapper around the pure protocol.
pub struct ReplicatedDomain[S, C, E, R] {
  protocol : Protocol[S, C, E, R]
  replica_id : String
  mut state : State[S, C, E, R]
  mut next_local_sequence : Int
}

///|
pub(all) struct Proposal[C] {
  envelope : Envelope[C]
  delta : Delta[C]
} derive(Eq, Debug)

///|
pub fn[S, C, E, R] ReplicatedDomain::new(
  protocol : Protocol[S, C, E, R],
  replica_id : String,
) -> ReplicatedDomain[S, C, E, R] {
  { protocol, replica_id, state: protocol.initial(), next_local_sequence: 0 }
}

///|
pub fn[S, C, E, R] ReplicatedDomain::protocol(
  self : ReplicatedDomain[S, C, E, R],
) -> Protocol[S, C, E, R] {
  self.protocol
}

///|
pub fn[S, C, E, R] ReplicatedDomain::replica_id(
  self : ReplicatedDomain[S, C, E, R],
) -> String {
  self.replica_id
}

///|
pub fn[S, C, E, R] ReplicatedDomain::state(
  self : ReplicatedDomain[S, C, E, R],
) -> State[S, C, E, R] {
  self.state
}

///|
pub fn[S, C, E, R] ReplicatedDomain::next_local_sequence(
  self : ReplicatedDomain[S, C, E, R],
) -> Int {
  self.next_local_sequence
}

///|
/// Record a local proposal and return the delta to disseminate.
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] ReplicatedDomain::propose(
  self : ReplicatedDomain[S, C, E, R],
  tick : Int,
  command : C,
) -> Proposal[C] raise ProtocolError {
  let local_sequence = self.next_local_sequence
  let envelope : Envelope[C] = {
    id: command_id(self.replica_id, local_sequence),
    tick,
    submitted_by: self.replica_id,
    local_sequence,
    command,
  }
  let delta : Delta[C] = {
    proposals: [envelope],
    closures: [],
    base_certificates: [],
  }
  self.state = self.protocol.apply_delta(self.state, delta)
  self.next_local_sequence = local_sequence + 1
  { envelope, delta }
}

///|
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] ReplicatedDomain::merge(
  self : ReplicatedDomain[S, C, E, R],
  delta : Delta[C],
) -> Unit raise ProtocolError {
  self.state = self.protocol.apply_delta(self.state, delta)
}

///|
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] ReplicatedDomain::close_tick(
  self : ReplicatedDomain[S, C, E, R],
  certificate : ClosureCertificate,
) -> Unit raise ProtocolError {
  self.merge({ proposals: [], closures: [certificate], base_certificates: [] })
}

///|
pub fn[S, C, E, R] ReplicatedDomain::decision(
  self : ReplicatedDomain[S, C, E, R],
) -> Decision[E, R] {
  self.protocol.decision(self.state)
}

///|
pub fn[S, C, E, R] ReplicatedDomain::domain_state(
  self : ReplicatedDomain[S, C, E, R],
) -> S {
  self.protocol.domain_state(self.state)
}

///|
pub fn[S, C, E, R] ReplicatedDomain::next_tick(
  self : ReplicatedDomain[S, C, E, R],
) -> Int {
  self.protocol.next_tick(self.state)
}

///|
pub fn[S, C, E, R] ReplicatedDomain::delta(
  self : ReplicatedDomain[S, C, E, R],
) -> Delta[C] {
  self.protocol.delta_of(self.state)
}

///|
pub fn[S, C : ToJson, E, R] ReplicatedDomain::state_hash(
  self : ReplicatedDomain[S, C, E, R],
) -> String {
  self.protocol.state_hash(self.state)
}

///|
/// Persisted form of a `ReplicatedDomain`: the protocol snapshot plus the
/// replica identity and its next local sequence number.
pub(all) struct ReplicatedSnapshot[S, C, E, R] {
  state : Snapshot[S, C, E, R]
  replica_id : String
  next_local_sequence : Int
} derive(ToJson, FromJson)

///|
pub fn[S : ToJson, C : ToJson, E : ToJson, R : ToJson] ReplicatedDomain::snapshot(
  self : ReplicatedDomain[S, C, E, R],
) -> Json {
  let snapshot : ReplicatedSnapshot[S, C, E, R] = {
    state: self.protocol.snapshot_of(self.state),
    replica_id: self.replica_id,
    next_local_sequence: self.next_local_sequence,
  }
  snapshot.to_json()
}

///|
pub fn[
  S : ToJson + @json.FromJson,
  C : Eq + @json.FromJson,
  E : ToJson + @json.FromJson,
  R : ToJson + @json.FromJson,
] ReplicatedDomain::restore(
  protocol : Protocol[S, C, E, R],
  json : Json,
) -> ReplicatedDomain[S, C, E, R] raise ProtocolError {
  let snapshot : ReplicatedSnapshot[S, C, E, R] = snapshot_decode(
    json, "replicated snapshot",
  )
  {
    protocol,
    replica_id: snapshot.replica_id,
    state: protocol.restore_snapshot(snapshot.state),
    next_local_sequence: snapshot.next_local_sequence,
  }
}

///|
/// State transfer for a peer that fell behind a compacted history: the
/// sender's base plus the delta the peer is missing.
///
/// Trust note: a base cannot be re-derived by the receiver once the sender
/// has forgotten the history behind it. `apply_catchup` therefore adopts a
/// base only when it is certified (`certificate`) and the receiver's own
/// committed prefix cannot contradict it.
pub(all) struct Catchup[S, C] {
  base : Base[S]
  /// Required unless `base` is the genesis base. Omitted from the JSON
  /// encoding when absent.
  certificate : BaseCertificate?
  delta : Delta[C]
} derive(ToJson, FromJson)

///|
pub fn[S, C, E, R] Protocol::catchup_since(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  digest : KnowledgeDigest,
) -> Catchup[S, C] {
  {
    base: state.base,
    certificate: state.base_certificate,
    delta: self.delta_since(state, digest),
  }
}

///|
/// Adopt a later base when local knowledge cannot contradict it, then apply
/// the delta. A base at or below the local base is ignored.
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] Protocol::apply_catchup(
  self : Protocol[S, C, E, R],
  state : State[S, C, E, R],
  catchup : Catchup[S, C],
) -> State[S, C, E, R] raise ProtocolError {
  let rebased = if catchup.base.next_tick > state.base.next_tick {
    let certificate = match catchup.certificate {
      Some(certificate) => certificate
      None => raise UnauthenticatedBase(catchup.base.next_tick)
    }
    if certificate.next_tick != catchup.base.next_tick ||
      certificate.decision_hash != catchup.base.decision_hash ||
      certificate.state_hash != hash_value(self.hasher, catchup.base.state) ||
      !self.finalizer.verify_base(certificate) {
      raise UnauthenticatedBase(catchup.base.next_tick)
    }
    let log = self.rebase_log(state, catchup.base)
    let certified : Map[Int, BaseCertificate] = Map([])
    for tick, known in state.certified_bases {
      if tick >= catchup.base.next_tick {
        certified[tick] = known
      }
    }
    certified[certificate.next_tick] = certificate
    {
      base: catchup.base,
      base_certificate: Some(certificate),
      certified_bases: certified,
      proposals: state.proposals.prune_below(catchup.base.next_tick),
      closures: state.closures.prune_below(catchup.base.next_tick),
      committed: log,
    }
  } else {
    state
  }
  self.apply_delta(rebased, catchup.delta)
}

///|
pub fn[S, C, E, R] ReplicatedDomain::compact(
  self : ReplicatedDomain[S, C, E, R],
  retain_ticks~ : Int,
) -> Unit raise ProtocolError {
  self.state = self.protocol.compact(self.state, retain_ticks~)
}

///|
pub fn[S, C, E, R] ReplicatedDomain::digest(
  self : ReplicatedDomain[S, C, E, R],
) -> KnowledgeDigest {
  self.protocol.digest(self.state)
}

///|
pub fn[S, C, E, R] ReplicatedDomain::delta_since(
  self : ReplicatedDomain[S, C, E, R],
  digest : KnowledgeDigest,
) -> Delta[C] {
  self.protocol.delta_since(self.state, digest)
}

///|
pub fn[S, C, E, R] ReplicatedDomain::catchup_since(
  self : ReplicatedDomain[S, C, E, R],
  digest : KnowledgeDigest,
) -> Catchup[S, C] {
  self.protocol.catchup_since(self.state, digest)
}

///|
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] ReplicatedDomain::apply_catchup(
  self : ReplicatedDomain[S, C, E, R],
  catchup : Catchup[S, C],
) -> Unit raise ProtocolError {
  self.state = self.protocol.apply_catchup(self.state, catchup)
}
