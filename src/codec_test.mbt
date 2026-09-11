///|
let codecs : Array[&Codec] = [json_codec, binary_codec]

///|
fn round_trip(codec : &Codec, value : Json) -> Json raise Error {
  codec.decode(codec.encode(value)[:])
}

///|
test "every codec round-trips the whole json document model" {
  let value : Json = {
    "null": Json::null(),
    "true": true,
    "false": false,
    "zero": 0,
    "negative": -42,
    "big": 9007199254740991.0,
    "fraction": 1.5,
    "tiny": -0.125,
    "text": "hp/mp ✅ \"quoted\" \\ escaped\n",
    "empty_text": "",
    "array": [1, [2, [3]], {}],
    "empty_array": [],
    "nested": { "a": { "b": { "c": [true, Json::null()] } } },
  }
  for codec in codecs {
    assert_eq(round_trip(codec, value), value)
  }
}

///|
test "every codec is canonical: equal documents encode to equal bytes" {
  let value : Json = { "b": 1, "a": { "z": [3, 1, 2], "y": true } }
  let reordered : Json = { "a": { "y": true, "z": [3, 1, 2] }, "b": 1 }
  for codec in codecs {
    assert_eq(codec.encode(value), codec.encode(reordered))
    // Arrays keep their order; only object keys are normalized.
    let ascending : Json = [1, 2]
    let descending : Json = [2, 1]
    assert_not_eq(codec.encode(ascending), codec.encode(descending))
  }
}

///|
test "binary encoding is compact and self-describing" {
  let value : Json = {
    "next_tick": 3,
    "decision_hash": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "state_hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  }
  let json_size = json_codec.encode(value).length()
  let binary_size = binary_codec.encode(value).length()
  assert_true(binary_size < json_size)
  // Small integers cost one tag plus one varint byte, against decimal text
  // plus punctuation in JSON.
  let small : Json = 7
  let large : Json = -1000000
  assert_eq(binary_codec.encode(small).length(), 2)
  assert_eq(json_codec.encode(small).length(), 1)
  assert_eq(binary_codec.encode(large).length(), 4)
  assert_eq(json_codec.encode(large).length(), 8)
}

///|
test "codecs report their identity" {
  assert_eq(json_codec.name(), "json")
  assert_eq(binary_codec.name(), "binary/v1")
}

///|
test "every codec refuses malformed input instead of guessing" {
  // Truncated encodings.
  for codec in codecs {
    let encoded = codec.encode({ "a": [1, 2, 3] })
    let truncated = encoded[0:encoded.length() - 1]
    let failure = try {
      let _ = codec.decode(truncated)
      None
    } catch {
      error => Some(error.message())
    }
    assert_true(failure is Some(_))
  }
  // Binary-specific corruption.
  let cases = [
    (b"\x09", "unknown tag"),
    (b"\x00\x00", "trailing bytes"),
    (b"\x05\x02\x61", "past the end"),
    (b"\x05\x01\xff", "not valid UTF-8"),
    (b"\x06\x7f", "exceeds the remaining input"),
  ]
  for entry in cases {
    let failure = try {
      let _ = binary_codec.decode(entry.0[:])
      "decoded"
    } catch {
      error => error.message()
    }
    assert_true(failure.contains(entry.1))
  }
}

///|
test "decode_value reports the path of a mismatched field" {
  for codec in codecs {
    let failure = try {
      let _ : Envelope[String] = decode_value(
        codec,
        codec.encode({
          "id": "x:0",
          "tick": "not a number",
          "submitted_by": "x",
          "local_sequence": 0,
          "command": "noop",
        })[:],
      )
      "decoded"
    } catch {
      error => error.message()
    }
    assert_true(failure.contains("/tick"))
  }
}

///|
test "the binary codec stores hex digests as bytes, not as text" {
  let digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  let value = Json::string(digest)
  // 1 tag + 1 length + 32 bytes, against 64 characters plus quotes.
  assert_eq(binary_codec.encode(value).length(), 34)
  assert_eq(json_codec.encode(value).length(), 66)
  assert_eq(round_trip(binary_codec, value), value)
  // Strings that only look like hex still round-trip exactly.
  for
    text in [
      "",
      "ab",
      "abcdef",
      "0123456789abcdef",
      "0123456789ABCDEF",
      "0123456789abcdeg",
      "0123456789abcde",
      digest + digest,
    ] {
    let as_json = Json::string(text)
    assert_eq(round_trip(binary_codec, as_json), as_json)
  }
  // Uppercase hex is not the compact form, so it cannot be confused with it.
  let upper : Json = "0123456789ABCDEF0123456789ABCDEF"
  let lower : Json = "0123456789abcdef0123456789abcdef"
  assert_not_eq(binary_codec.encode(upper), binary_codec.encode(lower))
  assert_eq(round_trip(binary_codec, upper), upper)
}
