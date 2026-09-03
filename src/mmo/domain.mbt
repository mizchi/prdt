///|
/// MMO sample domain: a pure reducer. `alive` is evaluated here, against the
/// state immediately before the command in the finalized order, and never as
/// a proposal-time precondition.
pub fn validate_game_command(
  world : World,
  command : GameCommand,
) -> @prdt.Validation[GameEvent, GameRejection] {
  match command {
    Damage(source~, target~, amount~) => {
      if amount <= 0 {
        return Reject(InvalidAmount)
      }
      if !world.players.contains(target) {
        return Reject(TargetNotFound)
      }
      Accept(DamageApplied(source~, target~, amount~))
    }
    UseSkill(actor~, skill~, mp_cost~) => {
      if mp_cost < 0 {
        return Reject(InvalidAmount)
      }
      let player = match world.players.get(actor) {
        Some(player) => player
        None => return Reject(ActorNotFound)
      }
      if player.hp <= 0 {
        return Reject(ActorDead)
      }
      if player.mp < mp_cost {
        return Reject(InsufficientMP)
      }
      Accept(SkillActivated(actor~, skill~, mp_cost~))
    }
  }
}

///|
pub fn apply_game_event(world : World, event : GameEvent) -> World {
  match event {
    DamageApplied(target~, amount~, ..) =>
      match world.players.get(target) {
        Some(player) => {
          let hp = if player.hp - amount < 0 { 0 } else { player.hp - amount }
          world.with_player(target, { ..player, hp, })
        }
        None => world
      }
    SkillActivated(actor~, mp_cost~, ..) =>
      match world.players.get(actor) {
        Some(player) =>
          world.with_player(actor, { ..player, mp: player.mp - mp_cost })
        None => world
      }
  }
}

///|
pub fn game_domain(
  initial_world : World,
) -> @prdt.Domain[World, GameCommand, GameEvent, GameRejection] {
  {
    initial_state: fn() { initial_world },
    validate: validate_game_command,
    apply: apply_game_event,
  }
}

///|
/// `(tick, phase, submitted_by, local_sequence, command_id)` with
/// `Damage = 0 < UseSkill = 1`.
pub fn game_order() -> @prdt.CommandOrder[GameCommand] {
  @prdt.canonical_order(phase_of)
}
