///|
/// Seeded scenario generator for property-style tests.
///
/// A scenario is a fully specified run of the MMO protocol: proposals from
/// several replicas over several ticks and one certificate per tick closing
/// the proposals the authority had seen by then. It is expressed as a list of
/// deltas so tests can apply them in any order, duplicated, or partially.
pub let scenario_players : Array[String] = ["p1", "p2", "p3"]

///|
pub struct Scenario {
  protocol : @mmo.GameProtocol
  authority : @prdt.ClosureAuthority[@mmo.GameCommand]
  world : @mmo.World
  envelopes : Array[@prdt.Envelope[@mmo.GameCommand]]
  certificates : Array[@prdt.ClosureCertificate]
  /// One delta per proposal plus one per certificate, in a valid causal order.
  deltas : Array[@prdt.Delta[@mmo.GameCommand]]
  /// The state after every delta has been applied.
  full : @mmo.GameState
}

///|
pub fn random_world(rng : @runtime.Rng) -> @mmo.World {
  @mmo.World::new(
    scenario_players.map(fn(id) {
      (id, { hp: rng.int(41), max_hp: 40, mp: rng.int(101) })
    }),
  )
}

///|
pub fn random_scenario_command(rng : @runtime.Rng) -> @mmo.GameCommand {
  let actors = ["p1", "p2", "p3", "ghost"]
  if rng.chance(0.5) {
    @mmo.Damage(
      source=rng.pick(["p1", "p2", "p3", "monster"]),
      target=rng.pick(actors),
      amount=rng.int(47) - 1,
    )
  } else {
    @mmo.UseSkill(
      actor=rng.pick(actors),
      skill=rng.pick(["fireball", "heal", "dash"]),
      mp_cost=rng.int(62) - 1,
    )
  }
}

///|
pub fn generate_scenario(seed : Int) -> Scenario raise Error {
  let rng = @runtime.Rng::new(seed)
  let world = random_world(rng)
  let hasher = @prdt.Sha256Hasher::new()
  let authenticator = @prdt.SharedSecretAuthenticator::new(
    "authority", "scenario",
  )
  let finalizer = @prdt.SingleAuthorityFinalizer::new(
    hasher,
    authenticator,
    authenticator.public_key(),
  )
  let protocol = @mmo.game_protocol(finalizer, hasher, initial_world=world)
  let authority = @prdt.ClosureAuthority::new(
    hasher,
    authenticator,
    @mmo.game_order(),
  )
  let replica_count = 1 + rng.int(3)
  let replicas = []
  for index in 0..<replica_count {
    replicas.push(
      @prdt.ReplicatedDomain::new(protocol, "r" + index.to_string()),
    )
  }
  let auth = @prdt.ReplicatedDomain::new(protocol, "authority")
  let envelopes = []
  let certificates = []
  let deltas : Array[@prdt.Delta[@mmo.GameCommand]] = []
  let tick_count = 1 + rng.int(4)
  for tick in 0..<tick_count {
    let included = []
    let late : Array[@prdt.Delta[@mmo.GameCommand]] = []
    for _ in 0..<rng.int(5) {
      let replica = rng.pick(replicas)
      let proposal = replica.propose(tick, random_scenario_command(rng))
      envelopes.push(proposal.envelope)
      deltas.push(proposal.delta)
      if rng.chance(0.3) {
        late.push(proposal.delta)
      } else {
        included.push(proposal.envelope)
        auth.merge(proposal.delta)
      }
    }
    let certificate = authority.close(
      tick,
      auth.decision().head_decision_hash(),
      included,
    )
    auth.close_tick(certificate)
    certificates.push(certificate)
    deltas.push({
      proposals: [],
      closures: [certificate],
      base_certificates: [],
    })
    for delta in late {
      auth.merge(delta)
    }
  }
  let mut full = protocol.initial()
  for delta in deltas {
    full = protocol.apply_delta(full, delta)
  }
  { protocol, authority, world, envelopes, certificates, deltas, full }
}

///|
/// A state reached by applying a random subset of the scenario's deltas in a
/// random order.
pub fn Scenario::random_reachable(
  self : Scenario,
  rng : @runtime.Rng,
) -> @mmo.GameState raise Error {
  let subset = rng.shuffle(rng.subset(self.deltas))
  let mut state = self.protocol.initial()
  for delta in subset {
    state = self.protocol.apply_delta(state, delta)
  }
  state
}

///|
/// All deltas, shuffled, with random duplicates spliced in.
pub fn Scenario::delivery_schedule(
  self : Scenario,
  rng : @runtime.Rng,
) -> Array[@prdt.Delta[@mmo.GameCommand]] {
  let all = self.deltas.copy()
  for delta in rng.subset(self.deltas) {
    all.push(delta)
  }
  rng.shuffle(all)
}

///|
pub fn Scenario::fold(
  self : Scenario,
  deltas : Array[@prdt.Delta[@mmo.GameCommand]],
) -> @mmo.GameState raise Error {
  let mut state = self.protocol.initial()
  for delta in deltas {
    state = self.protocol.apply_delta(state, delta)
  }
  state
}
