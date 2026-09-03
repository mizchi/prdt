///|
/// Protocol errors are raised when an input can never be joined with the
/// current state. A merge that raises leaves both inputs untouched.
pub(all) suberror ProtocolError {
  /// Two different payloads for one command id.
  ConflictingProposal(String)
  /// Two different closure certificates for one tick.
  ConflictingClosure(Int)
  /// Two committed logs that are not prefixes of each other; the index of divergence.
  PrefixConflict(Int)
  /// The finalizer refused a closure certificate for this tick.
  InvalidCertificate(Int)
  /// The certificate is structurally invalid (tick, duplicate ids, hash mismatch).
  MalformedCertificate(Int, String)
  /// The certificate chains from a parent hash that is not the local committed head.
  ChainMismatch(Int)
  /// The certificate's id order is not the canonical order.
  OrderMismatch(Int)
  /// An envelope carries an invalid tick.
  InvalidTick(String)
  /// A persisted snapshot cannot be decoded or does not match recomputation.
  SnapshotMismatch(String)
  /// A base certificate for this tick disagrees with the local committed history.
  ConflictingBase(Int)
  /// A catchup tried to install a base without a verifiable certificate.
  UnauthenticatedBase(Int)
} derive(Eq, Debug)

///|
pub fn ProtocolError::kind(self : ProtocolError) -> String {
  match self {
    ConflictingProposal(_) => "ConflictingProposal"
    ConflictingClosure(_) => "ConflictingClosure"
    PrefixConflict(_) => "PrefixConflict"
    InvalidCertificate(_) => "InvalidCertificate"
    MalformedCertificate(_, _) => "MalformedCertificate"
    ChainMismatch(_) => "ChainMismatch"
    OrderMismatch(_) => "OrderMismatch"
    InvalidTick(_) => "InvalidTick"
    SnapshotMismatch(_) => "SnapshotMismatch"
    ConflictingBase(_) => "ConflictingBase"
    UnauthenticatedBase(_) => "UnauthenticatedBase"
  }
}
