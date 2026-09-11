///|
/// Canonical JSON: object keys sorted recursively by UTF-16 code units (the
/// JCS / RFC 8785 order, which is also what JavaScript's default string
/// comparison gives), arrays kept in order.
///
/// This is the byte representation of `JsonCodec`, the default encoding: keys
/// are ordered so that all replicas encode the same logical value to the same
/// bytes regardless of insertion order or Map iteration order. MoonBit's own
/// `String` ordering compares lengths first, so it is not used here.
pub fn canonical_json(value : Json) -> Json {
  match value {
    Object(fields) => {
      let keys = fields.keys().to_array()
      keys.sort_by(compare_code_units)
      let sorted : Map[String, Json] = Map([])
      for key in keys {
        sorted[key] = canonical_json(fields.get(key).unwrap())
      }
      Json::object(sorted)
    }
    Array(items) => Json::array(items.map(canonical_json))
    other => other
  }
}

///|
fn compare_code_units(left : String, right : String) -> Int {
  let shared = if left.length() < right.length() {
    left.length()
  } else {
    right.length()
  }
  for i in 0..<shared {
    let order = left.unsafe_get(i).compare(right.unsafe_get(i))
    if order != 0 {
      return order
    }
  }
  left.length().compare(right.length())
}

///|
pub fn canonicalize(value : Json) -> String {
  canonical_json(value).stringify()
}

///|
/// A hash function paired with the encoding whose bytes it hashes.
///
/// Every digest in the protocol is `hasher(codec.encode(document))`, so the
/// two travel together: replicas that agree on both agree on every hash, and
/// changing the codec changes the hashes consistently everywhere. Build one
/// and pass it to `Protocol::new` and to the finalizers, rather than letting
/// each component pick its own.
pub struct Hashing {
  hasher : &Hasher
  codec : &Codec
}

///|
/// Defaults to canonical JSON, which is what a deployment gets unless it
/// deliberately chooses another encoding.
pub fn Hashing::new(hasher : &Hasher, codec? : &Codec = json_codec) -> Hashing {
  { hasher, codec }
}

///|
pub fn Hashing::hasher(self : Hashing) -> &Hasher {
  self.hasher
}

///|
pub fn Hashing::codec(self : Hashing) -> &Codec {
  self.codec
}

///|
pub fn Hashing::hash_bytes(self : Hashing, bytes : Bytes) -> Digest {
  self.hasher.hash_bytes(bytes)
}

///|
/// Digest of a JSON document under this encoding.
pub fn Hashing::hash_json(self : Hashing, value : Json) -> String {
  self.hasher.hash_bytes(self.codec.encode(value)).0
}

///|
/// Digest of any `ToJson` value under this encoding.
pub fn[T : ToJson] Hashing::hash_value(self : Hashing, value : T) -> String {
  self.hash_json(value.to_json())
}

///|
/// Encode a value with this hashing context's codec.
pub fn[T : ToJson] Hashing::encode(self : Hashing, value : T) -> Bytes {
  encode_value(self.codec, value)
}

///|
/// Decode a value with this hashing context's codec.
pub fn[T : @json.FromJson] Hashing::decode(
  self : Hashing,
  bytes : BytesView,
) -> T raise CodecError {
  decode_value(self.codec, bytes)
}

///|
/// Hash of a JSON document. Free-function spelling of `Hashing::hash_json`.
pub fn hash_json(hashing : Hashing, value : Json) -> String {
  hashing.hash_json(value)
}

///|
/// Hash of any `ToJson` value. Free-function spelling of
/// `Hashing::hash_value`.
pub fn[T : ToJson] hash_value(hashing : Hashing, value : T) -> String {
  hashing.hash_value(value)
}
