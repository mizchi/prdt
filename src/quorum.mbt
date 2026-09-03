///|
/// Quorum finalization (safety half of Phase 5).
///
/// A tick is closed when at least `threshold` distinct roster members sign
/// the same closure payload. Uniqueness follows from
/// `2 * threshold > roster.length()`: any two quorums intersect in at least
/// one voter, and a non-equivocating voter signs at most one payload per
/// tick. An equivocating voter is excluded from every tally.
///
/// Leader election, retry, and view change (liveness) are out of scope.
pub struct QuorumRoster {
  members : Array[PublicKey]
  threshold : Int
}

///|
pub(all) suberror QuorumConfigError {
  ThresholdNotPositive(Int)
  ThresholdExceedsRoster(Int, Int)
  ThresholdNotMajority(Int, Int)
  DuplicateMember(String)
} derive(Eq, Debug)

///|
pub fn QuorumRoster::new(
  members : Array[PublicKey],
  threshold : Int,
) -> QuorumRoster raise QuorumConfigError {
  if threshold < 1 {
    raise ThresholdNotPositive(threshold)
  }
  if threshold > members.length() {
    raise ThresholdExceedsRoster(threshold, members.length())
  }
  if !@contracts.quorum_threshold_valid(members.length(), threshold) {
    raise ThresholdNotMajority(threshold, members.length())
  }
  let seen : Map[String, Unit] = Map([])
  for key in members {
    if seen.contains(key.0) {
      raise DuplicateMember(key.0)
    }
    seen[key.0] = ()
  }
  { members: members.copy(), threshold }
}

///|
pub fn QuorumRoster::members(self : QuorumRoster) -> Array[PublicKey] {
  self.members.copy()
}

///|
pub fn QuorumRoster::threshold(self : QuorumRoster) -> Int {
  self.threshold
}

///|
pub struct QuorumFinalizer {
  hasher : &Hasher
  verifier : &Verifier
  roster : QuorumRoster
}

///|
pub fn QuorumFinalizer::new(
  hasher : &Hasher,
  verifier : &Verifier,
  roster : QuorumRoster,
) -> QuorumFinalizer {
  { hasher, verifier, roster }
}

///|
pub impl Finalizer for QuorumFinalizer with fn verify_closure(self, certificate) {
  if !certificate_shape_ok(self.hasher, certificate) {
    return false
  }
  let digest = ClosurePayload::of(certificate).digest(self.hasher)
  let accepted : Map[String, Unit] = Map([])
  for attestation in certificate.attestations {
    if accepted.contains(attestation.signer.0) {
      continue
    }
    if !self.roster.members.contains(attestation.signer) {
      continue
    }
    if self.verifier.verify(attestation.signer, digest, attestation.signature) {
      accepted[attestation.signer.0] = ()
    }
  }
  accepted.length() >= self.roster.threshold
}

///|
/// A roster member that signs closure votes.
pub struct Voter[C] {
  hasher : &Hasher
  signer : &Signer
  order : CommandOrder[C]
}

///|
pub fn[C] Voter::new(
  hasher : &Hasher,
  signer : &Signer,
  order : CommandOrder[C],
) -> Voter[C] {
  { hasher, signer, order }
}

///|
pub fn[C] Voter::vote(
  self : Voter[C],
  tick : Int,
  parent_decision_hash : String,
  commands : Array[Envelope[C]],
) -> ClosureVote {
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
    voter: self.signer.public_key(),
    tick,
    parent_decision_hash,
    ordered_command_ids,
    ordered_commands_hash,
    signature: self.signer.sign(payload.digest(self.hasher)),
  }
}

///|
/// Assemble a certificate from vote knowledge, or `None` while no candidate
/// payload has reached the threshold. With a majority threshold at most one
/// candidate can ever qualify.
pub fn assemble_quorum_certificate(
  votes : VoteState,
  tick : Int,
  roster : QuorumRoster,
) -> ClosureCertificate? {
  let tally = votes.tally(tick, roster.members)
  let keys = tally.candidates.keys().to_array()
  keys.sort()
  let mut winner : Array[ClosureVote]? = None
  for key in keys {
    let list = tally.candidates.get(key).unwrap()
    if list.length() >= roster.threshold {
      match winner {
        Some(_) => abort("quorum invariant violated: two majority candidates")
        None => winner = Some(list)
      }
    }
  }
  match winner {
    None => None
    Some(list) => {
      let sample = list[0]
      let attestations = list.map(fn(vote) {
        { signer: vote.voter, signature: vote.signature }
      })
      attestations.sort_by(fn(a, b) { a.signer.0.compare(b.signer.0) })
      Some({
        tick: sample.tick,
        parent_decision_hash: sample.parent_decision_hash,
        ordered_command_ids: sample.ordered_command_ids,
        ordered_commands_hash: sample.ordered_commands_hash,
        attestations,
      })
    }
  }
}

///|
/// A vote counts only if its signer is a roster member and the signature
/// covers the vote's closure payload.
pub fn QuorumFinalizer::verify_vote(
  self : QuorumFinalizer,
  vote : ClosureVote,
) -> Bool {
  if !self.roster.members.contains(vote.voter) {
    return false
  }
  if hash_command_ids(self.hasher, vote.ordered_command_ids) !=
    vote.ordered_commands_hash {
    return false
  }
  self.verifier.verify(
    vote.voter,
    vote.payload().digest(self.hasher),
    vote.signature,
  )
}

///|
pub fn QuorumFinalizer::roster(self : QuorumFinalizer) -> QuorumRoster {
  self.roster
}

///|
pub fn[C] Voter::public_key(self : Voter[C]) -> PublicKey {
  self.signer.public_key()
}

///|
pub impl Finalizer for QuorumFinalizer with fn verify_base(self, certificate) {
  let digest = BasePayload::of(certificate).digest(self.hasher)
  let accepted : Map[String, Unit] = Map([])
  for attestation in certificate.attestations {
    if accepted.contains(attestation.signer.0) {
      continue
    }
    if !self.roster.members.contains(attestation.signer) {
      continue
    }
    if self.verifier.verify(attestation.signer, digest, attestation.signature) {
      accepted[attestation.signer.0] = ()
    }
  }
  accepted.length() >= self.roster.threshold
}

///|
pub fn QuorumFinalizer::verify_base_vote(
  self : QuorumFinalizer,
  vote : BaseVote,
) -> Bool {
  self.roster.members.contains(vote.voter) &&
  self.verifier.verify(
    vote.voter,
    vote.payload().digest(self.hasher),
    vote.signature,
  )
}

///|
pub fn[C] Voter::vote_base(
  self : Voter[C],
  next_tick : Int,
  decision_hash : String,
  state_hash : String,
) -> BaseVote {
  let payload : BasePayload = { next_tick, decision_hash, state_hash }
  {
    voter: self.signer.public_key(),
    next_tick,
    decision_hash,
    state_hash,
    signature: self.signer.sign(payload.digest(self.hasher)),
  }
}
