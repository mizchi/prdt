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
  Accepted(E)
  Rejected(R)
} derive(Eq, Debug)

///|
pub(all) struct ResolvedCommand[C, E, R] {
  envelope : Envelope[C]
  verdict : Verdict[E, R]
} derive(Eq, Debug)

///|
pub impl[E : ToJson, R : ToJson] ToJson for Verdict[E, R] with fn to_json(self) {
  match self {
    Accepted(event) => { "status": "Accepted", "event": event.to_json() }
    Rejected(reason) => { "status": "Rejected", "reason": reason.to_json() }
  }
}

///|
pub impl[E : @json.FromJson, R : @json.FromJson] @json.FromJson for Verdict[
  E,
  R,
] with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "Verdict: expected object"))
  }
  let status : String = @json.from_json(
    json_field(fields, "status", path),
    path=path.add_key("status"),
  )
  match status {
    "Accepted" =>
      Accepted(
        @json.from_json(
          json_field(fields, "event", path),
          path=path.add_key("event"),
        ),
      )
    "Rejected" =>
      Rejected(
        @json.from_json(
          json_field(fields, "reason", path),
          path=path.add_key("reason"),
        ),
      )
    other =>
      raise @json.JsonDecodeError((path, "Verdict: unknown status " + other))
  }
}

///|
pub impl[C : ToJson, E : ToJson, R : ToJson] ToJson for ResolvedCommand[C, E, R] with fn to_json(
  self,
) {
  { "envelope": self.envelope.to_json(), "verdict": self.verdict.to_json() }
}

///|
pub impl[C : @json.FromJson, E : @json.FromJson, R : @json.FromJson] @json.FromJson for ResolvedCommand[
  C,
  E,
  R,
] with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "ResolvedCommand: expected object"))
  }
  {
    envelope: @json.from_json(
      json_field(fields, "envelope", path),
      path=path.add_key("envelope"),
    ),
    verdict: @json.from_json(
      json_field(fields, "verdict", path),
      path=path.add_key("verdict"),
    ),
  }
}
