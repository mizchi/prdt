///|
/// Durable snapshot storage. A replica must persist its own proposals and (for
/// an authority) its own certificates before disseminating them; otherwise a
/// restart could reuse a command id for a different payload or close a tick
/// twice, which the protocol correctly refuses as a conflict.
pub(open) trait CheckpointStore {
  fn load(Self) -> Json?
  fn save(Self, Json) -> Unit
}

///|
/// Stores the snapshot as text so restore exercises real (de)serialization.
pub struct InMemoryCheckpointStore {
  mut snapshot : String?
}

///|
pub fn InMemoryCheckpointStore::new() -> InMemoryCheckpointStore {
  { snapshot: None }
}

///|
pub impl CheckpointStore for InMemoryCheckpointStore with fn load(self) {
  match self.snapshot {
    Some(text) => Some(@json.parse(text)) catch { _ => None }
    None => None
  }
}

///|
pub impl CheckpointStore for InMemoryCheckpointStore with fn save(
  self,
  snapshot,
) {
  self.snapshot = Some(snapshot.stringify())
}
