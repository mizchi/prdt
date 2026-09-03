///|
struct Setup {
  protocol : GameProtocol
  authority : @prdt.ClosureAuthority[GameCommand]
  authenticator : @prdt.SharedSecretAuthenticator
  hasher : @prdt.Sha256Hasher
}

///|
fn setup(secret? : String, initial_world? : World) -> Setup {
  let hasher = @prdt.Sha256Hasher::new()
  let authenticator = @prdt.SharedSecretAuthenticator::new(
    "authority",
    secret.unwrap_or("test-secret"),
  )
  let finalizer = @prdt.SingleAuthorityFinalizer::new(
    hasher,
    authenticator,
    authenticator.public_key(),
  )
  let protocol = game_protocol(finalizer, hasher, initial_world?)
  let authority = @prdt.ClosureAuthority::new(
    hasher,
    authenticator,
    game_order(),
  )
  { protocol, authority, authenticator, hasher }
}

///|
fn env(
  replica : String,
  seq : Int,
  tick : Int,
  command : GameCommand,
) -> @prdt.Envelope[GameCommand] {
  {
    id: @prdt.command_id(replica, seq),
    tick,
    submitted_by: replica,
    local_sequence: seq,
    command,
  }
}

///|
fn proposals(
  envelopes : Array[@prdt.Envelope[GameCommand]],
) -> @prdt.Delta[GameCommand] {
  { proposals: envelopes, closures: [], base_certificates: [] }
}

///|
fn closures(
  certificates : Array[@prdt.ClosureCertificate],
) -> @prdt.Delta[GameCommand] {
  { proposals: [], closures: certificates, base_certificates: [] }
}

///|
/// Close the next tick of `object` with everything it currently knows for it.
fn close_next(
  object : GameObject,
  authority : @prdt.ClosureAuthority[GameCommand],
) -> @prdt.ClosureCertificate raise Error {
  let tick = object.next_tick()
  let known = object.state().proposals().for_tick(tick).values().to_array()
  let certificate = authority.close(
    tick,
    object.decision().head_decision_hash(),
    known,
  )
  object.close_tick(certificate)
  certificate
}

///|
test "lethal damage racing a skill converges in either arrival order" {
  let s = setup()
  let x = @prdt.ReplicatedDomain::new(s.protocol, "X")
  let y = @prdt.ReplicatedDomain::new(s.protocol, "Y")
  let skill = x.propose(0, fireball())
  let damage = y.propose(0, lethal_hit())
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  auth.merge(damage.delta)
  auth.merge(skill.delta)
  let certificate = close_next(auth, s.authority)
  assert_eq(certificate.ordered_command_ids, ["Y:0", "X:0"])

  // X: skill, closure, then damage. Y: damage, skill, closure.
  x.merge(closures([certificate]))
  assert_eq(x.decision().of("X:0"), @prdt.DecisionPending) // closed, waiting for Y:0
  x.merge(damage.delta)
  y.merge(skill.delta)
  y.merge(closures([certificate]))
  for replica in [x, y, auth] {
    let decision = replica.decision()
    assert_eq(
      decision.of("Y:0"),
      @prdt.DecisionAccepted(
        0,
        GameEvent::DamageApplied(source="monster", target=player_a, amount=20),
      ),
    )
    assert_eq(
      decision.of("X:0"),
      @prdt.DecisionRejected(0, GameRejection::ActorDead),
    )
    assert_eq(replica.domain_state().hp(player_a), Some(0))
    assert_eq(replica.state_hash(), auth.state_hash())
  }
}

///|
test "a late command never joins a closed tick and the committed result is unchanged" {
  let s = setup()
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  auth.merge(proposals([env("Y", 0, 0, lethal_hit())]))
  let _ = close_next(auth, s.authority)
  let before = auth.decision()
  auth.merge(proposals([env("X", 0, 0, fireball())]))
  let after = auth.decision()
  assert_eq(after.of("X:0"), @prdt.DecisionLate(0))
  assert_eq(after.head_decision_hash(), before.head_decision_hash())
  assert_eq(after.committed_ticks(), [0])
  let committed = auth.state().committed().batches()
  assert_eq(committed[0].result.results.map(fn(r) { r.envelope.id }), ["Y:0"])
}

///|
test "ticks chain: a skill in tick 1 is rejected because tick 0 killed the actor" {
  let s = setup()
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  auth.merge(proposals([env("Y", 0, 0, lethal_hit())]))
  let _ = close_next(auth, s.authority)
  auth.merge(proposals([env("X", 0, 1, fireball())]))
  let _ = close_next(auth, s.authority)
  assert_eq(
    auth.decision().of("X:0"),
    @prdt.DecisionRejected(1, GameRejection::ActorDead),
  )
  assert_eq(auth.decision().committed_ticks(), [0, 1])
  let _ = close_next(auth, s.authority) // empty tick 2
  assert_eq(auth.next_tick(), 3)
}

///|
test "a certificate from an unknown authority is refused and the state is untouched" {
  let forged = setup(secret="attacker")
  let real = setup(secret="real")
  let auth = @prdt.ReplicatedDomain::new(real.protocol, "A")
  auth.merge(proposals([env("Y", 0, 0, lethal_hit())]))
  let certificate = forged.authority.close(0, real.protocol.genesis_hash(), [
    env("Y", 0, 0, lethal_hit()),
  ])
  let before = auth.state_hash()
  assert_eq(close_error(auth, certificate), Some(@prdt.InvalidCertificate(0)))
  assert_eq(auth.state_hash(), before)
  assert_eq(auth.decision().of("Y:0"), @prdt.DecisionPending)
}

///|
test "malformed, wrong-parent, and non-canonical certificates are refused" {
  let s = setup()
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  let empty = s.authority.close(0, s.protocol.genesis_hash(), [])
  assert_eq(
    close_error(auth, { ..empty, ordered_command_ids: ["Y:0"] }),
    Some(
      @prdt.MalformedCertificate(0, "ordered_commands_hash does not match ids"),
    ),
  )
  let wrong_parent = s.authority.close(0, "not-the-genesis-hash", [])
  assert_eq(close_error(auth, wrong_parent), Some(@prdt.ChainMismatch(0)))
  assert_eq(auth.decision().committed_ticks(), [])

  auth.merge(
    proposals([env("X", 0, 0, fireball()), env("Y", 0, 0, lethal_hit())]),
  )
  let swapped_ids = ["X:0", "Y:0"] // canonical is Damage (Y) first
  let payload : @prdt.ClosurePayload = {
    tick: 0,
    parent_decision_hash: s.protocol.genesis_hash(),
    ordered_commands_hash: @prdt.hash_command_ids(s.hasher, swapped_ids),
  }
  let swapped : @prdt.ClosureCertificate = {
    tick: 0,
    parent_decision_hash: payload.parent_decision_hash,
    ordered_command_ids: swapped_ids,
    ordered_commands_hash: payload.ordered_commands_hash,
    attestations: [
      {
        signer: s.authenticator.public_key(),
        signature: s.authenticator.sign(payload.digest(s.hasher)),
      },
    ],
  }
  assert_eq(close_error(auth, swapped), Some(@prdt.OrderMismatch(0)))
  assert_eq(auth.decision().committed_ticks(), [])
}

///|
test "a closure whose commands are not yet known waits, then materializes" {
  let s = setup()
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  auth.merge(proposals([env("Y", 0, 0, lethal_hit())]))
  let certificate = close_next(auth, s.authority)
  let late_replica = @prdt.ReplicatedDomain::new(s.protocol, "B")
  late_replica.merge(closures([certificate]))
  assert_eq(late_replica.decision().committed_ticks(), [])
  assert_eq(late_replica.next_tick(), 0)
  late_replica.merge(proposals([env("Y", 0, 0, lethal_hit())]))
  assert_eq(late_replica.decision().committed_ticks(), [0])
  assert_eq(late_replica.state_hash(), auth.state_hash())
}

///|
test "snapshot restore reproduces the state and never reuses a local sequence" {
  let s = setup()
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  auth.merge(
    proposals([env("Y", 0, 0, lethal_hit()), env("X", 0, 0, fireball())]),
  )
  let _ = close_next(auth, s.authority)
  let _ = auth.propose(1, fireball())
  let json = @json.parse(auth.snapshot().stringify())
  let restored = @prdt.ReplicatedDomain::restore(s.protocol, json)
  assert_eq(restored.state_hash(), auth.state_hash())
  assert_true(s.protocol.states_equal(restored.state(), auth.state()))
  assert_eq(restored.next_local_sequence(), 1)
  assert_eq(restored.propose(1, lethal_hit()).envelope.id, "A:1")
}

///|
test "a tampered snapshot is refused" {
  let s = setup()
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  auth.merge(proposals([env("Y", 0, 0, lethal_hit())]))
  let _ = close_next(auth, s.authority)
  let snapshot = auth.snapshot()
  guard snapshot is Object(fields) else { fail("snapshot object") }
  guard fields.get("state").unwrap() is Object(state_fields) else {
    fail("state object")
  }
  guard state_fields.get("committed").unwrap() is Array([Object(batch)]) else {
    fail("one batch")
  }
  batch["result_hash"] = "0000".to_json()
  let outcome = try {
    let _ = @prdt.ReplicatedDomain::restore(s.protocol, snapshot)
    None
  } catch {
    error => Some(error)
  }
  assert_eq(
    outcome,
    Some(
      @prdt.SnapshotMismatch("committed prefix does not match recomputation"),
    ),
  )
}

///|
fn quorum_setup(
  ids : Array[String],
  threshold : Int,
) -> (
  @prdt.QuorumRoster,
  Map[String, @prdt.SharedSecretAuthenticator],
  @prdt.Sha256Hasher,
) raise Error {
  let hasher = @prdt.Sha256Hasher::new()
  let auths : Map[String, @prdt.SharedSecretAuthenticator] = Map([])
  for id in ids {
    auths[id] = @prdt.SharedSecretAuthenticator::new(id, "key-" + id)
  }
  let roster = @prdt.QuorumRoster::new(
    ids.map(fn(id) { @prdt.PublicKey(id) }),
    threshold,
  )
  (roster, auths, hasher)
}

///|
/// Verifier that consults every roster member's authenticator.
struct RosterVerifier {
  auths : Map[String, @prdt.SharedSecretAuthenticator]
}

///|
impl @prdt.Verifier for RosterVerifier with fn verify(
  self,
  key,
  digest,
  signature,
) {
  match self.auths.get(key.0) {
    Some(auth) => auth.verify(key, digest, signature)
    None => false
  }
}

///|
test "quorum finalizer closes with two of three votes and drives the domain" {
  let (roster, auths, hasher) = quorum_setup(["a", "b", "c"], 2)
  let verifier = RosterVerifier::{ auths, }
  let finalizer = @prdt.QuorumFinalizer::new(hasher, verifier, roster)
  let protocol = game_protocol(finalizer, hasher)
  let object = @prdt.ReplicatedDomain::new(protocol, "R")
  let skill = env("X", 0, 0, fireball())
  let damage = env("Y", 0, 0, lethal_hit())
  object.merge(proposals([skill, damage]))
  let voter = fn(id : String) {
    @prdt.Voter::new(hasher, auths.get(id).unwrap(), game_order())
  }
  let mut votes = @prdt.VoteState::empty()
  votes = votes.add(
    voter("a").vote(0, protocol.genesis_hash(), [skill, damage]),
  )
  assert_eq(@prdt.assemble_quorum_certificate(votes, 0, roster), None)
  votes = votes.add(
    voter("b").vote(0, protocol.genesis_hash(), [damage, skill]),
  )
  let certificate = @prdt.assemble_quorum_certificate(votes, 0, roster).unwrap()
  assert_eq(certificate.attestations.length(), 2)
  object.close_tick(certificate)
  assert_eq(
    object.decision().of("X:0"),
    @prdt.DecisionRejected(0, GameRejection::ActorDead),
  )
  assert_eq(object.domain_state().hp(player_a), Some(0))

  // Under-signed and outsider-signed certificates are refused.
  let single : @prdt.ClosureCertificate = {
    ..certificate,
    attestations: [certificate.attestations[0]],
  }
  let fresh = @prdt.ReplicatedDomain::new(protocol, "F")
  fresh.merge(proposals([skill, damage]))
  assert_eq(close_error(fresh, single), Some(@prdt.InvalidCertificate(0)))
  let outsider = @prdt.SharedSecretAuthenticator::new("z", "key-z")
  let payload = @prdt.ClosurePayload::of(certificate)
  let forged : @prdt.ClosureCertificate = {
    ..certificate,
    attestations: [
      certificate.attestations[0],
      {
        signer: outsider.public_key(),
        signature: outsider.sign(payload.digest(hasher)),
      },
    ],
  }
  assert_eq(close_error(fresh, forged), Some(@prdt.InvalidCertificate(0)))
}

///|
test "an equivocating voter is excluded so competing payloads cannot both close a tick" {
  let (roster, auths, hasher) = quorum_setup(["a", "b", "c"], 2)
  let genesis = "g"
  let voter = fn(id : String) {
    @prdt.Voter::new(hasher, auths.get(id).unwrap(), game_order())
  }
  let damage = env("Y", 0, 0, lethal_hit())
  let skill = env("X", 0, 0, fireball())
  let honest = @prdt.VoteState::empty().add(
    voter("b").vote(0, genesis, [damage]),
  )
  let a1 = @prdt.VoteState::empty().add(voter("a").vote(0, genesis, [damage]))
  let a2 = @prdt.VoteState::empty().add(
    voter("a").vote(0, genesis, [damage, skill]),
  )
  assert_true(
    @prdt.assemble_quorum_certificate(honest.merge(a1), 0, roster) is Some(_),
  )
  let all = honest.merge(a1).merge(a2)
  assert_eq(all.tally(0, roster.members()).equivocators, ["a"])
  assert_eq(@prdt.assemble_quorum_certificate(all, 0, roster), None)
  assert_true(all.equals(a2.merge(a1.merge(honest))))
  // With three honest votes split 2:1, only the majority payload closes.
  let split = @prdt.VoteState::empty()
    .add(voter("a").vote(0, genesis, [damage]))
    .add(voter("b").vote(0, genesis, [damage, skill]))
    .add(voter("c").vote(0, genesis, [damage]))
  assert_eq(
    @prdt.assemble_quorum_certificate(split, 0, roster).unwrap().ordered_command_ids,
    ["Y:0"],
  )
}

///|
fn close_error(
  object : GameObject,
  certificate : @prdt.ClosureCertificate,
) -> @prdt.ProtocolError? {
  try {
    object.close_tick(certificate)
    None
  } catch {
    error => Some(error)
  }
}
