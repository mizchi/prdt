///|
/// Compact deterministic binary encoding of the `Json` document model.
///
/// Same data model as JSON, a fraction of the bytes: tags instead of
/// punctuation, integers as varints instead of decimal text, strings with a
/// length prefix instead of escaping. Nothing is schema-dependent, so it
/// decodes back to exactly the document that was encoded and stays a drop-in
/// alternative to `JsonCodec`.
///
/// ```text
/// 0x00                                   null
/// 0x01 / 0x02                            false / true
/// 0x03 <zigzag varint>                   integral number
/// 0x04 <8 bytes, big-endian IEEE-754>    any other number
/// 0x05 <varint byte length> <utf-8>      string
/// 0x06 <varint count> <value>*           array
/// 0x07 <varint count> (<key> <value>)*   object, keys in code-unit order
/// 0x08 <varint byte length> <raw bytes>  lowercase-hex string
/// ```
///
/// The last tag is what makes this worth having. Digests, signatures, and
/// state hashes dominate every message, and they are lowercase hex: 64
/// characters carrying 32 bytes. Tag `0x08` stores those bytes directly and
/// rebuilds the same string on the way out, so the document model is
/// unchanged and the encoding stops paying twice for every hash.
///
/// Canonical by construction: object keys are sorted, and a number takes the
/// integral form whenever it has one, so equal documents encode to equal
/// bytes.
pub struct BinaryCodec {}

///|
pub let binary_codec : &Codec = BinaryCodec::{  }

///|
const TAG_NULL : Byte = 0x00

///|
const TAG_FALSE : Byte = 0x01

///|
const TAG_TRUE : Byte = 0x02

///|
const TAG_INT : Byte = 0x03

///|
const TAG_DOUBLE : Byte = 0x04

///|
const TAG_STRING : Byte = 0x05

///|
const TAG_ARRAY : Byte = 0x06

///|
const TAG_OBJECT : Byte = 0x07

///|
const TAG_HEX : Byte = 0x08

///|
/// Below this length the tag and the length prefix cost more than the hex
/// text saves, so short strings keep the plain form.
const MIN_HEX_LENGTH : Int = 16

///|
/// Largest magnitude a `Double` represents exactly, so the integral form is
/// lossless.
const EXACT_INTEGER_LIMIT : Double = 9007199254740992.0

///|
pub impl Codec for BinaryCodec with fn name(_self) {
  "binary/v1"
}

///|
pub impl Codec for BinaryCodec with fn encode(_self, value) {
  let output = Buffer()
  write_json(output, value)
  output.to_bytes()
}

///|
pub impl Codec for BinaryCodec with fn decode(_self, bytes) {
  let cursor = { bytes, offset: 0 }
  let value = read_json(cursor)
  if cursor.offset != bytes.length() {
    raise MalformedEncoding("binary: trailing bytes")
  }
  value
}

///|
fn write_json(output : Buffer, value : Json) -> Unit {
  match value {
    Null => output.write_byte(TAG_NULL)
    False => output.write_byte(TAG_FALSE)
    True => output.write_byte(TAG_TRUE)
    Number(number, ..) => write_number(output, number)
    String(text) =>
      match hex_bytes(text) {
        Some(raw) => {
          output.write_byte(TAG_HEX)
          write_varint(output, raw.length().to_uint64())
          output.write_bytes(raw[:])
        }
        None => {
          output.write_byte(TAG_STRING)
          write_text(output, text)
        }
      }
    Array(items) => {
      output.write_byte(TAG_ARRAY)
      write_varint(output, items.length().to_uint64())
      for item in items {
        write_json(output, item)
      }
    }
    Object(fields) => {
      output.write_byte(TAG_OBJECT)
      let keys = fields.keys().to_array()
      keys.sort_by(compare_code_units)
      write_varint(output, keys.length().to_uint64())
      for key in keys {
        write_text(output, key)
        write_json(output, fields.get(key).unwrap())
      }
    }
  }
}

///|
fn write_number(output : Buffer, number : Double) -> Unit {
  if is_exact_integer(number) {
    output.write_byte(TAG_INT)
    write_varint(output, zigzag(number.to_int64()))
  } else {
    output.write_byte(TAG_DOUBLE)
    let bits = number.reinterpret_as_uint64()
    for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
      output.write_byte(((bits >> shift) & 0xFF).to_byte())
    }
  }
}

///|
/// `-0.0` and non-finite values are excluded: they have no integral form that
/// survives the round trip.
fn is_exact_integer(number : Double) -> Bool {
  if number != number || number.abs() > EXACT_INTEGER_LIMIT {
    return false
  }
  if number == 0.0 && number.reinterpret_as_uint64() != 0UL {
    return false
  }
  number.to_int64().to_double() == number
}

///|
fn write_text(output : Buffer, text : String) -> Unit {
  let encoded = @utf8.encode(text[:])
  write_varint(output, encoded.length().to_uint64())
  output.write_bytes(encoded[:])
}

///|
fn write_varint(output : Buffer, value : UInt64) -> Unit {
  let mut rest = value
  while rest >= 0x80UL {
    output.write_byte(((rest & 0x7F) | 0x80).to_byte())
    rest = rest >> 7
  }
  output.write_byte(rest.to_byte())
}

///|
fn zigzag(value : Int64) -> UInt64 {
  ((value << 1) ^ (value >> 63)).reinterpret_as_uint64()
}

///|
fn unzigzag(value : UInt64) -> Int64 {
  (value >> 1).reinterpret_as_int64() ^ -(value & 1UL).reinterpret_as_int64()
}

///|
priv struct Cursor {
  bytes : BytesView
  mut offset : Int
}

///|
fn Cursor::next(self : Cursor) -> Byte raise CodecError {
  if self.offset >= self.bytes.length() {
    raise MalformedEncoding("binary: unexpected end of input")
  }
  let byte = self.bytes[self.offset]
  self.offset += 1
  byte
}

///|
fn read_json(cursor : Cursor) -> Json raise CodecError {
  match cursor.next() {
    TAG_NULL => Json::null()
    TAG_FALSE => Json::boolean(false)
    TAG_TRUE => Json::boolean(true)
    TAG_INT => Json::number(unzigzag(read_varint(cursor)).to_double())
    TAG_DOUBLE => {
      let mut bits = 0UL
      for _ in 0..<8 {
        bits = (bits << 8) | cursor.next().to_uint64()
      }
      Json::number(bits.reinterpret_as_double())
    }
    TAG_STRING => Json::string(read_text(cursor))
    TAG_HEX => {
      let length = read_length(cursor)
      if cursor.offset + length > cursor.bytes.length() {
        raise MalformedEncoding("binary: hex string runs past the end of input")
      }
      let raw = cursor.bytes[cursor.offset:cursor.offset + length]
      cursor.offset += length
      Json::string(bytes_to_lower_hex(Bytes::from_iter(raw.iter())))
    }
    TAG_ARRAY => {
      let count = read_length(cursor)
      let items = []
      for _ in 0..<count {
        items.push(read_json(cursor))
      }
      Json::array(items)
    }
    TAG_OBJECT => {
      let count = read_length(cursor)
      let fields : Map[String, Json] = Map([])
      for _ in 0..<count {
        let key = read_text(cursor)
        fields[key] = read_json(cursor)
      }
      Json::object(fields)
    }
    other => raise MalformedEncoding("binary: unknown tag \{other}")
  }
}

///|
fn read_text(cursor : Cursor) -> String raise CodecError {
  let length = read_length(cursor)
  if cursor.offset + length > cursor.bytes.length() {
    raise MalformedEncoding("binary: string runs past the end of input")
  }
  let slice = cursor.bytes[cursor.offset:cursor.offset + length]
  cursor.offset += length
  @utf8.decode(slice) catch {
    _ => raise MalformedEncoding("binary: string is not valid UTF-8")
  }
}

///|
/// Lengths are bounded by the input itself, so a corrupt varint cannot ask
/// for an allocation the input could never contain.
fn read_length(cursor : Cursor) -> Int raise CodecError {
  let value = read_varint(cursor)
  if value > cursor.bytes.length().to_uint64() {
    raise MalformedEncoding("binary: length exceeds the remaining input")
  }
  value.to_int()
}

///|
fn read_varint(cursor : Cursor) -> UInt64 raise CodecError {
  let mut result = 0UL
  let mut shift = 0
  while true {
    let byte = cursor.next().to_uint64()
    result = result | ((byte & 0x7F) << shift)
    if byte < 0x80 {
      return result
    }
    shift += 7
    if shift >= 64 {
      raise MalformedEncoding("binary: varint is too long")
    }
  }
  result
}

///|
/// Raw bytes behind a lowercase-hex string, or `None` when the string is not
/// one. Deterministic: a given string always takes the same branch, which is
/// what keeps the encoding canonical.
fn hex_bytes(text : String) -> Bytes? {
  if text.length() < MIN_HEX_LENGTH || text.length() % 2 != 0 {
    return None
  }
  bytes_from_lower_hex(text)
}
