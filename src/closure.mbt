///|
/// Tick closure.
///
/// A PRDT cannot infer "no more commands will arrive for this tick" from the
/// event set alone; that negative information must be certified explicitly.
/// A `ClosureCertificate` fixes the exact ordered command set of one tick and
/// chains it to the decision hash of the previous tick.
///
/// Decision order:
///   ClosurePending <= Closed(c)
///   Closed(a) <= Closed(b)  iff  a == b
/// Two different certificates for the same tick can never be joined.
pub(all) struct Attestation {
  signer : PublicKey
  signature : Signature
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct ClosureCertificate {
  tick : Int
  parent_decision_hash : String
  ordered_command_ids : Array[String]
  ordered_commands_hash : String
  /// Finalizer-specific proof: one attestation for a single authority, a
  /// quorum of attestations for the quorum finalizer.
  attestations : Array[Attestation]
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) enum ClosureDecision {
  ClosurePending
  Closed(ClosureCertificate)
} derive(Eq, Debug)

///|
/// Certificate identity is its payload: tick, parent hash, and the ordered
/// command ids. Attestations are proof, not state; two verified certificates
/// for the same payload are the same decision even if different quorum
/// members signed them.
pub fn ClosureCertificate::same_decision(
  self : ClosureCertificate,
  other : ClosureCertificate,
) -> Bool {
  self.tick == other.tick &&
  self.parent_decision_hash == other.parent_decision_hash &&
  self.ordered_commands_hash == other.ordered_commands_hash &&
  self.ordered_command_ids == other.ordered_command_ids
}

///|
pub fn ClosureCertificate::payload_json(self : ClosureCertificate) -> Json {
  {
    "tick": self.tick.to_json(),
    "parent_decision_hash": self.parent_decision_hash.to_json(),
    "ordered_command_ids": self.ordered_command_ids.to_json(),
    "ordered_commands_hash": self.ordered_commands_hash.to_json(),
  }
}

///|
pub fn merge_closure_decisions(
  left : ClosureDecision,
  right : ClosureDecision,
) -> ClosureDecision raise ProtocolError {
  match (left, right) {
    (ClosurePending, other) | (other, ClosurePending) => other
    (Closed(a), Closed(b)) =>
      if a.same_decision(b) {
        left
      } else {
        raise ConflictingClosure(a.tick)
      }
  }
}

///|
pub fn closure_decisions_equivalent(
  left : ClosureDecision,
  right : ClosureDecision,
) -> Bool {
  match (left, right) {
    (ClosurePending, ClosurePending) => true
    (Closed(a), Closed(b)) => a.same_decision(b)
    _ => false
  }
}

///|
pub impl JoinSemilattice for ClosureDecision with fn join(a, b) {
  merge_closure_decisions(a, b)
}

///|
pub impl JoinSemilattice for ClosureDecision with fn equivalent(a, b) {
  closure_decisions_equivalent(a, b)
}

///|
/// Closure knowledge per tick. Immutable by convention; every operation
/// returns a fresh value.
pub struct ClosureMap {
  by_tick : Map[Int, ClosureDecision]
}

///|
pub fn ClosureMap::empty() -> ClosureMap {
  { by_tick: {} }
}

///|
pub fn ClosureMap::from_certificates(
  certificates : Array[ClosureCertificate],
) -> ClosureMap raise ProtocolError {
  let mut out = ClosureMap::empty()
  for certificate in certificates {
    let single : Map[Int, ClosureDecision] = Map([])
    single[certificate.tick] = Closed(certificate)
    out = out.merge({ by_tick: single })
  }
  out
}

///|
pub fn ClosureMap::merge(
  self : ClosureMap,
  other : ClosureMap,
) -> ClosureMap raise ProtocolError {
  let by_tick : Map[Int, ClosureDecision] = Map([])
  for tick, decision in self.by_tick {
    by_tick[tick] = decision
  }
  for tick, decision in other.by_tick {
    by_tick[tick] = match by_tick.get(tick) {
      Some(existing) => merge_closure_decisions(existing, decision)
      None => decision
    }
  }
  { by_tick, }
}

///|
pub fn ClosureMap::for_tick(self : ClosureMap, tick : Int) -> ClosureDecision {
  match self.by_tick.get(tick) {
    Some(decision) => decision
    None => ClosurePending
  }
}

///|
/// Certificates in tick order.
pub fn ClosureMap::list(self : ClosureMap) -> Array[ClosureCertificate] {
  let ticks = self.by_tick.keys().to_array()
  ticks.sort()
  let out = []
  for tick in ticks {
    match self.by_tick.get(tick).unwrap() {
      Closed(certificate) => out.push(certificate)
      ClosurePending => ()
    }
  }
  out
}

///|
pub fn ClosureMap::equals(self : ClosureMap, other : ClosureMap) -> Bool {
  let mine = self.list()
  let theirs = other.list()
  if mine.length() != theirs.length() {
    return false
  }
  for index in 0..<mine.length() {
    if !mine[index].same_decision(theirs[index]) {
      return false
    }
  }
  true
}

///|
pub impl JoinSemilattice for ClosureMap with fn join(a, b) {
  a.merge(b)
}

///|
pub impl JoinSemilattice for ClosureMap with fn equivalent(a, b) {
  a.equals(b)
}

///|
/// Drop every tick below `tick` (compaction / GC of finalized history).
pub fn ClosureMap::prune_below(self : ClosureMap, tick : Int) -> ClosureMap {
  let by_tick : Map[Int, ClosureDecision] = Map([])
  for known_tick, decision in self.by_tick {
    if known_tick >= tick {
      by_tick[known_tick] = decision
    }
  }
  { by_tick, }
}

///|
/// Closed ticks at or above `tick`, sorted.
pub fn ClosureMap::closed_ticks_from(
  self : ClosureMap,
  tick : Int,
) -> Array[Int] {
  self.list().filter(fn(c) { c.tick >= tick }).map(fn(c) { c.tick })
}
