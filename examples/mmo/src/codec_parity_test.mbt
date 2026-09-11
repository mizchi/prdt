///|
/// The encoding is a deployment choice, not a protocol change: the same
/// scenario must reach the same verdicts and the same world under any codec.
/// Only the digests differ, because they are hashes of the encoded bytes.
let parity_codecs : Array[(String, &@prdt.Codec)] = [
  ("json", @prdt.json_codec),
  ("binary", @prdt.binary_codec),
]

///|
/// Runs the lethal race to completion and reports what the domain decided,
/// independently of how anything was encoded.
fn lethal_race_outcome(
  codec : &@prdt.Codec,
) -> (Array[String], Int?, @prdt.Delta[GameCommand], GameObject) raise Error {
  let s = setup(codec~)
  let x = @prdt.ReplicatedDomain::new(s.protocol, "X")
  let y = @prdt.ReplicatedDomain::new(s.protocol, "Y")
  let skill = x.propose(0, fireball())
  let damage = y.propose(0, lethal_hit())
  let auth = @prdt.ReplicatedDomain::new(s.protocol, "A")
  auth.merge(damage.delta)
  auth.merge(skill.delta)
  let certificate = close_next(auth, s.authority)
  x.merge(closures([certificate]))
  x.merge(damage.delta)
  y.merge(skill.delta)
  y.merge(closures([certificate]))
  let decision = auth.decision()
  let verdicts = decision
    .command_ids()
    .map(fn(id) { id + "=" + Repr(decision.of(id)).to_string() })
  (verdicts, auth.domain_state().hp(player_a), auth.delta(), auth)
}

///|
test "the codec changes the bytes, never the decisions" {
  let mut expected_verdicts : Array[String]? = None
  let mut expected_hp : Int?? = None
  for entry in parity_codecs {
    let (verdicts, hp, _, _) = lethal_race_outcome(entry.1)
    match expected_verdicts {
      None => {
        expected_verdicts = Some(verdicts)
        expected_hp = Some(hp)
      }
      Some(first) => {
        assert_eq(verdicts, first)
        assert_eq(Some(hp), expected_hp)
      }
    }
  }
  // The digests are hashes of the encoding, so they must NOT agree.
  let (_, _, _, json_run) = lethal_race_outcome(@prdt.json_codec)
  let (_, _, _, binary_run) = lethal_race_outcome(@prdt.binary_codec)
  assert_not_eq(json_run.state_hash(), binary_run.state_hash())
}

///|
test "snapshots and deltas round-trip as bytes under every codec" {
  for entry in parity_codecs {
    let (_, _, delta, replica) = lethal_race_outcome(entry.1)
    let protocol = replica.protocol()

    // Snapshot: bytes out, replica back in, same state hash and same world.
    let bytes = replica.snapshot_bytes()
    let restored = @prdt.ReplicatedDomain::restore_bytes(protocol, bytes[:])
    assert_eq(restored.state_hash(), replica.state_hash())
    assert_eq(restored.domain_state(), replica.domain_state())

    // Delta: what one replica gossips is what another decodes.
    let encoded = protocol.encode(delta)
    let decoded : @prdt.Delta[GameCommand] = protocol.decode(
      encoded[:],
      "delta",
    )
    assert_eq(decoded, delta)
    assert_eq(protocol.codec().name(), entry.1.name())
  }
}

///|
test "a snapshot in the wrong encoding is refused, not misread" {
  let json_replica = lethal_race_outcome(@prdt.json_codec).3
  let binary_replica = lethal_race_outcome(@prdt.binary_codec).3
  let failure = try {
    let _ = @prdt.ReplicatedDomain::restore_bytes(
      binary_replica.protocol(),
      json_replica.snapshot_bytes()[:],
    )
    "restored"
  } catch {
    error => error.kind()
  }
  assert_eq(failure, "SnapshotMismatch")
}

///|
test "the binary encoding is materially smaller than json" {
  let (_, _, delta, replica) = lethal_race_outcome(@prdt.binary_codec)
  let json_snapshot = @prdt.json_codec.encode(
    lethal_race_outcome(@prdt.json_codec).3.snapshot(),
  )
  let binary_snapshot = replica.snapshot_bytes()
  assert_true(binary_snapshot.length() < json_snapshot.length())
  let json_delta = @prdt.json_codec.encode(delta.to_json())
  let binary_delta = @prdt.binary_codec.encode(delta.to_json())
  assert_true(binary_delta.length() < json_delta.length())
}
