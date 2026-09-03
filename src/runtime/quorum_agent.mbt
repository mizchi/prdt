///|
/// Quorum closure in the runtime.
///
/// Any replica may propose to close its next tick with the command set it
/// knows. A voter signs the first proposal for a tick that (1) targets its
/// own next tick, (2) chains from its committed head, (3) lists only known
/// commands in canonical order. One vote per tick per voter. Whoever collects
/// a majority assembles the certificate and gossips it as a delta.
///
/// Safety comes from the vote lattice and the majority threshold; liveness
/// is best effort (a partition or disagreeing proposers can stall a tick
/// until knowledge converges). `equivocate` turns the agent into a faulty
/// voter that also signs a conflicting empty set for every proposal it makes.
pub struct QuorumAgent[S, C, E, R] {
  replica : Replica[S, C, E, R]
  voter : @prdt.Voter[C]
  finalizer : @prdt.QuorumFinalizer
  mut votes : @prdt.VoteState
  mut base_votes : @prdt.BaseVoteState
  /// Highest `next_tick` this agent has signed a base vote for.
  mut base_voted_through : Int
  pending : Array[ClosureProposal]
  equivocate : Bool
}

///|
pub fn[S, C, E, R] QuorumAgent::new(
  replica : Replica[S, C, E, R],
  voter : @prdt.Voter[C],
  finalizer : @prdt.QuorumFinalizer,
  equivocate? : Bool = false,
) -> QuorumAgent[S, C, E, R] {
  {
    replica,
    voter,
    finalizer,
    votes: @prdt.VoteState::empty(),
    base_votes: @prdt.BaseVoteState::empty(),
    base_voted_through: -1,
    pending: [],
    equivocate,
  }
}

///|
pub fn[S, C, E, R] QuorumAgent::replica(
  self : QuorumAgent[S, C, E, R],
) -> Replica[S, C, E, R] {
  self.replica
}

///|
pub fn[S, C, E, R] QuorumAgent::votes(
  self : QuorumAgent[S, C, E, R],
) -> @prdt.VoteState {
  self.votes
}

///|
fn[S, C, E, R] QuorumAgent::has_voted(
  self : QuorumAgent[S, C, E, R],
  tick : Int,
) -> Bool {
  self.votes.slot(tick, self.voter.public_key()) is Some(_)
}

///|
fn[S, C, E, R] QuorumAgent::known_for(
  self : QuorumAgent[S, C, E, R],
  tick : Int,
  ids : Array[String],
) -> Array[@prdt.Envelope[C]]? {
  let known = self.replica.object().state().proposals().for_tick(tick)
  let out = []
  for id in ids {
    match known.get(id) {
      Some(envelope) => out.push(envelope)
      None => return None
    }
  }
  Some(out)
}

///|
/// Propose closing the next tick with everything known for it. Returns the
/// gossip to broadcast (proposal + own vote, plus a conflicting vote when
/// equivocating). Empty when this voter already voted for the tick.
pub fn[S, C, E, R] QuorumAgent::propose_closure(
  self : QuorumAgent[S, C, E, R],
) -> Array[Gossip[S, C]] {
  let tick = self.replica.next_tick()
  if self.has_voted(tick) {
    return []
  }
  let parent = self.replica.decision().head_decision_hash()
  let known = self.replica
    .object()
    .state()
    .proposals()
    .for_tick(tick)
    .values()
    .to_array()
  let vote = self.voter.vote(tick, parent, known)
  self.votes = self.votes.add(vote)
  let out : Array[Gossip[S, C]] = [
    ClosureProposalGossip({
      proposer: self.replica.id(),
      tick,
      parent_decision_hash: parent,
      ordered_command_ids: vote.ordered_command_ids,
    }),
    VoteGossip(vote),
  ]
  if self.equivocate && known.length() > 0 {
    // A faulty voter also signs the empty set for the same tick.
    out.push(VoteGossip(self.voter.vote(tick, parent, [])))
  }
  out
}

///|
fn[S, C, E, R] QuorumAgent::consider(
  self : QuorumAgent[S, C, E, R],
  proposal : ClosureProposal,
) -> Gossip[S, C]? {
  if proposal.tick != self.replica.next_tick() {
    return None
  }
  if proposal.parent_decision_hash !=
    self.replica.decision().head_decision_hash() {
    return None
  }
  if self.has_voted(proposal.tick) {
    return None
  }
  let envelopes = match
    self.known_for(proposal.tick, proposal.ordered_command_ids) {
    Some(envelopes) => envelopes
    None => return None
  }
  let vote = self.voter.vote(
    proposal.tick,
    proposal.parent_decision_hash,
    envelopes,
  )
  if vote.ordered_command_ids != proposal.ordered_command_ids {
    return None // not canonical order; ignore the proposal
  }
  self.votes = self.votes.add(vote)
  Some(VoteGossip(vote))
}

///|
/// Vote for buffered proposals that became valid after new knowledge arrived.
pub fn[S, C, E, R] QuorumAgent::retry_pending(
  self : QuorumAgent[S, C, E, R],
) -> Array[Gossip[S, C]] {
  let out = []
  let next_tick = self.replica.next_tick()
  let keep = []
  for proposal in self.pending {
    if proposal.tick < next_tick {
      continue
    }
    match self.consider(proposal) {
      Some(gossip) => out.push(gossip)
      None => keep.push(proposal)
    }
  }
  self.pending.clear()
  for proposal in keep {
    self.pending.push(proposal)
  }
  out
}

///|
/// Try to assemble a certificate for the next tick from known votes.
pub fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] QuorumAgent::try_close(
  self : QuorumAgent[S, C, E, R],
) -> Array[Gossip[S, C]] raise @prdt.ProtocolError {
  let tick = self.replica.next_tick()
  match
    @prdt.assemble_quorum_certificate(self.votes, tick, self.finalizer.roster()) {
    None => []
    Some(certificate) => {
      self.replica.object().close_tick(certificate)
      let _ = self.replica.checkpoint()
      [
        DeltaGossip({
          proposals: [],
          closures: [certificate],
          base_certificates: [],
        }),
      ]
    }
  }
}

///|
/// Sign a base vote for the current committed head once per head.
fn[S : ToJson, C, E, R] QuorumAgent::vote_bases(
  self : QuorumAgent[S, C, E, R],
) -> Array[Gossip[S, C]] {
  let next_tick = self.replica.next_tick()
  if next_tick <= self.base_voted_through {
    return []
  }
  self.base_voted_through = next_tick
  let vote = self.voter.vote_base(
    next_tick,
    self.replica.decision().head_decision_hash(),
    @prdt.hash_value(
      self.replica.protocol().hasher(),
      self.replica.domain_state(),
    ),
  )
  self.base_votes = self.base_votes.add(vote)
  [BaseVoteGossip(vote)]
}

///|
/// Install and gossip a base certificate once a majority signed this head.
fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] QuorumAgent::try_certify_base(
  self : QuorumAgent[S, C, E, R],
  next_tick : Int,
) -> Array[Gossip[S, C]] raise @prdt.ProtocolError {
  let state = self.replica.object().state()
  if next_tick < state.base().next_tick || next_tick > self.replica.next_tick() {
    return []
  }
  if state.certified_bases().iter().any(fn(c) { c.next_tick == next_tick }) {
    return []
  }
  match
    @prdt.assemble_base_certificate(
      self.base_votes,
      next_tick,
      self.finalizer.roster(),
    ) {
    None => []
    Some(certificate) => {
      let delta : @prdt.Delta[C] = {
        proposals: [],
        closures: [],
        base_certificates: [certificate],
      }
      self.replica.receive(delta)
      self.base_votes = self.base_votes.prune_below(state.base().next_tick)
      [DeltaGossip(delta)]
    }
  }
}

///|
/// Handle one gossip message; returns the gossip to broadcast in response.
pub fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] QuorumAgent::receive(
  self : QuorumAgent[S, C, E, R],
  gossip : Gossip[S, C],
) -> Array[Gossip[S, C]] raise @prdt.ProtocolError {
  let out : Array[Gossip[S, C]] = []
  match gossip {
    DeltaGossip(delta) => self.replica.receive(delta)
    CatchupGossip(catchup) => self.replica.receive_catchup(catchup)
    ClosureProposalGossip(proposal) =>
      match self.consider(proposal) {
        Some(vote) => out.push(vote)
        None =>
          if proposal.tick >= self.replica.next_tick() {
            self.pending.push(proposal)
          }
      }
    VoteGossip(vote) =>
      if self.finalizer.verify_vote(vote) {
        self.votes = self.votes.add(vote)
      }
    BaseVoteGossip(vote) =>
      if self.finalizer.verify_base_vote(vote) {
        self.base_votes = self.base_votes.add(vote)
        for item in self.try_certify_base(vote.next_tick) {
          out.push(item)
        }
      }
  }
  for gossip in self.retry_pending() {
    out.push(gossip)
  }
  for gossip in self.try_close() {
    out.push(gossip)
  }
  for gossip in self.vote_bases() {
    out.push(gossip)
  }
  for gossip in self.try_certify_base(self.replica.next_tick()) {
    out.push(gossip)
  }
  out
}

///|
/// Base votes and certificates this agent can emit right now (used after a
/// local closure so the new head gets certified).
pub fn[S : ToJson, C : Eq + ToJson, E : ToJson, R : ToJson] QuorumAgent::certify_head(
  self : QuorumAgent[S, C, E, R],
) -> Array[Gossip[S, C]] raise @prdt.ProtocolError {
  let out = self.vote_bases()
  for gossip in self.try_certify_base(self.replica.next_tick()) {
    out.push(gossip)
  }
  out
}
