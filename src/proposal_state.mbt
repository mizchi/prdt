///|
/// Proposal knowledge: everything a replica has heard about submitted
/// commands, grouped by tick. A grow-only map of grow-only maps.
///
/// Join rules:
/// - outer map: joined per tick
/// - inner map: set union keyed by command id
/// - the same id with a different payload is a protocol error; neither
///   payload is adopted implicitly
/// - nothing is ever overwritten or removed
///
/// Instances are treated as immutable: every operation returns a fresh value.
pub struct ProposalState[C] {
  by_tick : Map[Int, Map[String, Envelope[C]]]
}

///|
pub fn[C] ProposalState::empty() -> ProposalState[C] {
  { by_tick: {} }
}

///|
pub fn[C] ProposalState::singleton(envelope : Envelope[C]) -> ProposalState[C] {
  let inner : Map[String, Envelope[C]] = Map([])
  inner[envelope.id] = envelope
  let by_tick : Map[Int, Map[String, Envelope[C]]] = Map([])
  by_tick[envelope.tick] = inner
  { by_tick, }
}

///|
fn[C] copy_tick(source : Map[String, Envelope[C]]) -> Map[String, Envelope[C]] {
  let out : Map[String, Envelope[C]] = Map([])
  for id, envelope in source {
    out[id] = envelope
  }
  out
}

///|
pub fn[C : Eq] ProposalState::merge(
  self : ProposalState[C],
  other : ProposalState[C],
) -> ProposalState[C] raise ProtocolError {
  let by_tick : Map[Int, Map[String, Envelope[C]]] = Map([])
  for tick, envelopes in self.by_tick {
    by_tick[tick] = copy_tick(envelopes)
  }
  for tick, envelopes in other.by_tick {
    let target = match by_tick.get(tick) {
      Some(existing) => existing
      None => {
        let fresh : Map[String, Envelope[C]] = Map([])
        by_tick[tick] = fresh
        fresh
      }
    }
    for id, envelope in envelopes {
      match target.get(id) {
        Some(existing) =>
          if existing != envelope {
            raise ConflictingProposal(id)
          }
        None => target[id] = envelope
      }
    }
  }
  { by_tick, }
}

///|
pub fn[C : Eq] ProposalState::add(
  self : ProposalState[C],
  envelope : Envelope[C],
) -> ProposalState[C] raise ProtocolError {
  self.merge(ProposalState::singleton(envelope))
}

///|
/// Envelopes known for one tick, keyed by id (a fresh map).
pub fn[C] ProposalState::for_tick(
  self : ProposalState[C],
  tick : Int,
) -> Map[String, Envelope[C]] {
  match self.by_tick.get(tick) {
    Some(envelopes) => copy_tick(envelopes)
    None => {}
  }
}

///|
pub fn[C] ProposalState::ticks(self : ProposalState[C]) -> Array[Int] {
  let ticks = self.by_tick.keys().to_array()
  ticks.sort()
  ticks
}

///|
/// Every known envelope in `(tick, id)` order, independent of insertion order.
pub fn[C] ProposalState::list(self : ProposalState[C]) -> Array[Envelope[C]] {
  let out : Array[Envelope[C]] = []
  for tick in self.ticks() {
    let envelopes = self.by_tick.get(tick).unwrap()
    let ids = envelopes.keys().to_array()
    ids.sort()
    for id in ids {
      out.push(envelopes.get(id).unwrap())
    }
  }
  out
}

///|
pub fn[C] ProposalState::count(self : ProposalState[C]) -> Int {
  let mut count = 0
  for _, envelopes in self.by_tick {
    count += envelopes.length()
  }
  count
}

///|
pub fn[C : Eq] ProposalState::equals(
  self : ProposalState[C],
  other : ProposalState[C],
) -> Bool {
  if self.count() != other.count() {
    return false
  }
  for tick, envelopes in self.by_tick {
    let theirs = match other.by_tick.get(tick) {
      Some(theirs) => theirs
      None => if envelopes.length() == 0 { continue } else { return false }
    }
    for id, envelope in envelopes {
      match theirs.get(id) {
        Some(other_envelope) => if other_envelope != envelope { return false }
        None => return false
      }
    }
  }
  true
}

///|
pub impl[C : Eq] JoinSemilattice for ProposalState[C] with fn join(a, b) {
  a.merge(b)
}

///|
pub impl[C : Eq] JoinSemilattice for ProposalState[C] with fn equivalent(a, b) {
  a.equals(b)
}

///|
/// Drop every tick below `tick` (compaction / GC of finalized history).
pub fn[C] ProposalState::prune_below(
  self : ProposalState[C],
  tick : Int,
) -> ProposalState[C] {
  let by_tick : Map[Int, Map[String, Envelope[C]]] = Map([])
  for known_tick, envelopes in self.by_tick {
    if known_tick >= tick {
      by_tick[known_tick] = copy_tick(envelopes)
    }
  }
  { by_tick, }
}

///|
/// Ids known for ticks at or above `tick`, sorted.
pub fn[C] ProposalState::ids_from(
  self : ProposalState[C],
  tick : Int,
) -> Array[String] {
  let ids = []
  for known_tick, envelopes in self.by_tick {
    if known_tick >= tick {
      for id, _ in envelopes {
        ids.push(id)
      }
    }
  }
  ids.sort()
  ids
}
