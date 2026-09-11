///|
/// Wire and storage encoding.
///
/// The protocol defines the *shape* of everything it transports or persists
/// as a `Json` document (every type derives `ToJson` / `FromJson`), and a
/// `Codec` decides how that document becomes bytes. JSON text is the default,
/// but nothing in the protocol depends on it: a compact binary encoding is a
/// drop-in replacement.
///
/// ```text
/// value --derive(ToJson)--> Json document --Codec--> Bytes
/// ```
///
/// **Canonicality contract.** Every codec must be canonical: two documents
/// that are equal as values must encode to identical bytes, regardless of map
/// iteration order. That is what makes the encoded bytes safe to hash and to
/// sign, so `Hashing` can hash the encoding directly.
pub(open) trait Codec {
  /// Stable identifier, recorded in snapshots so a reader can tell which
  /// encoding produced them.
  fn name(Self) -> String
  fn encode(Self, Json) -> Bytes
  fn decode(Self, BytesView) -> Json raise CodecError
}

///|
pub(all) suberror CodecError {
  MalformedEncoding(String)
}

///|
pub fn CodecError::message(self : CodecError) -> String {
  match self {
    MalformedEncoding(detail) => detail
  }
}

///|
/// Encode any `ToJson` value.
pub fn[T : ToJson] encode_value(codec : &Codec, value : T) -> Bytes {
  codec.encode(value.to_json())
}

///|
/// Decode into any `FromJson` type. Reports the JSON path of the first
/// mismatch, so a wrong field is located, not just refused.
pub fn[T : @json.FromJson] decode_value(
  codec : &Codec,
  bytes : BytesView,
) -> T raise CodecError {
  let document = codec.decode(bytes)
  @json.from_json(document) catch {
    @json.JsonDecodeError((path, message)) =>
      raise MalformedEncoding(message + " at " + path.to_string())
  }
}

///|
/// Canonical JSON text (RFC 8785 key order), encoded as UTF-8.
pub struct JsonCodec {}

///|
pub let json_codec : &Codec = JsonCodec::{  }

///|
pub impl Codec for JsonCodec with fn name(_self) {
  "json"
}

///|
pub impl Codec for JsonCodec with fn encode(_self, value) {
  @utf8.encode(canonicalize(value)[:])
}

///|
pub impl Codec for JsonCodec with fn decode(_self, bytes) {
  let text = @utf8.decode(bytes) catch {
    _ => raise MalformedEncoding("json: not valid UTF-8")
  }
  @json.parse(text) catch {
    _ => raise MalformedEncoding("json: not valid JSON text")
  }
}
