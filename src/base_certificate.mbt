///|
/// Authenticated bases.
///
/// A base (the decision hash and domain state at `next_tick - 1`) cannot be
/// re-derived by a receiver once the history behind it was compacted, so a
/// base handed over in a `Catchup` must be certified: signed by the closure
/// authority, or by a quorum of the roster. Certificate identity is the
/// payload; attestations are proof.
pub(all) struct BaseCertificate {
  next_tick : Int
  decision_hash : String
  state_hash : String
  attestations : Array[Attestation]
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct BasePayload {
  next_tick : Int
  decision_hash : String
  state_hash : String
} derive(Eq, Debug, ToJson)

///|
pub let base_message_domain : String = "prdt/base/v1"

///|
pub fn BasePayload::of(certificate : BaseCertificate) -> BasePayload {
  {
    next_tick: certificate.next_tick,
    decision_hash: certificate.decision_hash,
    state_hash: certificate.state_hash,
  }
}

///|
pub fn BasePayload::message(self : BasePayload) -> String {
  canonicalize({
    "domain": base_message_domain.to_json(),
    "next_tick": self.next_tick.to_json(),
    "decision_hash": self.decision_hash.to_json(),
    "state_hash": self.state_hash.to_json(),
  })
}

///|
pub fn BasePayload::digest(self : BasePayload, hasher : &Hasher) -> Digest {
  hasher.hash_string(self.message())
}

///|
pub fn BaseCertificate::same_base(
  self : BaseCertificate,
  other : BaseCertificate,
) -> Bool {
  self.next_tick == other.next_tick &&
  self.decision_hash == other.decision_hash &&
  self.state_hash == other.state_hash
}

///|
pub fn BaseCertificate::payload_json(self : BaseCertificate) -> Json {
  BasePayload::of(self).to_json()
}

///|
/// A roster member's signed statement that its committed head at
/// `next_tick - 1` has this decision hash and domain state hash.
pub(all) struct BaseVote {
  voter : PublicKey
  next_tick : Int
  decision_hash : String
  state_hash : String
  signature : Signature
} derive(Eq, Debug, ToJson, FromJson)

///|
pub fn BaseVote::payload(self : BaseVote) -> BasePayload {
  {
    next_tick: self.next_tick,
    decision_hash: self.decision_hash,
    state_hash: self.state_hash,
  }
}

///|
/// Per `(next_tick, voter)` slot lattice for base votes, mirroring closure
/// votes: a voter that signs two different bases for one tick equivocates
/// and never counts.
pub(all) enum BaseVoteSlot {
  BaseVoted(BaseVote)
  BaseEquivocated
} derive(Eq, Debug)

///|
pub fn merge_base_vote_slots(
  left : BaseVoteSlot,
  right : BaseVoteSlot,
) -> BaseVoteSlot {
  match (left, right) {
    (BaseVoted(a), BaseVoted(b)) =>
      if a.payload() == b.payload() {
        left
      } else {
        BaseEquivocated
      }
    _ => BaseEquivocated
  }
}

///|
pub struct BaseVoteState {
  by_tick : Map[Int, Map[String, BaseVoteSlot]]
}

///|
pub fn BaseVoteState::empty() -> BaseVoteState {
  { by_tick: Map([]) }
}

///|
pub fn BaseVoteState::add(
  self : BaseVoteState,
  vote : BaseVote,
) -> BaseVoteState {
  let by_tick : Map[Int, Map[String, BaseVoteSlot]] = Map([])
  for tick, slots in self.by_tick {
    let copy : Map[String, BaseVoteSlot] = Map([])
    for voter, slot in slots {
      copy[voter] = slot
    }
    by_tick[tick] = copy
  }
  let slots = match by_tick.get(vote.next_tick) {
    Some(slots) => slots
    None => {
      let fresh : Map[String, BaseVoteSlot] = Map([])
      by_tick[vote.next_tick] = fresh
      fresh
    }
  }
  slots[vote.voter.0] = match slots.get(vote.voter.0) {
    Some(existing) => merge_base_vote_slots(existing, BaseVoted(vote))
    None => BaseVoted(vote)
  }
  { by_tick, }
}

///|
/// Drop ticks below `tick`.
pub fn BaseVoteState::prune_below(
  self : BaseVoteState,
  tick : Int,
) -> BaseVoteState {
  let by_tick : Map[Int, Map[String, BaseVoteSlot]] = Map([])
  for known_tick, slots in self.by_tick {
    if known_tick >= tick {
      by_tick[known_tick] = slots
    }
  }
  { by_tick, }
}

///|
/// Certificate for `next_tick` once a majority of roster members signed the
/// same base payload; `None` otherwise.
pub fn assemble_base_certificate(
  votes : BaseVoteState,
  next_tick : Int,
  roster : QuorumRoster,
) -> BaseCertificate? {
  let slots = match votes.by_tick.get(next_tick) {
    Some(slots) => slots
    None => return None
  }
  let candidates : Map[String, Array[BaseVote]] = Map([])
  let voters = slots.keys().to_array()
  voters.sort()
  for voter in voters {
    if !roster.members.contains(PublicKey(voter)) {
      continue
    }
    match slots.get(voter).unwrap() {
      BaseEquivocated => ()
      BaseVoted(vote) => {
        let key = canonicalize(vote.payload().message().to_json())
        match candidates.get(key) {
          Some(list) => list.push(vote)
          None => candidates[key] = [vote]
        }
      }
    }
  }
  let keys = candidates.keys().to_array()
  keys.sort()
  for key in keys {
    let list = candidates.get(key).unwrap()
    if list.length() >= roster.threshold {
      let sample = list[0]
      let attestations = list.map(fn(vote) {
        { signer: vote.voter, signature: vote.signature }
      })
      attestations.sort_by(fn(a, b) { a.signer.0.compare(b.signer.0) })
      return Some({
        next_tick: sample.next_tick,
        decision_hash: sample.decision_hash,
        state_hash: sample.state_hash,
        attestations,
      })
    }
  }
  None
}
