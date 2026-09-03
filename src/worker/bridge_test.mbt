///|
fn field(response : String, key : String) -> Json raise Error {
  guard @json.parse(response) is Object(fields) else { fail("response object") }
  match fields.get(key) {
    Some(value) => value
    None => fail("missing " + key)
  }
}

///|
fn snapshot_of(response : String) -> String raise Error {
  field(response, "snapshot").stringify()
}

///|
test "bridge resolves the lethal race through JSON strings and a client converges" {
  let secret = "dev-only-secret"
  // Client replica X proposes a skill and ships the delta to the authority.
  let x1 = prdt_mmo_propose(
    "",
    secret,
    "X",
    0,
    @mmo.fireball().to_json().stringify(),
  )
  assert_eq(field(x1, "ok"), true)
  let x_snapshot = snapshot_of(x1)
  let x_delta = field(x1, "delta").stringify()
  let a1 = prdt_mmo_merge("", secret, "authority", x_delta)
  assert_eq(field(a1, "ok"), true)
  let a2 = prdt_mmo_propose(
    snapshot_of(a1),
    secret,
    "authority",
    0,
    @mmo.lethal_hit().to_json().stringify(),
  )
  assert_eq(field(a2, "ok"), true)
  guard field(a2, "decision") is Object(decision) &&
    decision.get("commands").unwrap() is Object(commands) else {
    fail("decision commands")
  }
  assert_eq(commands.get("X:0").unwrap(), { "status": "Pending" })

  let a3 = prdt_mmo_close(snapshot_of(a2), secret, "authority")
  assert_eq(field(a3, "ok"), true)
  guard field(a3, "certificate") is Object(certificate) else {
    fail("certificate")
  }
  assert_eq(certificate.get("ordered_command_ids").unwrap(), [
    "authority:0", "X:0",
  ])
  let a4 = prdt_mmo_decision(snapshot_of(a3), secret, "authority")
  guard field(a4, "decision") is Object(final_decision) &&
    final_decision.get("commands").unwrap() is Object(final_commands) else {
    fail("final decision")
  }
  guard final_commands.get("X:0").unwrap() is Object(skill) else {
    fail("skill")
  }
  assert_eq(skill.get("status").unwrap(), "Rejected")
  assert_eq(skill.get("reason").unwrap(), { "type": "ActorDead" })
  guard final_commands.get("authority:0").unwrap() is Object(damage) else {
    fail("damage")
  }
  assert_eq(damage.get("status").unwrap(), "Accepted")
  assert_eq(final_decision.get("committed_ticks").unwrap(), [0])
  let world = prdt_mmo_world(snapshot_of(a4), secret, "authority")
  assert_eq(field(world, "next_tick"), 1)
  assert_eq(field(world, "world"), {
    "players": [["player-a", { "hp": 0, "max_hp": 10, "mp": 100 }]],
  })

  // Anti-entropy: X pulls the authority's full delta and reaches the same verdicts.
  let full = prdt_mmo_delta(snapshot_of(a4), secret, "authority")
  let x2 = prdt_mmo_merge(
    x_snapshot,
    secret,
    "X",
    field(full, "delta").stringify(),
  )
  assert_eq(field(x2, "ok"), true)
  let x_world = prdt_mmo_world(snapshot_of(x2), secret, "X")
  assert_eq(field(x_world, "state_hash"), field(world, "state_hash"))
}

///|
test "bridge reports protocol errors and bad input as failures" {
  let secret = "dev-only-secret"
  let y1 = prdt_mmo_propose(
    "",
    secret,
    "Y",
    5,
    @mmo.fireball().to_json().stringify(),
  )
  let envelope = field(y1, "envelope")
  guard envelope is Object(fields) else { fail("envelope") }
  fields["command"] = @mmo.lethal_hit().to_json()
  let conflicting : Json = {
    "proposals": [Json::object(fields)],
    "closures": [],
  }
  let response = prdt_mmo_merge(
    snapshot_of(y1),
    secret,
    "Y",
    conflicting.stringify(),
  )
  assert_eq(field(response, "ok"), false)
  assert_eq(field(response, "error"), "ConflictingProposal")
  let malformed = prdt_mmo_merge("", secret, "Y", "{not json")
  assert_eq(field(malformed, "ok"), false)
  assert_eq(field(malformed, "error"), "SnapshotMismatch")
  // A forged authority secret cannot close a tick for replicas using the real one.
  let forged = prdt_mmo_close("", "attacker", "authority")
  let victim = prdt_mmo_merge(
    "",
    secret,
    "X",
    field(forged, "delta").stringify(),
  )
  assert_eq(field(victim, "error"), "InvalidCertificate")
}

///|
test "bridge syncs by digest, transfers a certified base, and refuses an unsigned one" {
  let secret = "dev-only-secret"
  // Authority closes three ticks (one with a hit), certifying every head.
  let mut authority = ""
  for tick in 0..<3 {
    if tick == 0 {
      authority = snapshot_of(
        prdt_mmo_propose(
          authority,
          secret,
          "authority",
          0,
          @mmo.lethal_hit().to_json().stringify(),
        ),
      )
    }
    authority = snapshot_of(prdt_mmo_close(authority, secret, "authority"))
  }
  let compacted = prdt_mmo_compact(authority, secret, "authority", 0)
  assert_eq(field(compacted, "base_next_tick"), 3)
  authority = snapshot_of(compacted)

  // A fresh client asks for what it is missing and receives the base.
  let client_digest = field(prdt_mmo_digest("", secret, "X"), "digest").stringify()
  let catchup = field(
    prdt_mmo_catchup(authority, secret, "authority", client_digest),
    "catchup",
  )
  let applied = prdt_mmo_apply_catchup("", secret, "X", catchup.stringify())
  assert_eq(field(applied, "ok"), true)
  assert_eq(field(applied, "next_tick"), 3)
  let client_world = prdt_mmo_world(snapshot_of(applied), secret, "X")
  assert_eq(
    field(client_world, "state_hash"),
    field(prdt_mmo_world(authority, secret, "authority"), "state_hash"),
  )

  // Stripping the certificate makes the base unacceptable.
  guard catchup is Object(fields) else { fail("catchup object") }
  fields["certificate"] = Json::null()
  let refused = prdt_mmo_apply_catchup(
    "",
    secret,
    "X",
    Json::object(fields).stringify(),
  )
  assert_eq(field(refused, "ok"), false)
  assert_eq(field(refused, "error"), "UnauthenticatedBase")
}
