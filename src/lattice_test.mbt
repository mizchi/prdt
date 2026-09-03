///|
fn env(replica : String, seq : Int, tick : Int, command : Int) -> Envelope[Int] {
  {
    id: command_id(replica, seq),
    tick,
    submitted_by: replica,
    local_sequence: seq,
    command,
  }
}

///|
test "proposal state is a set union keyed by command id" {
  let a = ProposalState::empty().add(env("x", 0, 0, 1))
  let b = ProposalState::empty().add(env("y", 0, 0, 2))
  let merged = a.merge(b)
  assert_eq(merged.list().map(fn(e) { e.id }), ["x:0", "y:0"])
  assert_true(merged.merge(a).equals(merged))
  assert_eq(lattice_law_violations(a, b, merged), [])
}

///|
test "proposal state refuses two payloads for one id without adopting either" {
  let a = ProposalState::empty().add(env("x", 0, 0, 1))
  let b = ProposalState::empty().add(env("x", 0, 0, 2))
  assert_eq(proposal_merge_error(a, b), Some(ConflictingProposal("x:0")))
  assert_eq(a.for_tick(0).get("x:0").unwrap().command, 1)
  assert_eq(b.for_tick(0).get("x:0").unwrap().command, 2)
}

///|
test "proposal list order does not depend on insertion order" {
  let s1 = ProposalState::empty().add(env("y", 0, 1, 1)).add(env("x", 0, 0, 2))
  let s2 = ProposalState::empty().add(env("x", 0, 0, 2)).add(env("y", 0, 1, 1))
  assert_eq(s1.list(), s2.list())
  assert_eq(s1.list().map(fn(e) { e.id }), ["x:0", "y:0"])
}

///|
fn cert(tick : Int, ids : Array[String], hash : String) -> ClosureCertificate {
  {
    tick,
    parent_decision_hash: "g",
    ordered_command_ids: ids,
    ordered_commands_hash: hash,
    attestations: [
      { signer: @prdt.PublicKey("a"), signature: @prdt.Signature("s") },
    ],
  }
}

///|
test "closure decision order: Pending <= Closed and Closed(a) == Closed(a)" {
  let a = cert(0, ["x:0"], "h1")
  let pending = ClosureDecision::ClosurePending
  let closed = ClosureDecision::Closed(a)
  assert_eq(merge_closure_decisions(pending, closed), closed)
  assert_eq(merge_closure_decisions(closed, pending), closed)
  assert_eq(merge_closure_decisions(closed, closed), closed)
  assert_eq(lattice_law_violations(pending, closed, closed), [])
}

///|
test "two different certificates for one tick can never be joined" {
  let a = ClosureMap::from_certificates([cert(0, ["x:0"], "h1")])
  let b = ClosureMap::from_certificates([cert(0, ["y:0"], "h2")])
  assert_eq(closure_merge_error(a, b), Some(ConflictingClosure(0)))
}

///|
test "closure certificate json round-trips" {
  let certificate = cert(4, ["x:0", "y:3"], "h")
  let decoded : ClosureCertificate = @json.from_json(certificate.to_json())
  assert_eq(decoded, certificate)
}

///|
fn batch(tick : Int, result_hash : String) -> CommittedBatch[Unit] {
  {
    tick,
    parent_decision_hash: "p",
    ordered_commands_hash: "o",
    result_hash,
    result: (),
  }
}

///|
test "committed log joins to the longer log when one is a prefix" {
  let l1 : CommittedLog[Unit] = CommittedLog::empty().append(batch(0, "a"))
  let l2 = l1.append(batch(1, "b"))
  assert_true(is_prefix_of(CommittedLog::empty(), l2))
  assert_true(is_prefix_of(l1, l2))
  assert_false(is_prefix_of(l2, l1))
  assert_true(l1.merge(l2).equals(l2))
  assert_true(l2.merge(l1).equals(l2))
  assert_eq(lattice_law_violations(CommittedLog::empty(), l1, l2), [])
  assert_eq(l2.head_decision_hash("genesis"), "b")
  let empty : CommittedLog[Unit] = CommittedLog::empty()
  assert_eq(empty.head_decision_hash("genesis"), "genesis")
}

///|
test "committed logs that diverge are a prefix conflict" {
  let l2 : CommittedLog[Unit] = CommittedLog::empty()
    .append(batch(0, "a"))
    .append(batch(1, "b"))
  let l2x : CommittedLog[Unit] = CommittedLog::empty()
    .append(batch(0, "a"))
    .append(batch(1, "c"))
  assert_eq(log_merge_error(l2, l2x), Some(PrefixConflict(1)))
}

///|
fn vote_for(voter : String, tick : Int, ids : Array[String]) -> ClosureVote {
  {
    voter: @prdt.PublicKey(voter),
    tick,
    parent_decision_hash: "p",
    ordered_command_ids: ids,
    ordered_commands_hash: ids.length().to_string(),
    signature: @prdt.Signature("sig-" + voter),
  }
}

///|
test "voter slot lattice turns conflicting votes into equivocation" {
  let a = VoterSlot::Voted(vote_for("a", 0, ["x"]))
  let b = VoterSlot::Voted(vote_for("a", 0, ["y"]))
  let merged = merge_voter_slots(a, b)
  guard merged is Equivocated(evidence) else { fail("expected equivocation") }
  assert_eq(evidence.length(), 2)
  assert_eq(merge_voter_slots(a, a), a)
  assert_eq(merge_voter_slots(merged, a), merged)
  assert_eq(lattice_law_violations(a, b, merged), [])
}

///|
test "vote state converges independently of delivery order" {
  let va = vote_for("a", 0, ["x"])
  let vb = vote_for("b", 0, ["x"])
  let va2 = vote_for("a", 0, ["y"])
  let s1 = VoteState::empty().add(va).add(vb).add(va2)
  let s2 = VoteState::empty().add(va2).add(va).add(vb)
  let s3 = VoteState::empty().add(vb).add(va2).add(va)
  assert_true(s1.equals(s2))
  assert_true(s2.equals(s3))
  let tally = s1.tally(0, [@prdt.PublicKey("a"), @prdt.PublicKey("b")])
  assert_eq(tally.equivocators, ["a"])
  assert_eq(tally.candidates.length(), 1)
  assert_eq(lattice_law_violations(s1, s2, s3), [])
}

///|
test "quorum roster requires a majority threshold" {
  let members = [
    @prdt.PublicKey("a"),
    @prdt.PublicKey("b"),
    @prdt.PublicKey("c"),
  ]
  assert_true(roster_error(members, 1) is Some(_))
  assert_true(roster_error(members, 2) is None)
  assert_true(roster_error(members, 4) is Some(_))
  let four = [
    @prdt.PublicKey("a"),
    @prdt.PublicKey("b"),
    @prdt.PublicKey("c"),
    @prdt.PublicKey("d"),
  ]
  assert_true(roster_error(four, 2) is Some(_))
  assert_true(
    roster_error([@prdt.PublicKey("a"), @prdt.PublicKey("a")], 2) is Some(_),
  )
}

///|
fn proposal_merge_error(
  a : ProposalState[Int],
  b : ProposalState[Int],
) -> ProtocolError? {
  try {
    let _ = a.merge(b)
    None
  } catch {
    error => Some(error)
  }
}

///|
fn closure_merge_error(a : ClosureMap, b : ClosureMap) -> ProtocolError? {
  try {
    let _ = a.merge(b)
    None
  } catch {
    error => Some(error)
  }
}

///|
fn log_merge_error(
  a : CommittedLog[Unit],
  b : CommittedLog[Unit],
) -> ProtocolError? {
  try {
    let _ = a.merge(b)
    None
  } catch {
    error => Some(error)
  }
}

///|
fn roster_error(
  members : Array[@prdt.PublicKey],
  threshold : Int,
) -> QuorumConfigError? {
  try {
    let _ = QuorumRoster::new(members, threshold)
    None
  } catch {
    error => Some(error)
  }
}
