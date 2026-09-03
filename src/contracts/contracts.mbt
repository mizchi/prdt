///|
/// Pure, integer-and-enum level facts that the executable protocol relies on.
/// This package has no dependencies so `moon prove` translates only what it
/// needs. Each function carries a post-condition discharged by Why3/Z3; the
/// lemmas in `contracts.mbtp` state the consequences the design depends on.

///|
/// `2 * threshold > size` is the safety condition of the quorum finalizer:
/// any two quorums intersect, so at most one payload per tick can close.
pub fn quorum_threshold_valid(
  size : Int,
  threshold : Int,
) -> Bool where {
  proof_ensure: result => quorum_threshold_valid_post(size, threshold, result),
} {
  let result = threshold >= 1 && threshold <= size && 2 * threshold > size
  proof_assert quorum_threshold_valid_post(size, threshold, result)
  result
}

///|
/// Number of oldest batches compaction folds into the base.
pub fn compaction_drop(
  length : Int,
  retain : Int,
) -> Int where {
  proof_require: length >= 0,
  proof_require: retain >= 0,
  proof_ensure: result => compaction_drop_post(length, retain, result),
} {
  let result = if length - retain > 0 { length - retain } else { 0 }
  proof_assert compaction_drop_post(length, retain, result)
  result
}

///|
/// Abstract shape of a command decision, used to state the decision order
/// without the generic payloads.
pub(all) enum DecisionKind {
  KindPending
  KindAccepted
  KindRejected
  KindLate
} derive(Eq, Debug)

///|
/// Decision order: Pending is the bottom; every final kind is only <= itself.
pub fn decision_kind_less_or_equal(
  before : DecisionKind,
  after : DecisionKind,
) -> Bool where {
  proof_ensure: result => {
    decision_kind_less_or_equal_post(before, after, result)
  },
} {
  let result = match before {
    KindPending => true
    KindAccepted =>
      match after {
        KindAccepted => true
        _ => false
      }
    KindRejected =>
      match after {
        KindRejected => true
        _ => false
      }
    KindLate =>
      match after {
        KindLate => true
        _ => false
      }
  }
  proof_assert decision_kind_less_or_equal_post(before, after, result)
  result
}

///|
/// Abstract shape of a `(tick, voter)` vote slot.
pub(all) enum VoteSlotKind {
  KindNoVote
  KindVoted
  KindEquivocated
} derive(Eq, Debug)

///|
/// Slot join, abstracted over payload equality of two `Voted` slots.
pub fn merge_vote_slot_kind(
  left : VoteSlotKind,
  right : VoteSlotKind,
  same_payload : Bool,
) -> VoteSlotKind where {
  proof_ensure: result => {
    merge_vote_slot_kind_post(left, right, same_payload, result)
  },
} {
  let result = match left {
    KindEquivocated => KindEquivocated
    KindNoVote => right
    KindVoted =>
      match right {
        KindEquivocated => KindEquivocated
        KindNoVote => KindVoted
        KindVoted => if same_payload { KindVoted } else { KindEquivocated }
      }
  }
  proof_assert merge_vote_slot_kind_post(left, right, same_payload, result)
  result
}
