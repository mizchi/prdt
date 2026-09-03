///|
/// Hashing and signing interfaces.
///
/// These mirror the `Hasher` / `Signer` / `Verifier` traits of
/// `mizchi/converge_audit`, so an adapter between the two is a one-line
/// `impl`. The protocol assumes hash collision resistance and signature
/// unforgeability; it does not prove them.
pub(all) struct Digest(String) derive(Eq, Compare, Hash, Debug)

///|
pub(all) struct Signature(String) derive(Eq, Debug)

///|
pub(all) struct PublicKey(String) derive(Eq, Hash, Debug)

///|
pub(open) trait Hasher {
  fn hash_string(Self, String) -> Digest
}

///|
pub(open) trait Signer {
  fn sign(Self, Digest) -> Signature
  fn public_key(Self) -> PublicKey
}

///|
pub(open) trait Verifier {
  fn verify(Self, PublicKey, Digest, Signature) -> Bool
}

///|
/// Digests, signatures, and keys travel as plain JSON strings.
pub impl ToJson for Digest with fn to_json(self) {
  self.0.to_json()
}

///|
pub impl @json.FromJson for Digest with fn from_json(json, path) {
  Digest(@json.from_json(json, path~))
}

///|
pub impl ToJson for Signature with fn to_json(self) {
  self.0.to_json()
}

///|
pub impl @json.FromJson for Signature with fn from_json(json, path) {
  Signature(@json.from_json(json, path~))
}

///|
pub impl ToJson for PublicKey with fn to_json(self) {
  self.0.to_json()
}

///|
pub impl @json.FromJson for PublicKey with fn from_json(json, path) {
  PublicKey(@json.from_json(json, path~))
}
