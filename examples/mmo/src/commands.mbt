///|
pub(all) enum GameCommand {
  Damage(source~ : String, target~ : String, amount~ : Int)
  UseSkill(actor~ : String, skill~ : String, mp_cost~ : Int)
} derive(Eq, Debug, ToJson(style="legacy"), FromJson(style="legacy"))

///|
/// Tick phase order. This is a game-semantic choice, not a physical order:
/// damage resolves before skills, so a lethal hit in the same tick makes a
/// concurrent skill `Rejected(ActorDead)`.
pub fn phase_of(command : GameCommand) -> Int {
  match command {
    Damage(..) => 0
    UseSkill(..) => 1
  }
}
