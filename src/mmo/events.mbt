///|
pub(all) enum GameEvent {
  DamageApplied(source~ : String, target~ : String, amount~ : Int)
  SkillActivated(actor~ : String, skill~ : String, mp_cost~ : Int)
} derive(Eq, Debug)

///|
pub(all) enum GameRejection {
  ActorNotFound
  ActorDead
  InsufficientMP
  TargetNotFound
  InvalidAmount
} derive(Eq, Debug)

///|
pub impl ToJson for GameEvent with fn to_json(self) {
  match self {
    DamageApplied(source~, target~, amount~) =>
      {
        "type": "DamageApplied",
        "source": source.to_json(),
        "target": target.to_json(),
        "amount": amount.to_json(),
      }
    SkillActivated(actor~, skill~, mp_cost~) =>
      {
        "type": "SkillActivated",
        "actor": actor.to_json(),
        "skill": skill.to_json(),
        "mp_cost": mp_cost.to_json(),
      }
  }
}

///|
pub impl @json.FromJson for GameEvent with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "GameEvent: expected object"))
  }
  let kind : String = @json.from_json(
    @prdt.json_field(fields, "type", path),
    path=path.add_key("type"),
  )
  match kind {
    "DamageApplied" =>
      DamageApplied(
        source=@json.from_json(
          @prdt.json_field(fields, "source", path),
          path=path.add_key("source"),
        ),
        target=@json.from_json(
          @prdt.json_field(fields, "target", path),
          path=path.add_key("target"),
        ),
        amount=@json.from_json(
          @prdt.json_field(fields, "amount", path),
          path=path.add_key("amount"),
        ),
      )
    "SkillActivated" =>
      SkillActivated(
        actor=@json.from_json(
          @prdt.json_field(fields, "actor", path),
          path=path.add_key("actor"),
        ),
        skill=@json.from_json(
          @prdt.json_field(fields, "skill", path),
          path=path.add_key("skill"),
        ),
        mp_cost=@json.from_json(
          @prdt.json_field(fields, "mp_cost", path),
          path=path.add_key("mp_cost"),
        ),
      )
    other =>
      raise @json.JsonDecodeError((path, "GameEvent: unknown type " + other))
  }
}

///|
pub fn GameRejection::name(self : GameRejection) -> String {
  match self {
    ActorNotFound => "ActorNotFound"
    ActorDead => "ActorDead"
    InsufficientMP => "InsufficientMP"
    TargetNotFound => "TargetNotFound"
    InvalidAmount => "InvalidAmount"
  }
}

///|
pub impl ToJson for GameRejection with fn to_json(self) {
  { "type": self.name().to_json() }
}

///|
pub impl @json.FromJson for GameRejection with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "GameRejection: expected object"))
  }
  let kind : String = @json.from_json(
    @prdt.json_field(fields, "type", path),
    path=path.add_key("type"),
  )
  match kind {
    "ActorNotFound" => ActorNotFound
    "ActorDead" => ActorDead
    "InsufficientMP" => InsufficientMP
    "TargetNotFound" => TargetNotFound
    "InvalidAmount" => InvalidAmount
    other =>
      raise @json.JsonDecodeError(
        (path, "GameRejection: unknown type " + other),
      )
  }
}
