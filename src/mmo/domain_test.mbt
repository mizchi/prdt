///|
fn alive_world() -> World {
  World::new([("a", { hp: 10, max_hp: 10, mp: 50 })])
}

///|
fn dead_world() -> World {
  World::new([("a", { hp: 0, max_hp: 10, mp: 50 })])
}

///|
test "skill from a living actor with enough MP is accepted" {
  assert_eq(
    validate_game_command(
      alive_world(),
      UseSkill(actor="a", skill="fireball", mp_cost=30),
    ),
    Accept(SkillActivated(actor="a", skill="fireball", mp_cost=30)),
  )
}

///|
test "skill from a dead actor is rejected" {
  assert_eq(
    validate_game_command(
      dead_world(),
      UseSkill(actor="a", skill="fireball", mp_cost=30),
    ),
    Reject(ActorDead),
  )
}

///|
test "insufficient MP, unknown actor, unknown target, invalid amounts" {
  assert_eq(
    validate_game_command(
      alive_world(),
      UseSkill(actor="a", skill="meteor", mp_cost=51),
    ),
    Reject(InsufficientMP),
  )
  assert_eq(
    validate_game_command(
      alive_world(),
      UseSkill(actor="zzz", skill="x", mp_cost=0),
    ),
    Reject(ActorNotFound),
  )
  assert_eq(
    validate_game_command(
      alive_world(),
      Damage(source="a", target="zzz", amount=1),
    ),
    Reject(TargetNotFound),
  )
  assert_eq(
    validate_game_command(
      alive_world(),
      Damage(source="a", target="a", amount=0),
    ),
    Reject(InvalidAmount),
  )
  assert_eq(
    validate_game_command(
      alive_world(),
      UseSkill(actor="a", skill="x", mp_cost=-1),
    ),
    Reject(InvalidAmount),
  )
}

///|
test "damage clamps HP at zero and does not mutate the input world" {
  let before = alive_world()
  let after = apply_game_event(
    before,
    DamageApplied(source="m", target="a", amount=25),
  )
  assert_eq(after.hp("a"), Some(0))
  assert_eq(before.hp("a"), Some(10))
  let used = apply_game_event(
    before,
    SkillActivated(actor="a", skill="fireball", mp_cost=30),
  )
  assert_eq(used.mp("a"), Some(20))
}

///|
test "world, command, event, and rejection json round-trip" {
  let world = World::new([
    ("b", { hp: 1, max_hp: 2, mp: 3 }),
    ("a", { hp: 4, max_hp: 5, mp: 6 }),
  ])
  let decoded : World = @json.from_json(world.to_json())
  assert_eq(decoded, world)
  assert_eq(
    world.to_json().stringify(),
    "{\"players\":[[\"a\",{\"hp\":4,\"max_hp\":5,\"mp\":6}],[\"b\",{\"hp\":1,\"max_hp\":2,\"mp\":3}]]}",
  )
  let command : GameCommand = @json.from_json(fireball().to_json())
  assert_eq(command, fireball())
  let expected_event = GameEvent::DamageApplied(
    source="m",
    target="a",
    amount=1,
  )
  let event : GameEvent = @json.from_json(expected_event.to_json())
  assert_eq(event, expected_event)
  let rejection : GameRejection = @json.from_json(
    GameRejection::ActorDead.to_json(),
  )
  assert_eq(rejection, GameRejection::ActorDead)
}
