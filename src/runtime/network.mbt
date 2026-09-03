///|
/// Adversarial in-memory network: delay, reorder, duplicate, partition, heal.
/// It never corrupts a payload; authenticity is the finalizer's job and
/// payload conflicts are the proposal lattice's job.
pub(all) struct Message[M] {
  sequence : Int
  sender : String
  receiver : String
  payload : M
}

///|
pub struct InMemoryNetwork[M] {
  queue : Array[Message[M]]
  mut sequence : Int
  mut groups : Map[String, Int]?
}

///|
pub fn[M] InMemoryNetwork::new() -> InMemoryNetwork[M] {
  { queue: [], sequence: 0, groups: None }
}

///|
pub fn[M] InMemoryNetwork::send(
  self : InMemoryNetwork[M],
  sender : String,
  receiver : String,
  payload : M,
) -> Unit {
  self.queue.push({ sequence: self.sequence, sender, receiver, payload })
  self.sequence += 1
}

///|
pub fn[M] InMemoryNetwork::pending(self : InMemoryNetwork[M]) -> Int {
  self.queue.length()
}

///|
fn[M] InMemoryNetwork::deliverable_indices(
  self : InMemoryNetwork[M],
) -> Array[Int] {
  let out = []
  for index in 0..<self.queue.length() {
    let message = self.queue[index]
    let crossable = match self.groups {
      None => true
      Some(groups) => groups.get(message.sender) == groups.get(message.receiver)
    }
    if crossable {
      out.push(index)
    }
  }
  out
}

///|
/// Remove and return one deliverable message: FIFO, or a random one when `rng` is given.
pub fn[M] InMemoryNetwork::deliver_one(
  self : InMemoryNetwork[M],
  rng? : Rng,
) -> Message[M]? {
  let candidates = self.deliverable_indices()
  if candidates.length() == 0 {
    return None
  }
  let index = match rng {
    Some(rng) => rng.pick(candidates)
    None => candidates[0]
  }
  Some(self.queue.remove(index))
}

///|
/// Re-enqueue a copy of a random queued message (duplicate delivery).
pub fn[M] InMemoryNetwork::duplicate_one(
  self : InMemoryNetwork[M],
  rng : Rng,
) -> Bool {
  if self.queue.length() == 0 {
    return false
  }
  let original = rng.pick(self.queue)
  self.queue.push({ ..original, sequence: self.sequence })
  self.sequence += 1
  true
}

///|
pub fn[M] InMemoryNetwork::partition(
  self : InMemoryNetwork[M],
  groups : Array[Array[String]],
) -> Unit {
  let map : Map[String, Int] = Map([])
  for index, group in groups {
    for id in group {
      map[id] = index
    }
  }
  self.groups = Some(map)
}

///|
pub fn[M] InMemoryNetwork::heal(self : InMemoryNetwork[M]) -> Unit {
  self.groups = None
}

///|
pub fn[M] InMemoryNetwork::partitioned(self : InMemoryNetwork[M]) -> Bool {
  self.groups is Some(_)
}
