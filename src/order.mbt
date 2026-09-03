///|
/// Canonical command ordering inside a tick.
///
/// The order is a domain design decision, not a physical truth. It must be
/// total; `command_id` is always the final tie breaker so that two distinct
/// envelopes never compare equal.
pub struct CommandOrder[C] {
  compare : (Envelope[C], Envelope[C]) -> Int
}

///|
pub fn[C] CommandOrder::new(
  compare : (Envelope[C], Envelope[C]) -> Int,
) -> CommandOrder[C] {
  { compare, }
}

///|
/// `(tick, phase, submitted_by, local_sequence, command_id)`
pub fn[C] canonical_order(phase : (C) -> Int) -> CommandOrder[C] {
  CommandOrder::new(fn(a, b) {
    let by_tick = a.tick.compare(b.tick)
    if by_tick != 0 {
      return by_tick
    }
    let by_phase = phase(a.command).compare(phase(b.command))
    if by_phase != 0 {
      return by_phase
    }
    let by_submitter = a.submitted_by.compare(b.submitted_by)
    if by_submitter != 0 {
      return by_submitter
    }
    let by_sequence = a.local_sequence.compare(b.local_sequence)
    if by_sequence != 0 {
      return by_sequence
    }
    a.id.compare(b.id)
  })
}

///|
/// Returns a sorted copy; the input array is never mutated.
pub fn[C] sort_commands(
  commands : Array[Envelope[C]],
  order : CommandOrder[C],
) -> Array[Envelope[C]] {
  let copy = commands.copy()
  copy.sort_by(order.compare)
  copy
}
