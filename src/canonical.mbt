///|
/// Canonical JSON: object keys sorted recursively by UTF-16 code units (the
/// JCS / RFC 8785 order, which is also what JavaScript's default string
/// comparison gives), arrays kept in order.
///
/// Every hash in this package is computed over `canonicalize(json)` so that
/// all replicas hash the same logical value to the same digest regardless of
/// key insertion order or Map iteration order. MoonBit's own `String`
/// ordering compares lengths first, so it is not used here.
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
/// Hash of the canonical encoding of a JSON value.
pub fn hash_json(hasher : &Hasher, value : Json) -> String {
  hasher.hash_string(canonicalize(value)).0
}

///|
/// Hash of any `ToJson` value through its canonical encoding.
pub fn[T : ToJson] hash_value(hasher : &Hasher, value : T) -> String {
  hash_json(hasher, value.to_json())
}
