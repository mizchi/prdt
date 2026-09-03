///|
/// Executable statements of the properties this package claims. Tests drive
/// them with seeded generators; they are exported so downstream domains can
/// reuse them against their own replicated objects.
pub fn[E : Eq, R : Eq] command_decision_less_or_equal(
  before : CommandDecision[E, R],
  after : CommandDecision[E, R],
) -> Bool {
  @contracts.decision_kind_less_or_equal(before.kind(), after.kind()) &&
  (before is DecisionPending || before == after)
}

///|
/// `decision(state) <= decision(apply_delta(state, delta))`: no command ever
/// moves away from a final verdict, and the committed prefix only grows.
pub fn[E : Eq, R : Eq] decision_less_or_equal(
  before : Decision[E, R],
  after : Decision[E, R],
) -> Bool {
  for id, decision in before.commands {
    match after.commands.get(id) {
      Some(later) =>
        if !command_decision_less_or_equal(decision, later) {
          return false
        }
      None => return false
    }
  }
  if before.committed_ticks.length() > after.committed_ticks.length() {
    return false
  }
  for index in 0..<before.committed_ticks.length() {
    if before.committed_ticks[index] != after.committed_ticks[index] {
      return false
    }
  }
  true
}

///|
pub fn[R] logs_are_prefix_compatible(
  a : CommittedLog[R],
  b : CommittedLog[R],
) -> Bool {
  is_prefix_of(a, b) || is_prefix_of(b, a)
}

///|
/// Lattice laws for the whole replicated state under `Protocol::join`.
pub fn[S : ToJson, C : Eq, E : ToJson, R : ToJson] Protocol::lattice_law_violations(
  self : Protocol[S, C, E, R],
  a : State[S, C, E, R],
  b : State[S, C, E, R],
  c : State[S, C, E, R],
) -> Array[String] raise ProtocolError {
  let violations = []
  if !self.states_equal(self.join(a, a), a) {
    violations.push("idempotent")
  }
  if !self.states_equal(self.join(a, b), self.join(b, a)) {
    violations.push("commutative")
  }
  if !self.states_equal(
      self.join(self.join(a, b), c),
      self.join(a, self.join(b, c)),
    ) {
    violations.push("associative")
  }
  violations
}

///|
/// Abstract shape of a decision, for the proved order in `prdt/contracts`.
pub fn[E, R] CommandDecision::kind(
  self : CommandDecision[E, R],
) -> @contracts.DecisionKind {
  match self {
    DecisionPending => KindPending
    DecisionAccepted(_, _) => KindAccepted
    DecisionRejected(_, _) => KindRejected
    DecisionLate(_) => KindLate
  }
}
