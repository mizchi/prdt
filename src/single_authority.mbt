///|
/// Single-authority finalization.
///
/// One designated key closes ticks by signing the closure payload; every
/// replica verifies that signature before admitting the closure. Liveness
/// depends on the authority. Safety (closure uniqueness) depends on the
/// authority never signing two certificates for one tick, which the local
/// `ConflictingClosure` check surfaces but cannot prevent.
pub struct SingleAuthorityFinalizer {
  hasher : &Hasher
  verifier : &Verifier
  authority : PublicKey
}

///|
pub fn SingleAuthorityFinalizer::new(
  hasher : &Hasher,
  verifier : &Verifier,
  authority : PublicKey,
) -> SingleAuthorityFinalizer {
  { hasher, verifier, authority }
}

///|
pub impl Finalizer for SingleAuthorityFinalizer with fn verify_closure(
  self,
  certificate,
) {
  if !certificate_shape_ok(self.hasher, certificate) {
    return false
  }
  let digest = ClosurePayload::of(certificate).digest(self.hasher)
  for attestation in certificate.attestations {
    if attestation.signer == self.authority &&
      self.verifier.verify(attestation.signer, digest, attestation.signature) {
      return true
    }
  }
  false
}

///|
pub impl Finalizer for SingleAuthorityFinalizer with fn verify_base(
  self,
  certificate,
) {
  let digest = BasePayload::of(certificate).digest(self.hasher)
  for attestation in certificate.attestations {
    if attestation.signer == self.authority &&
      self.verifier.verify(attestation.signer, digest, attestation.signature) {
      return true
    }
  }
  false
}

///|
/// Produces certificates. Held by the authority replica only.
pub struct ClosureAuthority[C] {
  hasher : &Hasher
  signer : &Signer
  order : CommandOrder[C]
}

///|
pub fn[C] ClosureAuthority::new(
  hasher : &Hasher,
  signer : &Signer,
  order : CommandOrder[C],
) -> ClosureAuthority[C] {
  { hasher, signer, order }
}

///|
/// Certificate fixing `commands` as the complete, canonically ordered set for `tick`.
pub fn[C] ClosureAuthority::close(
  self : ClosureAuthority[C],
  tick : Int,
  parent_decision_hash : String,
  commands : Array[Envelope[C]],
) -> ClosureCertificate raise BatchError {
  for envelope in commands {
    if envelope.tick != tick {
      raise BatchTickMismatch(tick, envelope.tick, envelope.id)
    }
  }
  let ordered_command_ids = sort_commands(commands, self.order).map(fn(e) {
    e.id
  })
  let ordered_commands_hash = hash_command_ids(self.hasher, ordered_command_ids)
  let payload : ClosurePayload = {
    tick,
    parent_decision_hash,
    ordered_commands_hash,
  }
  {
    tick,
    parent_decision_hash,
    ordered_command_ids,
    ordered_commands_hash,
    attestations: [
      {
        signer: self.signer.public_key(),
        signature: self.signer.sign(payload.digest(self.hasher)),
      },
    ],
  }
}

///|
/// Certify the head at `next_tick - 1` so replicas may compact to it and
/// hand it to peers as a base.
pub fn[C] ClosureAuthority::certify_base(
  self : ClosureAuthority[C],
  next_tick : Int,
  decision_hash : String,
  state_hash : String,
) -> BaseCertificate {
  let payload : BasePayload = { next_tick, decision_hash, state_hash }
  {
    next_tick,
    decision_hash,
    state_hash,
    attestations: [
      {
        signer: self.signer.public_key(),
        signature: self.signer.sign(payload.digest(self.hasher)),
      },
    ],
  }
}
