///|
pub(all) enum GameCommand {
  Damage(source~ : String, target~ : String, amount~ : Int)
  UseSkill(actor~ : String, skill~ : String, mp_cost~ : Int)
} derive(Eq, Debug)

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

///|
pub impl ToJson for GameCommand with fn to_json(self) {
  match self {
    Damage(source~, target~, amount~) =>
      {
        "type": "Damage",
        "source": source.to_json(),
        "target": target.to_json(),
        "amount": amount.to_json(),
      }
    UseSkill(actor~, skill~, mp_cost~) =>
      {
        "type": "UseSkill",
        "actor": actor.to_json(),
        "skill": skill.to_json(),
        "mp_cost": mp_cost.to_json(),
      }
  }
}

///|
pub impl @json.FromJson for GameCommand with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "GameCommand: expected object"))
  }
  let kind : String = @json.from_json(
    @prdt.json_field(fields, "type", path),
    path=path.add_key("type"),
  )
  match kind {
    "Damage" =>
      Damage(
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
    "UseSkill" =>
      UseSkill(
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
      raise @json.JsonDecodeError((path, "GameCommand: unknown type " + other))
  }
}
