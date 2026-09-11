///|
/// A finalizer decides whether a closure certificate is authoritative. The
/// replicated domain never trusts a certificate it cannot verify. The
/// single-authority and quorum finalizers implement this trait so they can
/// be swapped without touching the domain or finalization layers.
pub(open) trait Finalizer {
  fn verify_closure(Self, ClosureCertificate) -> Bool
  /// Whether a compacted base may be adopted on the strength of this certificate.
  fn verify_base(Self, BaseCertificate) -> Bool
}

///|
/// The part of a certificate that a signer commits to.
pub(all) struct ClosurePayload {
  tick : Int
  parent_decision_hash : String
  ordered_commands_hash : String
} derive(Eq, Debug)

///|
pub let closure_message_domain : String = "prdt/closure/v1"

///|
pub fn ClosurePayload::of(certificate : ClosureCertificate) -> ClosurePayload {
  {
    tick: certificate.tick,
    parent_decision_hash: certificate.parent_decision_hash,
    ordered_commands_hash: certificate.ordered_commands_hash,
  }
}

///|
/// Domain-separated statement that closure signatures cover. The `domain`
/// field keeps a closure signature from being replayed as any other kind of
/// signature.
pub fn ClosurePayload::statement(self : ClosurePayload) -> Json {
  {
    "domain": closure_message_domain.to_json(),
    "tick": self.tick.to_json(),
    "parent_decision_hash": self.parent_decision_hash.to_json(),
    "ordered_commands_hash": self.ordered_commands_hash.to_json(),
  }
}

///|
pub fn ClosurePayload::digest(
  self : ClosurePayload,
  hashing : Hashing,
) -> Digest {
  hashing.hash_bytes(hashing.codec.encode(self.statement()))
}

///|
/// Every finalizer verifies the same structural facts before its own rule.
pub fn certificate_shape_ok(
  hashing : Hashing,
  certificate : ClosureCertificate,
) -> Bool {
  hash_command_ids(hashing, certificate.ordered_command_ids) ==
  certificate.ordered_commands_hash
}
