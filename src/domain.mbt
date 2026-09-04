///|
/// Domain layer.
///
/// A `Domain` is a pure, deterministic state machine. `validate` and `apply`
/// must not read the wall clock, randomness, the network, or global mutable
/// state, and `apply` must not mutate its input. Randomness a rule needs must
/// arrive inside the command.
///
/// The domain never sees replication. Validation runs against the state
/// immediately before the command in the finalized order, which is why
/// non-monotonic predicates such as `hp > 0` are safe here and unsafe as
/// proposal-time PRDT preconditions.
pub(all) enum Validation[E, R] {
  Accept(E)
  Reject(R)
} derive(Eq, Debug)

///|
pub(all) struct Domain[S, C, E, R] {
  initial_state : () -> S
  validate : (S, C) -> Validation[E, R]
  apply : (S, E) -> S
}

///|
/// Immutable once produced by batch resolution.
pub(all) enum Verdict[E, R] {
  Accepted(event~ : E)
  Rejected(reason~ : R)
} derive(Eq, Debug, ToJson(style="legacy"), FromJson(style="legacy"))

///|
pub(all) struct ResolvedCommand[C, E, R] {
  envelope : Envelope[C]
  verdict : Verdict[E, R]
} derive(Eq, Debug, ToJson, FromJson)
