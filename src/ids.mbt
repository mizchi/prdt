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
} derive(Eq, Debug, ToJson, FromJson)

///|
pub fn command_id(replica_id : String, local_sequence : Int) -> String {
  replica_id + ":" + local_sequence.to_string()
}

///|
pub fn is_valid_tick(tick : Int) -> Bool {
  tick >= 0
}
