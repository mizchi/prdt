///|
pub type GameProtocol = @prdt.Protocol[
  World,
  GameCommand,
  GameEvent,
  GameRejection,
]

///|
pub type GameState = @prdt.State[World, GameCommand, GameEvent, GameRejection]

///|
pub type GameObject = @prdt.ReplicatedDomain[
  World,
  GameCommand,
  GameEvent,
  GameRejection,
]

///|
pub let player_a : String = "player-a"

///|
/// Player A: HP=10, MP=100
pub fn lethal_race_world() -> World {
  World::new([(player_a, { hp: 10, max_hp: 10, mp: 100 })])
}

///|
pub fn fireball() -> GameCommand {
  UseSkill(actor=player_a, skill="fireball", mp_cost=30)
}

///|
pub fn lethal_hit() -> GameCommand {
  Damage(source="monster", target=player_a, amount=20)
}

///|
pub fn game_protocol(
  finalizer : &@prdt.Finalizer,
  hasher : &@prdt.Hasher,
  initial_world? : World,
  genesis_tick? : Int = 0,
) -> GameProtocol {
  let world = match initial_world {
    Some(world) => world
    None => lethal_race_world()
  }
  @prdt.Protocol::new(
    game_domain(world),
    game_order(),
    finalizer,
    hasher,
    genesis_tick~,
  )
}
