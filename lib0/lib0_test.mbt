///|
fn hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder(size_hint=b.length() * 2)
  for byte in b {
    let v = byte.to_int()
    sb.write_char(digits.get_char(v >> 4).unwrap())
    sb.write_char(digits.get_char(v & 15).unwrap())
  }
  sb.to_string()
}

///|
fn unhex(s : String) -> Bytes {
  let n = s.length() / 2
  Bytes::makei(n, i => {
    let hi = hex_digit(s[2 * i].to_int())
    let lo = hex_digit(s[2 * i + 1].to_int())
    (hi * 16 + lo).to_byte()
  })
}

///|
fn hex_digit(c : Int32) -> Int32 {
  if c >= '0'.to_int() && c <= '9'.to_int() {
    c - '0'.to_int()
  } else {
    c - 'a'.to_int() + 10
  }
}

///|
fn any_same(a : @lib0.Any, b : @lib0.Any) -> Bool {
  // NaN != NaN under Eq, but the round trip must preserve it
  match (a, b) {
    (Number(x), Number(y)) => x == y || (x != x && y != y)
    _ => a == b
  }
}

///|
test "var_uint matches lib0" {
  for v in var_uint_vectors {
    let (n, expected) = v
    let e = @lib0.Encoder()
    e.write_var_uint64(n)
    assert_eq(hex(e.to_bytes()), expected)
    let d = @lib0.Decoder(unhex(expected))
    assert_eq(d.read_var_uint64(), n)
    assert_false(d.has_content())
  }
}

///|
test "var_int matches lib0" {
  for v in var_int_vectors {
    let (n, expected) = v
    let e = @lib0.Encoder()
    e.write_var_int64(n)
    assert_eq(hex(e.to_bytes()), expected)
    let d = @lib0.Decoder(unhex(expected))
    assert_eq(d.read_var_int64(), n)
  }
}

///|
test "var_string matches lib0" {
  for v in var_string_vectors {
    let (s, expected) = v
    let e = @lib0.Encoder()
    e.write_var_string(s)
    assert_eq(hex(e.to_bytes()), expected)
    let d = @lib0.Decoder(unhex(expected))
    assert_eq(d.read_var_string(), s)
  }
}

///|
test "write_any matches lib0" {
  for v in any_vectors {
    let (label, value, expected) = v
    let e = @lib0.Encoder()
    e.write_any(value)
    assert_eq(label + ":" + hex(e.to_bytes()), label + ":" + expected)
    let back = @lib0.Decoder(unhex(expected)).read_any()
    assert_true(any_same(back, value), msg=label)
  }
}

///|
test "lone surrogates are replaced like TextEncoder" {
  let lone = String::from_array([(0xD83D).unsafe_to_char(), 'a'])
  let e = @lib0.Encoder()
  e.write_var_string(lone)
  inspect(hex(e.to_bytes()), content="04efbfbd61")
}

///|
test "decoder rejects truncated input" {
  let d = @lib0.Decoder(unhex("8080"))
  let r : Result[UInt64, @lib0.DecodeError] = Ok(d.read_var_uint64()) catch {
    e => Err(e)
  }
  debug_inspect(r, content="Err(UnexpectedEnd(pos=0))")
}

///|
test "decoder rejects integers beyond 2^53" {
  let d = @lib0.Decoder(unhex("ffffffffffffffff7f"))
  let r : Result[UInt64, @lib0.DecodeError] = Ok(d.read_var_uint64()) catch {
    e => Err(e)
  }
  debug_inspect(r, content="Err(IntegerOutOfRange(pos=0))")
}

///|
test "unknown any tag" {
  let d = @lib0.Decoder(b"\x01")
  let r : Result[@lib0.Any, @lib0.DecodeError] = Ok(d.read_any()) catch {
    e => Err(e)
  }
  debug_inspect(r, content="Err(UnknownTag(pos=0, tag=1))")
}

///|
test "property: var_uint round trips below 2^53" {
  @quickcheck.check((n : UInt64) => {
    let v = n & 0x1FFFFFFFFFFFFFUL
    let e = @lib0.Encoder()
    e.write_var_uint64(v)
    let d = @lib0.Decoder(e.to_bytes())
    (d.read_var_uint64() catch { _ => v + 1UL }) == v
  })
}

///|
test "property: var_int round trips within 53 bits" {
  @quickcheck.check((n : Int64) => {
    let v = n % 0x1FFFFFFFFFFFFFL
    let e = @lib0.Encoder()
    e.write_var_int64(v)
    let d = @lib0.Decoder(e.to_bytes())
    (d.read_var_int64() catch { _ => v + 1L }) == v
  })
}

///|
test "property: strings round trip" {
  @quickcheck.check((s : String) => {
    let e = @lib0.Encoder()
    e.write_var_string(s)
    let d = @lib0.Decoder(e.to_bytes())
    let back = d.read_var_string() catch { _ => "<error>" }
    back == @lib0.utf16_well_formed(s).to_owned()
  })
}

///|
test "js_number_to_string matches V8" {
  for v in number_vectors {
    let (bits, expected) = v
    let d = bits.reinterpret_as_double()
    assert_eq(@lib0.js_number_to_string(d), expected)
  }
}

///|
test "JSON string escaping matches V8" {
  for v in string_vectors {
    let (code_units, expected) = v
    let s = String::from_array(code_units.map(c => c.unsafe_to_char()))
    let sb = StringBuilder()
    @lib0.write_json_string(sb, s)
    assert_eq(sb.to_string(), expected)
  }
}

///|
test "json round trip keeps JS key order" {
  let v = @lib0.parse_json(
    "{\"b\":1,\"10\":2,\"a\":[true,null,\"x\"],\"2\":{}}",
  )
  inspect(
    v.to_json_string(),
    content="{\"2\":{},\"10\":2,\"b\":1,\"a\":[true,null,\"x\"]}",
  )
}
