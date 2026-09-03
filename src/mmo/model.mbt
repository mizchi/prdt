///|
pub(all) struct Player {
  hp : Int
  max_hp : Int
  mp : Int
} derive(Eq, Debug)

///|
/// Game world. Treated as immutable: `apply` returns a fresh world.
pub struct World {
  players : Map[String, Player]
}

///|
pub fn World::new(players : Array[(String, Player)]) -> World {
  let map : Map[String, Player] = Map([])
  for entry in players {
    map[entry.0] = entry.1
  }
  { players: map }
}

///|
pub fn World::player(self : World, id : String) -> Player? {
  self.players.get(id)
}

///|
pub fn World::player_ids(self : World) -> Array[String] {
  let ids = self.players.keys().to_array()
  ids.sort()
  ids
}

///|
pub fn World::with_player(self : World, id : String, player : Player) -> World {
  let players : Map[String, Player] = Map([])
  for key, value in self.players {
    players[key] = value
  }
  players[id] = player
  { players, }
}

///|
pub fn World::is_alive(self : World, id : String) -> Bool {
  match self.players.get(id) {
    Some(player) => player.hp > 0
    None => false
  }
}

///|
pub fn World::hp(self : World, id : String) -> Int? {
  self.players.get(id).map(fn(p) { p.hp })
}

///|
pub fn World::mp(self : World, id : String) -> Int? {
  self.players.get(id).map(fn(p) { p.mp })
}

///|
pub impl Eq for World with fn equal(self, other) {
  if self.players.length() != other.players.length() {
    return false
  }
  for id, player in self.players {
    match other.players.get(id) {
      Some(theirs) => if theirs != player { return false }
      None => return false
    }
  }
  true
}

///|
pub impl Debug for World with fn to_repr(self) {
  Repr::string(self.to_json().stringify())
}

///|
pub impl ToJson for Player with fn to_json(self) {
  {
    "hp": self.hp.to_json(),
    "max_hp": self.max_hp.to_json(),
    "mp": self.mp.to_json(),
  }
}

///|
pub impl @json.FromJson for Player with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "Player: expected object"))
  }
  {
    hp: @json.from_json(
      @prdt.json_field(fields, "hp", path),
      path=path.add_key("hp"),
    ),
    max_hp: @json.from_json(
      @prdt.json_field(fields, "max_hp", path),
      path=path.add_key("max_hp"),
    ),
    mp: @json.from_json(
      @prdt.json_field(fields, "mp", path),
      path=path.add_key("mp"),
    ),
  }
}

///|
/// Players are encoded as an id-sorted entry list so the encoding is
/// canonical regardless of insertion order.
pub impl ToJson for World with fn to_json(self) {
  let entries = self
    .player_ids()
    .map(fn(id) {
      Json::array([id.to_json(), self.players.get(id).unwrap().to_json()])
    })
  { "players": Json::array(entries) }
}

///|
pub impl @json.FromJson for World with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "World: expected object"))
  }
  guard @prdt.json_field(fields, "players", path) is Array(entries) else {
    raise @json.JsonDecodeError((path, "World.players: expected array"))
  }
  let players : Map[String, Player] = Map([])
  for entry in entries {
    guard entry is Array([String(id), player_json]) else {
      raise @json.JsonDecodeError((path, "World.players: bad entry"))
    }
    players[id] = @json.from_json(player_json, path=path.add_key(id))
  }
  { players, }
}
