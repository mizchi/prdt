///|
let property_seeds : Int = 60

///|
test "lattice laws hold for the whole replicated state over random reachable states" {
  for seed in 1..<=property_seeds {
    let scenario = generate_scenario(seed)
    let rng = @runtime.Rng::new(1000 + seed)
    let a = scenario.random_reachable(rng)
    let b = scenario.random_reachable(rng)
    let c = scenario.random_reachable(rng)
    assert_eq(scenario.protocol.lattice_law_violations(a, b, c), [])
  }
}

///|
test "delivery order, duplication, and merge-tree shape do not change the converged state" {
  for seed in 1..<=property_seeds {
    let scenario = generate_scenario(seed)
    let rng = @runtime.Rng::new(2000 + seed)
    let schedule_a = scenario.delivery_schedule(rng)
    let schedule_b = scenario.delivery_schedule(rng)
    let state_a = scenario.fold(schedule_a)
    let state_b = scenario.fold(schedule_b)
    let expected = scenario.protocol.state_hash(scenario.full)
    assert_eq(scenario.protocol.state_hash(state_a), expected)
    assert_eq(scenario.protocol.state_hash(state_b), expected)
    assert_eq(
      scenario.protocol.decision(state_a).commands,
      scenario.protocol.decision(scenario.full).commands,
    )
    let half = schedule_a.length() / 2
    let left = scenario.fold(schedule_a[0:half].to_owned())
    let right = scenario.fold(schedule_a[half:].to_owned())
    assert_eq(
      scenario.protocol.state_hash(scenario.protocol.join(left, right)),
      expected,
    )
  }
}

///|
test "snapshot round trip preserves the state hash and decision" {
  for seed in 1..<=property_seeds {
    let scenario = generate_scenario(seed)
    let json = @json.parse(
      scenario.protocol.snapshot(scenario.full).stringify(),
    )
    let restored = scenario.protocol.restore(json)
    assert_eq(
      scenario.protocol.state_hash(restored),
      scenario.protocol.state_hash(scenario.full),
    )
    assert_true(scenario.protocol.states_equal(restored, scenario.full))
    assert_eq(
      scenario.protocol.decision(restored).commands,
      scenario.protocol.decision(scenario.full).commands,
    )
  }
}

///|
test "decision monotonicity: decision(state) <= decision(apply_delta(state, delta)) and under join" {
  for seed in 1..<=property_seeds {
    let scenario = generate_scenario(seed)
    let rng = @runtime.Rng::new(3000 + seed)
    let state = scenario.random_reachable(rng)
    let delta = rng.pick(scenario.deltas)
    let before = scenario.protocol.decision(state)
    let after = scenario.protocol.decision(
      scenario.protocol.apply_delta(state, delta),
    )
    assert_true(@prdt.decision_less_or_equal(before, after))
    let other = scenario.random_reachable(rng)
    let joined = scenario.protocol.decision(
      scenario.protocol.join(state, other),
    )
    assert_true(@prdt.decision_less_or_equal(before, joined))
    assert_true(
      @prdt.decision_less_or_equal(scenario.protocol.decision(other), joined),
    )
  }
}

///|
test "closure uniqueness and prefix safety across reachable states" {
  for seed in 1..<=property_seeds {
    let scenario = generate_scenario(seed)
    let rng = @runtime.Rng::new(4000 + seed)
    let a = scenario.random_reachable(rng)
    let b = scenario.random_reachable(rng)
    for certificate in a.closures().list() {
      let expected = scenario.certificates.filter(fn(c) {
        c.tick == certificate.tick
      })
      assert_eq(expected.length(), 1)
      assert_eq(
        certificate.ordered_commands_hash,
        expected[0].ordered_commands_hash,
      )
    }
    assert_true(@prdt.logs_are_prefix_compatible(a.committed(), b.committed()))
  }
}

///|
test "a late command is final: once DecisionLate it never becomes anything else" {
  for seed in 1..<=property_seeds {
    let scenario = generate_scenario(seed)
    let rng = @runtime.Rng::new(5000 + seed)
    let partial = scenario.protocol.decision(scenario.random_reachable(rng))
    let full = scenario.protocol.decision(scenario.full)
    for id, decision in partial.commands {
      if decision is @prdt.DecisionLate(_) {
        assert_eq(full.of(id), decision)
      }
    }
  }
}

///|
/// PRDT agreement alone would be satisfied by every replica consistently
/// accepting a dead player's skill. These checks hold the domain rules
/// against the state immediately before each accepted command.
test "domain validity: accepted skills had hp > 0 and mp >= cost immediately before; hp never negative" {
  for seed in 1..<=(property_seeds * 2) {
    let scenario = generate_scenario(seed)
    let mut world = scenario.world
    for batch in scenario.full.committed().batches() {
      assert_eq(
        batch.result.previous_state_hash,
        @prdt.hash_value(scenario.protocol.hasher(), world),
      )
      for resolved in batch.result.results {
        match resolved.verdict {
          @prdt.Accepted(event=@mmo.SkillActivated(actor~, mp_cost~, ..)) => {
            let player = world.player(actor).unwrap()
            assert_true(player.hp > 0)
            assert_true(player.mp >= mp_cost)
            assert_true(resolved.envelope.command is @mmo.UseSkill(..))
          }
          @prdt.Rejected(reason=@mmo.ActorDead) => {
            guard resolved.envelope.command is @mmo.UseSkill(actor~, ..) else {
              fail("ActorDead only rejects skills")
            }
            assert_eq(world.hp(actor), Some(0))
          }
          _ => ()
        }
        match resolved.verdict {
          @prdt.Accepted(event~) => world = @mmo.apply_game_event(world, event)
          @prdt.Rejected(..) => ()
        }
        for id in world.player_ids() {
          assert_true(world.hp(id).unwrap() >= 0)
        }
      }
      assert_eq(
        batch.result.resulting_state_hash,
        @prdt.hash_value(scenario.protocol.hasher(), world),
      )
    }
  }
}
