///|
pub(all) enum GameEvent {
  DamageApplied(source~ : String, target~ : String, amount~ : Int)
  SkillActivated(actor~ : String, skill~ : String, mp_cost~ : Int)
} derive(Eq, Debug, ToJson(style="legacy"), FromJson(style="legacy"))

///|
pub(all) enum GameRejection {
  ActorNotFound
  ActorDead
  InsufficientMP
  TargetNotFound
  InvalidAmount
} derive(Eq, Debug, ToJson(style="legacy"), FromJson(style="legacy"))
