///|
/// A command as submitted by one replica.
///
/// `id` must be globally unique. The MVP identifier is
/// `"<replica_id>:<local_sequence>"`, which is unique as long as replica ids
/// are unique and each replica increments `local_sequence` monotonically and
/// durably.
pub(all) struct Envelope[C] {
  id : String
  tick : Int
  submitted_by : String
  local_sequence : Int
  command : C
} derive(Eq, Debug)

///|
pub fn command_id(replica_id : String, local_sequence : Int) -> String {
  replica_id + ":" + local_sequence.to_string()
}

///|
pub fn is_valid_tick(tick : Int) -> Bool {
  tick >= 0
}

///|
pub impl[C : ToJson] ToJson for Envelope[C] with fn to_json(self) {
  {
    "id": self.id.to_json(),
    "tick": self.tick.to_json(),
    "submitted_by": self.submitted_by.to_json(),
    "local_sequence": self.local_sequence.to_json(),
    "command": self.command.to_json(),
  }
}

///|
pub impl[C : @json.FromJson] @json.FromJson for Envelope[C] with fn from_json(
  json,
  path,
) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "Envelope: expected object"))
  }
  let id : String = @json.from_json(
    json_field(fields, "id", path),
    path=path.add_key("id"),
  )
  let tick : Int = @json.from_json(
    json_field(fields, "tick", path),
    path=path.add_key("tick"),
  )
  let submitted_by : String = @json.from_json(
    json_field(fields, "submitted_by", path),
    path=path.add_key("submitted_by"),
  )
  let local_sequence : Int = @json.from_json(
    json_field(fields, "local_sequence", path),
    path=path.add_key("local_sequence"),
  )
  let command : C = @json.from_json(
    json_field(fields, "command", path),
    path=path.add_key("command"),
  )
  { id, tick, submitted_by, local_sequence, command }
}

///|
/// Look up a required field of a JSON object.
pub fn json_field(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> Json raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(value) => value
    None => raise @json.JsonDecodeError((path, "missing field " + key))
  }
}
