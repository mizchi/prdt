///|
test "canonical json sorts object keys recursively and keeps array order" {
  let value : Json = { "b": 1, "a": { "z": [3, 1, 2], "y": true } }
  assert_eq(canonicalize(value), "{\"a\":{\"y\":true,\"z\":[3,1,2]},\"b\":1}")
  let reordered : Json = { "a": { "y": true, "z": [3, 1, 2] }, "b": 1 }
  assert_eq(canonicalize(value), canonicalize(reordered))
}

///|
test "sha256 hasher matches FIPS vectors and hex round-trips" {
  let hasher = Sha256Hasher::new()
  assert_eq(
    hasher.hash_string("").0,
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    hasher.hash_string("abc").0,
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  let bytes = bytes_from_lower_hex("00ff10").unwrap()
  assert_eq(bytes_to_lower_hex(bytes), "00ff10")
  assert_eq(bytes_from_lower_hex("abc"), None)
}

///|
test "shared-secret authenticator verifies only its own key and digest" {
  let hasher = Sha256Hasher::new()
  let auth = SharedSecretAuthenticator::new("authority", "s3cret")
  let other = SharedSecretAuthenticator::new("authority", "different")
  let digest = hasher.hash_string("payload")
  let signature = auth.sign(digest)
  assert_true(auth.verify(auth.public_key(), digest, signature))
  assert_false(auth.verify(@prdt.PublicKey("someone-else"), digest, signature))
  assert_false(
    auth.verify(auth.public_key(), hasher.hash_string("other"), signature),
  )
  assert_false(other.verify(other.public_key(), digest, signature))
}

///|
test "envelope json round-trips" {
  let envelope : Envelope[Int] = {
    id: "x:0",
    tick: 3,
    submitted_by: "x",
    local_sequence: 0,
    command: 42,
  }
  let decoded : Envelope[Int] = @json.from_json(envelope.to_json())
  assert_eq(decoded, envelope)
}
