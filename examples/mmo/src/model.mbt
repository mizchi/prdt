///|
pub(all) struct Player {
  hp : Int
  max_hp : Int
  mp : Int
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Game world. Treated as immutable: `apply` returns a fresh world.
///
/// Encoded as `{"players": {<id>: Player}}`; hashing goes through canonical
/// JSON, so insertion order never matters.
pub struct World {
  players : Map[String, Player]
} derive(ToJson, FromJson)

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
