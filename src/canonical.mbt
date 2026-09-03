///|
/// Canonical JSON: object keys sorted recursively, arrays kept in order.
///
/// Every hash in this package is computed over `canonicalize(json)` so that
/// all replicas hash the same logical value to the same digest regardless of
/// key insertion order or Map iteration order.
pub fn canonical_json(value : Json) -> Json {
  match value {
    Object(fields) => {
      let keys = fields.keys().to_array()
      keys.sort()
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
pub fn canonicalize(value : Json) -> String {
  canonical_json(value).stringify()
}

///|
/// Hash of the canonical encoding of a JSON value.
pub fn hash_json(hasher : &Hasher, value : Json) -> String {
  hasher.hash_string(canonicalize(value)).0
}

///|
/// Hash of any `ToJson` value through its canonical encoding.
pub fn[T : ToJson] hash_value(hasher : &Hasher, value : T) -> String {
  hash_json(hasher, value.to_json())
}
