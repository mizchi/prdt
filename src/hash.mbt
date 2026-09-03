///|
/// SHA-256 hasher backed by `mizchi/experimental_crypto/hash`.
///
/// The dependency is experimental and unaudited; this package assumes hash
/// collision resistance and does not prove it.
pub struct Sha256Hasher {}

///|
pub fn Sha256Hasher::new() -> Sha256Hasher {
  Sha256Hasher::{  }
}

///|
pub impl Hasher for Sha256Hasher with fn hash_string(self, value) {
  ignore(self)
  Digest(bytes_to_lower_hex(@hash.sha256(@utf8.encode(value[:]))))
}

///|
pub fn bytes_to_lower_hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let output = StringBuilder::new()
  for byte in bytes {
    let value = byte.to_int()
    output.write_char(
      digits.code_unit_at((value >> 4) & 0x0F).to_int().unsafe_to_char(),
    )
    output.write_char(
      digits.code_unit_at(value & 0x0F).to_int().unsafe_to_char(),
    )
  }
  output.to_string()
}

///|
fn hex_nibble(code : UInt16) -> Int? {
  let value = code.to_int()
  if value >= '0'.to_int() && value <= '9'.to_int() {
    Some(value - '0'.to_int())
  } else if value >= 'a'.to_int() && value <= 'f'.to_int() {
    Some(value - 'a'.to_int() + 10)
  } else {
    None
  }
}

///|
pub fn bytes_from_lower_hex(value : String) -> Bytes? {
  if value.length() % 2 != 0 {
    return None
  }
  let output = FixedArray::make(value.length() / 2, b'\x00')
  for index in 0..<output.length() {
    let high = match hex_nibble(value[index * 2]) {
      Some(nibble) => nibble
      None => return None
    }
    let low = match hex_nibble(value[index * 2 + 1]) {
      Some(nibble) => nibble
      None => return None
    }
    output[index] = ((high << 4) | low).to_byte()
  }
  Some(Bytes::from_array(output))
}
