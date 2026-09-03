///|
/// Everything replicas exchange in the simulator.
pub(all) enum Gossip[S, C] {
  /// Proposals and closure certificates.
  DeltaGossip(@prdt.Delta[C])
  /// State transfer for a peer behind a compacted history.
  CatchupGossip(@prdt.Catchup[S, C])
  /// A replica asks its peers to close a tick with this command set.
  ClosureProposalGossip(ClosureProposal)
  /// A signed quorum vote.
  VoteGossip(@prdt.ClosureVote)
  /// A signed statement of a committed head, toward a base certificate.
  BaseVoteGossip(@prdt.BaseVote)
}

///|
pub(all) struct ClosureProposal {
  proposer : String
  tick : Int
  parent_decision_hash : String
  ordered_command_ids : Array[String]
} derive(Eq, Debug)
