///|
/// Voting PRDT for quorum closure.
///
/// Each `(tick, voter)` slot is a small lattice:
///   Voted(v)  <=  Equivocated(S)          when v in S
///   Voted(a) join Voted(b) = Voted(a)      if a == b
///                          = Equivocated({a, b}) otherwise
/// An equivocating voter never counts toward a quorum. Because the slot
/// lattice is grow-only, vote knowledge converges regardless of delivery
/// order or duplication.
pub(all) struct ClosureVote {
  voter : PublicKey
  tick : Int
  parent_decision_hash : String
  ordered_command_ids : Array[String]
  ordered_commands_hash : String
  signature : Signature
} derive(Eq, Debug)

///|
pub fn ClosureVote::payload(self : ClosureVote) -> ClosurePayload {
  {
    tick: self.tick,
    parent_decision_hash: self.parent_decision_hash,
    ordered_commands_hash: self.ordered_commands_hash,
  }
}

///|
fn ClosureVote::sort_key(self : ClosureVote) -> String {
  canonicalize({
    "voter": self.voter.0.to_json(),
    "tick": self.tick.to_json(),
    "parent_decision_hash": self.parent_decision_hash.to_json(),
    "ordered_command_ids": self.ordered_command_ids.to_json(),
    "ordered_commands_hash": self.ordered_commands_hash.to_json(),
    "signature": self.signature.0.to_json(),
  })
}

///|
pub(all) enum VoterSlot {
  Voted(ClosureVote)
  Equivocated(Array[ClosureVote])
} derive(Eq, Debug)

///|
fn evidence_union(votes : Array[ClosureVote]) -> Array[ClosureVote] {
  let by_key : Map[String, ClosureVote] = Map([])
  for vote in votes {
    by_key[vote.sort_key()] = vote
  }
  let keys = by_key.keys().to_array()
  keys.sort()
  keys.map(fn(key) { by_key.get(key).unwrap() })
}

///|
pub fn merge_voter_slots(left : VoterSlot, right : VoterSlot) -> VoterSlot {
  match (left, right) {
    (Voted(a), Voted(b)) =>
      if a == b {
        left
      } else {
        Equivocated(evidence_union([a, b]))
      }
    (Voted(a), Equivocated(evidence)) | (Equivocated(evidence), Voted(a)) => {
      let all = evidence.copy()
      all.push(a)
      Equivocated(evidence_union(all))
    }
    (Equivocated(a), Equivocated(b)) => {
      let all = a.copy()
      for vote in b {
        all.push(vote)
      }
      Equivocated(evidence_union(all))
    }
  }
}

///|
pub impl JoinSemilattice for VoterSlot with fn join(a, b) {
  merge_voter_slots(a, b)
}

///|
pub impl JoinSemilattice for VoterSlot with fn equivalent(a, b) {
  a == b
}

///|
pub struct VoteState {
  by_tick : Map[Int, Map[String, VoterSlot]]
}

///|
pub fn VoteState::empty() -> VoteState {
  { by_tick: {} }
}

///|
pub fn VoteState::merge(self : VoteState, other : VoteState) -> VoteState {
  let by_tick : Map[Int, Map[String, VoterSlot]] = Map([])
  for tick, slots in self.by_tick {
    let copy : Map[String, VoterSlot] = Map([])
    for voter, slot in slots {
      copy[voter] = slot
    }
    by_tick[tick] = copy
  }
  for tick, slots in other.by_tick {
    let target = match by_tick.get(tick) {
      Some(existing) => existing
      None => {
        let fresh : Map[String, VoterSlot] = Map([])
        by_tick[tick] = fresh
        fresh
      }
    }
    for voter, slot in slots {
      target[voter] = match target.get(voter) {
        Some(existing) => merge_voter_slots(existing, slot)
        None => slot
      }
    }
  }
  { by_tick, }
}

///|
pub fn VoteState::add(self : VoteState, vote : ClosureVote) -> VoteState {
  let slots : Map[String, VoterSlot] = Map([])
  slots[vote.voter.0] = Voted(vote)
  let by_tick : Map[Int, Map[String, VoterSlot]] = Map([])
  by_tick[vote.tick] = slots
  self.merge({ by_tick, })
}

///|
pub fn VoteState::equals(self : VoteState, other : VoteState) -> Bool {
  let mut mine = 0
  for tick, slots in self.by_tick {
    let theirs = match other.by_tick.get(tick) {
      Some(theirs) => theirs
      None => if slots.length() == 0 { continue } else { return false }
    }
    for voter, slot in slots {
      mine += 1
      match theirs.get(voter) {
        Some(other_slot) => if other_slot != slot { return false }
        None => return false
      }
    }
  }
  let mut count = 0
  for _, slots in other.by_tick {
    count += slots.length()
  }
  mine == count
}

///|
pub impl JoinSemilattice for VoteState with fn join(a, b) {
  a.merge(b)
}

///|
pub impl JoinSemilattice for VoteState with fn equivalent(a, b) {
  a.equals(b)
}

///|
/// Candidate payloads for one tick with the non-equivocating roster votes
/// behind each, plus the voters excluded for equivocation.
pub(all) struct VoteTally {
  candidates : Map[String, Array[ClosureVote]]
  equivocators : Array[String]
}

///|
pub fn VoteState::tally(
  self : VoteState,
  tick : Int,
  roster : Array[PublicKey],
) -> VoteTally {
  let candidates : Map[String, Array[ClosureVote]] = Map([])
  let equivocators = []
  let slots = match self.by_tick.get(tick) {
    Some(slots) => slots
    None => {}
  }
  let voters = slots.keys().to_array()
  voters.sort()
  for voter in voters {
    if !roster.contains(PublicKey(voter)) {
      continue
    }
    match slots.get(voter).unwrap() {
      Equivocated(_) => equivocators.push(voter)
      Voted(vote) => {
        let key = canonicalize({
          "tick": vote.tick.to_json(),
          "parent_decision_hash": vote.parent_decision_hash.to_json(),
          "ordered_command_ids": vote.ordered_command_ids.to_json(),
          "ordered_commands_hash": vote.ordered_commands_hash.to_json(),
        })
        match candidates.get(key) {
          Some(list) => list.push(vote)
          None => candidates[key] = [vote]
        }
      }
    }
  }
  { candidates, equivocators }
}

///|
pub fn VoteState::slot(
  self : VoteState,
  tick : Int,
  voter : PublicKey,
) -> VoterSlot? {
  match self.by_tick.get(tick) {
    Some(slots) => slots.get(voter.0)
    None => None
  }
}

///|
pub impl ToJson for ClosureVote with fn to_json(self) {
  {
    "voter": self.voter.0.to_json(),
    "tick": self.tick.to_json(),
    "parent_decision_hash": self.parent_decision_hash.to_json(),
    "ordered_command_ids": self.ordered_command_ids.to_json(),
    "ordered_commands_hash": self.ordered_commands_hash.to_json(),
    "signature": self.signature.0.to_json(),
  }
}

///|
pub impl @json.FromJson for ClosureVote with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "ClosureVote: expected object"))
  }
  let voter : String = @json.from_json(
    json_field(fields, "voter", path),
    path=path.add_key("voter"),
  )
  let signature : String = @json.from_json(
    json_field(fields, "signature", path),
    path=path.add_key("signature"),
  )
  {
    voter: PublicKey(voter),
    tick: @json.from_json(
      json_field(fields, "tick", path),
      path=path.add_key("tick"),
    ),
    parent_decision_hash: @json.from_json(
      json_field(fields, "parent_decision_hash", path),
      path=path.add_key("parent_decision_hash"),
    ),
    ordered_command_ids: @json.from_json(
      json_field(fields, "ordered_command_ids", path),
      path=path.add_key("ordered_command_ids"),
    ),
    ordered_commands_hash: @json.from_json(
      json_field(fields, "ordered_commands_hash", path),
      path=path.add_key("ordered_commands_hash"),
    ),
    signature: Signature(signature),
  }
}
