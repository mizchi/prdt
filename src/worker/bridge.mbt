///|
/// JavaScript boundary for the MMO replicated domain object.
///
/// Every function is a pure transformation over JSON strings so that a host
/// (a Cloudflare Durable Object, a browser tab, a Node process) can persist
/// the snapshot however it likes and never has to hold MoonBit object
/// handles. Responses are `{"ok":true,...}` or
/// `{"ok":false,"error":<kind>,"message":<text>}`.
///
/// `secret` selects the shared-secret dev authority (key id `authority`).
/// Deployments should replace it with a real signer behind the same traits.
priv struct Room {
  object : @mmo.GameObject
  authority : @prdt.ClosureAuthority[@mmo.GameCommand]
}

///|
fn open_room(
  snapshot : String,
  secret : String,
  replica_id : String,
) -> Room raise @prdt.ProtocolError {
  let hasher = @prdt.Sha256Hasher::new()
  let authenticator = @prdt.SharedSecretAuthenticator::new("authority", secret)
  let finalizer = @prdt.SingleAuthorityFinalizer::new(
    hasher,
    authenticator,
    authenticator.public_key(),
  )
  let protocol = @mmo.game_protocol(finalizer, hasher)
  let authority = @prdt.ClosureAuthority::new(
    hasher,
    authenticator,
    @mmo.game_order(),
  )
  let object = if snapshot == "" {
    @prdt.ReplicatedDomain::new(protocol, replica_id)
  } else {
    let json = @json.parse(snapshot) catch {
      _ => raise @prdt.SnapshotMismatch("snapshot is not valid JSON")
    }
    @prdt.ReplicatedDomain::restore(protocol, json)
  }
  { object, authority }
}

///|
fn failure(kind : String, message : String) -> String {
  Json::object({
    "ok": Json::boolean(false),
    "error": Json::string(kind),
    "message": Json::string(message),
  }).stringify()
}

///|
fn protocol_failure(error : @prdt.ProtocolError) -> String {
  failure(error.kind(), Repr(error).to_string())
}

///|
fn success(room : Room, extra : Map[String, Json]) -> String {
  let fields : Map[String, Json] = Map([])
  fields["ok"] = Json::boolean(true)
  fields["snapshot"] = room.object.snapshot()
  fields["next_tick"] = room.object.next_tick().to_json()
  for key, value in extra {
    fields[key] = value
  }
  Json::object(fields).stringify()
}

///|
fn decision_json(
  decision : @prdt.Decision[@mmo.GameEvent, @mmo.GameRejection],
) -> Json {
  let commands : Map[String, Json] = Map([])
  for id in decision.command_ids() {
    commands[id] = match decision.of(id) {
      @prdt.DecisionPending => { "status": "Pending" }
      @prdt.DecisionAccepted(tick, event) =>
        {
          "status": "Accepted",
          "tick": tick.to_json(),
          "event": event.to_json(),
        }
      @prdt.DecisionRejected(tick, reason) =>
        {
          "status": "Rejected",
          "tick": tick.to_json(),
          "reason": reason.to_json(),
        }
      @prdt.DecisionLate(closed_tick) =>
        { "status": "RejectedLate", "closed_tick": closed_tick.to_json() }
    }
  }
  {
    "commands": Json::object(commands),
    "committed_ticks": decision.committed_ticks().to_json(),
    "head_decision_hash": decision.head_decision_hash().to_json(),
  }
}

///|
fn parse_input(text : String, what : String) -> Json raise @prdt.ProtocolError {
  @json.parse(text) catch {
    _ => raise @prdt.SnapshotMismatch(what + " is not valid JSON")
  }
}

///|
fn[T : @json.FromJson] decode_input(
  json : Json,
  what : String,
) -> T raise @prdt.ProtocolError {
  @json.from_json(json) catch {
    @json.JsonDecodeError((_, message)) =>
      raise @prdt.SnapshotMismatch(what + ": " + message)
  }
}

///|
/// Propose a command for `tick` as `replica_id`. Returns the envelope, the
/// delta to disseminate, and the current decision.
pub fn prdt_mmo_propose(
  snapshot : String,
  secret : String,
  replica_id : String,
  tick : Int,
  command_json : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    let command : @mmo.GameCommand = decode_input(
      parse_input(command_json, "command"),
      "command",
    )
    let proposal = room.object.propose(tick, command)
    success(room, {
      "envelope": proposal.envelope.to_json(),
      "delta": proposal.delta.to_json(),
      "decision": decision_json(room.object.decision()),
    })
  } catch {
    error => protocol_failure(error)
  }
}

///|
/// Merge a delta received from another replica.
pub fn prdt_mmo_merge(
  snapshot : String,
  secret : String,
  replica_id : String,
  delta_json : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    let delta : @prdt.Delta[@mmo.GameCommand] = decode_input(
      parse_input(delta_json, "delta"),
      "delta",
    )
    room.object.merge(delta)
    success(room, { "decision": decision_json(room.object.decision()) })
  } catch {
    error => protocol_failure(error)
  }
}

///|
/// Close the next tick with every proposal currently known for it (authority only).
pub fn prdt_mmo_close(
  snapshot : String,
  secret : String,
  replica_id : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    let tick = room.object.next_tick()
    let known = room.object
      .state()
      .proposals()
      .for_tick(tick)
      .values()
      .to_array()
    let certificate = room.authority.close(
      tick,
      room.object.decision().head_decision_hash(),
      known,
    ) catch {
      @prdt.BatchTickMismatch(_, _, id) => raise @prdt.InvalidTick(id)
      @prdt.DuplicateCommandId(id) => raise @prdt.ConflictingProposal(id)
    }
    room.object.close_tick(certificate)
    // Certify the new head so peers may compact to it and adopt it as a base.
    let base_certificate = room.authority.certify_base(
      room.object.next_tick(),
      room.object.decision().head_decision_hash(),
      @prdt.hash_value(
        room.object.protocol().hasher(),
        room.object.domain_state(),
      ),
    )
    room.object.merge({
      proposals: [],
      closures: [],
      base_certificates: [base_certificate],
    })
    let delta : @prdt.Delta[@mmo.GameCommand] = {
      proposals: [],
      closures: [certificate],
      base_certificates: [base_certificate],
    }
    success(room, {
      "certificate": certificate.to_json(),
      "base_certificate": base_certificate.to_json(),
      "delta": delta.to_json(),
      "decision": decision_json(room.object.decision()),
    })
  } catch {
    error => protocol_failure(error)
  }
}

///|
pub fn prdt_mmo_decision(
  snapshot : String,
  secret : String,
  replica_id : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    success(room, { "decision": decision_json(room.object.decision()) })
  } catch {
    error => protocol_failure(error)
  }
}

///|
/// Full knowledge as a delta, for anti-entropy.
pub fn prdt_mmo_delta(
  snapshot : String,
  secret : String,
  replica_id : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    success(room, { "delta": room.object.delta().to_json() })
  } catch {
    error => protocol_failure(error)
  }
}

///|
pub fn prdt_mmo_world(
  snapshot : String,
  secret : String,
  replica_id : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    success(room, {
      "world": room.object.domain_state().to_json(),
      "state_hash": room.object.state_hash().to_json(),
    })
  } catch {
    error => protocol_failure(error)
  }
}

///|
/// Summary of what this replica knows, to request only the missing rest.
pub fn prdt_mmo_digest(
  snapshot : String,
  secret : String,
  replica_id : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    success(room, { "digest": room.object.digest().to_json() })
  } catch {
    error => protocol_failure(error)
  }
}

///|
/// Everything a peer with `digest_json` is missing, including our base and
/// its certificate when the peer is behind a compacted history.
pub fn prdt_mmo_catchup(
  snapshot : String,
  secret : String,
  replica_id : String,
  digest_json : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    let digest : @prdt.KnowledgeDigest = decode_input(
      parse_input(digest_json, "digest"),
      "digest",
    )
    success(room, { "catchup": room.object.catchup_since(digest).to_json() })
  } catch {
    error => protocol_failure(error)
  }
}

///|
pub fn prdt_mmo_apply_catchup(
  snapshot : String,
  secret : String,
  replica_id : String,
  catchup_json : String,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    let catchup : @prdt.Catchup[@mmo.World, @mmo.GameCommand] = decode_input(
      parse_input(catchup_json, "catchup"),
      "catchup",
    )
    room.object.apply_catchup(catchup)
    success(room, { "decision": decision_json(room.object.decision()) })
  } catch {
    error => protocol_failure(error)
  }
}

///|
/// Fold finalized history into a certified base, keeping `retain_ticks` batches.
pub fn prdt_mmo_compact(
  snapshot : String,
  secret : String,
  replica_id : String,
  retain_ticks : Int,
) -> String {
  try {
    let room = open_room(snapshot, secret, replica_id)
    room.object.compact(retain_ticks~)
    success(room, {
      "base_next_tick": room.object.state().base().next_tick.to_json(),
    })
  } catch {
    error => protocol_failure(error)
  }
}
