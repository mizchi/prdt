///|
/// Negative test 1: `alive` as a proposal-time PRDT precondition is unstable.
///
/// A precondition is stable when `pre(s)` implies `pre(join(s, d))` for every
/// delta `d`. A concurrent Damage delta flips `hp > 0` from true to false,
/// so a replica that accepted the skill "because the actor was alive" and one
/// that rejected it "because the actor was dead" are both locally justified
/// and can never agree. The framework never evaluates `alive` at proposal time.
fn speculative_world(
  state : @prdt.ProposalState[@mmo.GameCommand],
  tick : Int,
) -> @mmo.World {
  let mut world = @mmo.lethal_race_world()
  let known = state.for_tick(tick).values().to_array()
  for envelope in @prdt.sort_commands(known, @mmo.game_order()) {
    match @mmo.validate_game_command(world, envelope.command) {
      Accept(event) => world = @mmo.apply_game_event(world, event)
      Reject(_) => ()
    }
  }
  world
}

///|
/// The unsafe design: guard the proposal with `alive` evaluated on local knowledge.
fn alive_guard(
  state : @prdt.ProposalState[@mmo.GameCommand],
  envelope : @prdt.Envelope[@mmo.GameCommand],
) -> Bool {
  match envelope.command {
    @mmo.UseSkill(actor~, ..) =>
      speculative_world(state, envelope.tick).is_alive(actor)
    _ => false
  }
}

///|
fn env(
  replica : String,
  seq : Int,
  tick : Int,
  command : @mmo.GameCommand,
) -> @prdt.Envelope[@mmo.GameCommand] {
  {
    id: @prdt.command_id(replica, seq),
    tick,
    submitted_by: replica,
    local_sequence: seq,
    command,
  }
}

///|
test "negative: alive guard is not stable under join and splits replicas" {
  let skill = env("X", 0, 0, @mmo.fireball())
  let damage = env("Y", 0, 0, @mmo.lethal_hit())
  let empty : @prdt.ProposalState[@mmo.GameCommand] = @prdt.ProposalState::empty()
  let with_damage = empty.add(damage)
  assert_true(alive_guard(empty, skill))
  assert_false(alive_guard(with_damage, skill))
  assert_true(with_damage.equals(empty.merge(with_damage)))

  // X knows only its own skill; Y saw the damage first.
  let x = empty.add(skill)
  let y = empty.add(damage).add(skill)
  assert_true(alive_guard(x, skill))
  assert_false(alive_guard(y, skill))
}

///|
struct Setup {
  protocol : @mmo.GameProtocol
  authority : @prdt.ClosureAuthority[@mmo.GameCommand]
}

///|
fn setup() -> Setup {
  let hasher = @prdt.Sha256Hasher::new()
  let authenticator = @prdt.SharedSecretAuthenticator::new(
    "authority", "negative",
  )
  let finalizer = @prdt.SingleAuthorityFinalizer::new(
    hasher,
    authenticator,
    authenticator.public_key(),
  )
  {
    protocol: @mmo.game_protocol(finalizer, hasher),
    authority: @prdt.ClosureAuthority::new(
      hasher,
      authenticator,
      @mmo.game_order(),
    ),
  }
}

///|
fn close_next(
  object : @mmo.GameObject,
  authority : @prdt.ClosureAuthority[@mmo.GameCommand],
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
test "negative: the framework evaluates alive only inside the finalized batch, so every replica agrees" {
  let s = setup()
  let skill = env("X", 0, 0, @mmo.fireball())
  let damage = env("Y", 0, 0, @mmo.lethal_hit())
  let a = @prdt.ReplicatedDomain::new(s.protocol, "A")
  a.merge({ proposals: [skill], closures: [], base_certificates: [] })
  assert_eq(a.decision().of("X:0"), @prdt.DecisionPending) // not Accepted "because alive"
  a.merge({ proposals: [damage], closures: [], base_certificates: [] })
  let certificate = close_next(a, s.authority)
  let b = @prdt.ReplicatedDomain::new(s.protocol, "B")
  b.merge({
    proposals: [skill, damage],
    closures: [certificate],
    base_certificates: [],
  })
  assert_eq(
    a.decision().of("X:0"),
    @prdt.DecisionRejected(0, @mmo.GameRejection::ActorDead),
  )
  assert_eq(b.decision().of("X:0"), a.decision().of("X:0"))
  assert_eq(b.domain_state().hp(@mmo.player_a), Some(0))
}

///|
/// Negative test 2: accepting before closure breaks decision monotonicity.
///
/// An "eager" finalizer that marks a skill Accepted as soon as it is known
/// locally must later flip it to Rejected when a lethal Damage for the same
/// tick arrives: exactly the Accepted -> Rejected transition the decision
/// order forbids.
fn eager_decision(
  protocol : @mmo.GameProtocol,
  state : @prdt.ProposalState[@mmo.GameCommand],
) -> Map[String, @prdt.CommandDecision[@mmo.GameEvent, @mmo.GameRejection]] raise Error {
  let known = state.for_tick(0).values().to_array()
  let batch = @prdt.resolve_batch(
    0,
    @mmo.lethal_race_world(),
    known,
    protocol.domain(),
    protocol.order(),
    protocol.hasher(),
  )
  let out : Map[
    String,
    @prdt.CommandDecision[@mmo.GameEvent, @mmo.GameRejection],
  ] = Map([])
  for resolved in batch.results {
    out[resolved.envelope.id] = match resolved.verdict {
      @prdt.Accepted(event) => @prdt.DecisionAccepted(0, event)
      @prdt.Rejected(reason) => @prdt.DecisionRejected(0, reason)
    }
  }
  out
}

///|
test "negative: premature acceptance moves Accepted -> Rejected when late damage arrives" {
  let s = setup()
  let skill = env("X", 0, 0, @mmo.fireball())
  let damage = env("Y", 0, 0, @mmo.lethal_hit())
  let x = @prdt.ReplicatedDomain::new(s.protocol, "X")
  x.merge({ proposals: [skill], closures: [], base_certificates: [] })
  let before = eager_decision(s.protocol, x.state().proposals())
  assert_true(before.get("X:0").unwrap() is @prdt.DecisionAccepted(_, _))
  x.merge({ proposals: [damage], closures: [], base_certificates: [] })
  let after = eager_decision(s.protocol, x.state().proposals())
  assert_true(after.get("X:0").unwrap() is @prdt.DecisionRejected(_, _))
  assert_false(
    @prdt.command_decision_less_or_equal(
      before.get("X:0").unwrap(),
      after.get("X:0").unwrap(),
    ),
  )
}

///|
test "negative contrast: the framework keeps the skill Pending until closure, so the decision only grows" {
  let s = setup()
  let skill = env("X", 0, 0, @mmo.fireball())
  let damage = env("Y", 0, 0, @mmo.lethal_hit())
  let x = @prdt.ReplicatedDomain::new(s.protocol, "X")
  x.merge({ proposals: [skill], closures: [], base_certificates: [] })
  let d0 = x.decision()
  assert_eq(d0.of("X:0"), @prdt.DecisionPending)
  x.merge({ proposals: [damage], closures: [], base_certificates: [] })
  let d1 = x.decision()
  assert_true(@prdt.decision_less_or_equal(d0, d1))
  let _ = close_next(x, s.authority)
  let d2 = x.decision()
  assert_true(@prdt.decision_less_or_equal(d1, d2))
  assert_eq(
    d2.of("X:0"),
    @prdt.DecisionRejected(0, @mmo.GameRejection::ActorDead),
  )
}
