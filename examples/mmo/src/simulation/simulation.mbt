///|
/// MMO wiring for the generic simulator: three players, random damage and
/// skills, closed either by a shared-secret authority or by a quorum of the
/// replicas themselves.
pub let players : Array[String] = ["player-a", "player-b", "player-c"]

///|
pub fn simulation_world() -> @mmo.World {
  @mmo.World::new(players.map(fn(id) { (id, { hp: 25, max_hp: 25, mp: 80 }) }))
}

///|
pub fn random_command(rng : @runtime.Rng, _tick : Int) -> @mmo.GameCommand {
  if rng.chance(0.5) {
    @mmo.Damage(
      source=rng.pick(players),
      target=rng.pick(players),
      amount=1 + rng.int(15),
    )
  } else {
    @mmo.UseSkill(
      actor=rng.pick(players),
      skill=rng.pick(["fireball", "heal"]),
      mp_cost=rng.int(30),
    )
  }
}

///|
pub fn run_mmo_simulation(
  seed~ : Int,
  steps? : Int = 400,
  replica_count? : Int = 3,
  compaction_retain? : Int,
  late_policy? : @runtime.LateCommandPolicy = RejectAsLate,
  codec? : &@prdt.Codec,
) -> @runtime.SimulationReport raise @prdt.ProtocolError {
  let hashing = @prdt.Hashing::new(@prdt.Sha256Hasher::new(), codec?)
  let authenticator = @prdt.SharedSecretAuthenticator::new("authority", "sim")
  let finalizer = @prdt.SingleAuthorityFinalizer::new(
    hashing,
    authenticator,
    authenticator.public_key(),
  )
  let protocol = @mmo.game_protocol(
    finalizer,
    hashing,
    initial_world=simulation_world(),
  )
  let authority = @prdt.ClosureAuthority::new(
    hashing,
    authenticator,
    @mmo.game_order(),
  )
  @runtime.run_simulation(
    protocol,
    SingleAuthority(authority),
    random_command,
    @runtime.SimulationOptions::new(
      seed~,
      steps~,
      replica_count~,
      compaction_retain?,
      late_policy~,
    ),
  )
}

///|
/// Every replica is a roster member; a majority closes each tick.
pub fn run_mmo_quorum_simulation(
  seed~ : Int,
  steps? : Int = 400,
  replica_count? : Int = 3,
  equivocators? : Array[Int] = [],
  compaction_retain? : Int,
  codec? : &@prdt.Codec,
) -> @runtime.SimulationReport raise Error {
  let hashing = @prdt.Hashing::new(@prdt.Sha256Hasher::new(), codec?)
  let keyed = @prdt.KeyedVerifier::new()
  let members = []
  let voters = []
  for index in 0..<replica_count {
    let id = "r" + index.to_string()
    let authenticator = @prdt.SharedSecretAuthenticator::new(id, "key-" + id)
    keyed.register(authenticator.public_key(), authenticator)
    members.push(authenticator.public_key())
    voters.push(@prdt.Voter::new(hashing, authenticator, @mmo.game_order()))
  }
  let roster = @prdt.QuorumRoster::new(members, replica_count / 2 + 1)
  let finalizer = @prdt.QuorumFinalizer::new(hashing, keyed, roster)
  let protocol = @mmo.game_protocol(
    finalizer,
    hashing,
    initial_world=simulation_world(),
  )
  @runtime.run_simulation(
    protocol,
    Quorum(finalizer, voters, equivocators),
    random_command,
    @runtime.SimulationOptions::new(
      seed~,
      steps~,
      replica_count~,
      compaction_retain?,
    ),
  )
}
