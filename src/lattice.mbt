///|
/// Join-semilattice.
///
/// Every replicated state in this package satisfies: `join` is idempotent,
/// commutative, and associative. Some joins reject inputs that can never be
/// joined (two payloads for one command id, two certificates for one tick);
/// those raise `ProtocolError` and leave both inputs untouched.
pub(open) trait JoinSemilattice {
  fn join(Self, Self) -> Self raise ProtocolError
  fn equivalent(Self, Self) -> Bool
}

///|
/// `a <= b` in the lattice order iff `join(a, b) == b`.
pub fn[L : JoinSemilattice] less_or_equal(
  a : L,
  b : L,
) -> Bool raise ProtocolError {
  L::equivalent(L::join(a, b), b)
}

///|
/// Names of the lattice laws violated by three samples; empty when all hold.
pub fn[L : JoinSemilattice] lattice_law_violations(
  a : L,
  b : L,
  c : L,
) -> Array[String] raise ProtocolError {
  let violations = []
  if !L::equivalent(L::join(a, a), a) {
    violations.push("idempotent")
  }
  if !L::equivalent(L::join(a, b), L::join(b, a)) {
    violations.push("commutative")
  }
  if !L::equivalent(L::join(L::join(a, b), c), L::join(a, L::join(b, c))) {
    violations.push("associative")
  }
  violations
}
