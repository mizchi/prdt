///|
/// Committed prefix log.
///
/// Decision order is prefix order: `[] <= [t0] <= [t0, t1]`. Two logs that
/// agree on a shared prefix but differ afterwards are not comparable and can
/// never be joined.
pub(all) struct CommittedBatch[R] {
  tick : Int
  parent_decision_hash : String
  ordered_commands_hash : String
  result_hash : String
  result : R
} derive(Eq, Debug, ToJson, FromJson)

///|
pub struct CommittedLog[R] {
  batches : Array[CommittedBatch[R]]
}

///|
pub fn[R] CommittedLog::empty() -> CommittedLog[R] {
  { batches: [] }
}

///|
pub fn[R] CommittedLog::length(self : CommittedLog[R]) -> Int {
  self.batches.length()
}

///|
pub fn[R] CommittedLog::batches(
  self : CommittedLog[R],
) -> Array[CommittedBatch[R]] {
  self.batches.copy()
}

///|
pub fn[R] CommittedLog::last(self : CommittedLog[R]) -> CommittedBatch[R]? {
  self.batches.last()
}

///|
pub fn[R] CommittedLog::append(
  self : CommittedLog[R],
  batch : CommittedBatch[R],
) -> CommittedLog[R] {
  let batches = self.batches.copy()
  batches.push(batch)
  { batches, }
}

///|
pub fn[R] CommittedLog::result_hashes(self : CommittedLog[R]) -> Array[String] {
  self.batches.map(fn(b) { b.result_hash })
}

///|
pub fn[R] is_prefix_of(prefix : CommittedLog[R], log : CommittedLog[R]) -> Bool {
  if prefix.batches.length() > log.batches.length() {
    return false
  }
  for index in 0..<prefix.batches.length() {
    let a = prefix.batches[index]
    let b = log.batches[index]
    if a.tick != b.tick || a.result_hash != b.result_hash {
      return false
    }
  }
  true
}

///|
pub fn[R] CommittedLog::merge(
  self : CommittedLog[R],
  other : CommittedLog[R],
) -> CommittedLog[R] raise ProtocolError {
  let (shorter, longer) = if self.batches.length() <= other.batches.length() {
    (self, other)
  } else {
    (other, self)
  }
  if !is_prefix_of(shorter, longer) {
    let mut index = 0
    while index < shorter.batches.length() &&
          shorter.batches[index].result_hash ==
          longer.batches[index].result_hash &&
          shorter.batches[index].tick == longer.batches[index].tick {
      index += 1
    }
    raise PrefixConflict(index)
  }
  longer
}

///|
pub fn[R] CommittedLog::equals(
  self : CommittedLog[R],
  other : CommittedLog[R],
) -> Bool {
  self.batches.length() == other.batches.length() && is_prefix_of(self, other)
}

///|
pub fn[R] CommittedLog::head_decision_hash(
  self : CommittedLog[R],
  genesis_hash : String,
) -> String {
  match self.batches.last() {
    Some(batch) => batch.result_hash
    None => genesis_hash
  }
}

///|
pub impl[R] JoinSemilattice for CommittedLog[R] with fn join(a, b) {
  a.merge(b)
}

///|
pub impl[R] JoinSemilattice for CommittedLog[R] with fn equivalent(a, b) {
  a.equals(b)
}
