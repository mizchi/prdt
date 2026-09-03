///|
struct AuthoritySetup {
  protocol : @mmo.GameProtocol
  authority : @prdt.ClosureAuthority[@mmo.GameCommand]
}

///|
fn authority_setup() -> AuthoritySetup {
  let hasher = @prdt.Sha256Hasher::new()
  let authenticator = @prdt.SharedSecretAuthenticator::new("authority", "late")
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
test "MoveToNextTick re-issues a late skill at the next open tick and it gets accepted" {
  let s = authority_setup()
  let authority = @runtime.Replica::new(
    s.protocol,
    "authority",
    @runtime.InMemoryCheckpointStore::new(),
    authority=s.authority,
  )
  let x = @runtime.Replica::new(
    s.protocol,
    "X",
    @runtime.InMemoryCheckpointStore::new(),
    late_policy=MoveToNextTick(max_moves=2),
  )
  // X proposes for tick 0, but the authority closes tick 0 before hearing it.
  let original = x.propose(0, @mmo.fireball())
  let _ = authority.close_next_tick()
  for delta in authority.drain_outbox() {
    x.receive(delta)
  }
  assert_eq(x.decision().of(original.id), @prdt.DecisionLate(0))
  assert_eq(x.moves(), [(original.id, "X:1")])
  let reissued = x.object().state().proposals().for_tick(1).get("X:1").unwrap()
  assert_eq(reissued.command, @mmo.fireball())
  // The re-issued proposal reaches the authority, which closes tick 1 with it.
  for delta in x.drain_outbox() {
    authority.receive(delta)
  }
  let _ = authority.close_next_tick()
  for delta in authority.drain_outbox() {
    x.receive(delta)
  }
  assert_eq(
    x.decision().of("X:1"),
    @prdt.DecisionAccepted(
      1,
      @mmo.GameEvent::SkillActivated(
        actor=@mmo.player_a,
        skill="fireball",
        mp_cost=30,
      ),
    ),
  )
  // The original stays late forever; nothing else was re-issued.
  assert_eq(x.decision().of(original.id), @prdt.DecisionLate(0))
  assert_eq(x.moves().length(), 1)
}

///|
test "MoveToNextTick stops after max_moves and survives a restart" {
  let s = authority_setup()
  let authority = @runtime.Replica::new(
    s.protocol,
    "authority",
    @runtime.InMemoryCheckpointStore::new(),
    authority=s.authority,
  )
  let store = @runtime.InMemoryCheckpointStore::new()
  let x = @runtime.Replica::new(
    s.protocol,
    "X",
    store,
    late_policy=MoveToNextTick(max_moves=1),
  )
  let _ = x.propose(0, @mmo.fireball())
  // Two closures without X's commands: the re-issue at tick 1 is late too.
  let _ = authority.close_next_tick()
  let _ = authority.close_next_tick()
  for delta in authority.drain_outbox() {
    x.receive(delta)
  }
  assert_eq(x.moves(), [("X:0", "X:1")])
  assert_eq(x.decision().of("X:1"), @prdt.DecisionLate(1))
  // max_moves=1: the lineage is not moved again.
  let _ = authority.close_next_tick()
  for delta in authority.drain_outbox() {
    x.receive(delta)
  }
  assert_eq(x.moves(), [("X:0", "X:1")])
  assert_eq(x.next_local_sequence_public(), 2)
  // A restart from checkpoint keeps the move ledger, so nothing is re-issued twice.
  x.restart()
  assert_eq(x.moves(), [("X:0", "X:1")])
  assert_eq(x.reissue_late(), [])
}

///|
fn[S, C, E, R] @runtime.Replica::next_local_sequence_public(
  self : @runtime.Replica[S, C, E, R],
) -> Int {
  self.object().next_local_sequence()
}

///|
test "simulation with MoveToNextTick re-issues late commands and still converges" {
  let mut reissues = 0
  for seed in 1..<=30 {
    let report = run_mmo_simulation(
      seed~,
      late_policy=MoveToNextTick(max_moves=3),
    )
    assert_eq(report.protocol_errors, [])
    assert_true(report.converged)
    reissues += report.counters.reissues
  }
  assert_true(reissues > 0)
}
