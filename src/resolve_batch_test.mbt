///|
/// A tiny counter domain: `Add(n)` is accepted while the total stays <= 10.
fn counter_domain() -> Domain[Int, Int, Int, String] {
  {
    initial_state: fn() { 0 },
    validate: fn(total, amount) {
      if total + amount > 10 {
        Reject("overflow")
      } else {
        Accept(amount)
      }
    },
    apply: fn(total, amount) { total + amount },
  }
}

///|
fn counter_env(replica : String, seq : Int, amount : Int) -> Envelope[Int] {
  {
    id: command_id(replica, seq),
    tick: 0,
    submitted_by: replica,
    local_sequence: seq,
    command: amount,
  }
}

///|
test "resolve_batch validates each command against the state before it" {
  let hasher = Sha256Hasher::new()
  let order = canonical_order(fn(_amount : Int) { 0 })
  let a = counter_env("a", 0, 6)
  let b = counter_env("b", 0, 6)
  let batch = resolve_batch(0, 0, [b, a], counter_domain(), order, hasher)
  assert_eq(batch.results.map(fn(r) { r.envelope.id }), ["a:0", "b:0"])
  assert_eq(batch.results[0].verdict, Accepted(event=6))
  assert_eq(batch.results[1].verdict, Rejected(reason="overflow"))
  assert_eq(batch.resulting_state, 6)
  let same = resolve_batch(0, 0, [a, b], counter_domain(), order, hasher)
  assert_eq(same, batch)
}

///|
test "resolve_batch rejects foreign ticks and duplicate ids" {
  let foreign : Envelope[Int] = { ..counter_env("a", 0, 1), tick: 1 }
  assert_eq(batch_error([foreign]), Some(BatchTickMismatch(0, 1, "a:0")))
  assert_eq(
    batch_error([counter_env("a", 0, 1), counter_env("a", 0, 1)]),
    Some(DuplicateCommandId("a:0")),
  )
}

///|
fn batch_error(commands : Array[Envelope[Int]]) -> BatchError? {
  let hasher = Sha256Hasher::new()
  let order = canonical_order(fn(_amount : Int) { 0 })
  try {
    let _ = resolve_batch(0, 0, commands, counter_domain(), order, hasher)
    None
  } catch {
    error => Some(error)
  }
}
