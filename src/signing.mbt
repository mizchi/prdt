///|
/// Shared-secret HMAC-SHA256 authenticator implementing the
/// `Signer` and `Verifier` traits.
///
/// This is a MAC, not a signature: anyone who can verify can also forge.
/// It is meant for tests and local development. Deployments should plug an
/// Ed25519 signer/verifier (for example the experimental adapter in
/// `x/game_audit/crypto`) through the same traits.
pub struct SharedSecretAuthenticator {
  key : Bytes
  public_key : PublicKey
}

///|
pub fn SharedSecretAuthenticator::new(
  key_id : String,
  secret : String,
) -> SharedSecretAuthenticator {
  {
    key: @utf8.encode(("prdt/shared-secret/v1:" + secret)[:]),
    public_key: PublicKey(key_id),
  }
}

///|
fn SharedSecretAuthenticator::tag(
  self : SharedSecretAuthenticator,
  digest : Digest,
) -> String {
  bytes_to_lower_hex(@hash.hmac_sha256(self.key, @utf8.encode(digest.0[:])))
}

///|
pub impl Signer for SharedSecretAuthenticator with fn sign(self, digest) {
  Signature(self.tag(digest))
}

///|
pub impl Signer for SharedSecretAuthenticator with fn public_key(self) {
  self.public_key
}

///|
pub impl Verifier for SharedSecretAuthenticator with fn verify(
  self,
  key,
  digest,
  signature,
) {
  key == self.public_key && signature.0 == self.tag(digest)
}

///|
/// Dispatches verification to the verifier registered for each public key.
/// Lets a quorum roster mix key types behind one `Verifier`.
pub struct KeyedVerifier {
  verifiers : Map[String, &Verifier]
}

///|
pub fn KeyedVerifier::new() -> KeyedVerifier {
  { verifiers: Map([]) }
}

///|
pub fn KeyedVerifier::register(
  self : KeyedVerifier,
  key : PublicKey,
  verifier : &Verifier,
) -> Unit {
  self.verifiers[key.0] = verifier
}

///|
pub impl Verifier for KeyedVerifier with fn verify(self, key, digest, signature) {
  match self.verifiers.get(key.0) {
    Some(verifier) => verifier.verify(key, digest, signature)
    None => false
  }
}
