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
  fn digit(c : Int32) -> Int32 {
    if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else {
      c - 'a'.to_int() + 10
    }
  }

  Bytes::makei(s.length() / 2, i => {
    (digit(s[2 * i].to_int()) * 16 + digit(s[2 * i + 1].to_int())).to_byte()
  })
}

///|
test "text edits produce byte-identical updates to yjs" {
  // reference bytes produced by oracle/smoke.mjs with yjs@13.6.33
  let doc = @ymoon.Doc(client_id=1)
  let ups : Array[String] = []
  doc.on_update((u, _) => ups.push(hex(u)))
  let t = doc.get_text("t")
  t.insert(0, "hello")
  t.insert(5, " world")
  t.delete(0, 1)
  t.format(0, 4, { "bold": @lib0.Any::Bool(true) })
  assert_eq(ups, [
    "01010100040101740568656c6c6f00", "010101058401040620776f726c6400", "000101010001",
    "0102010bc60100010104626f6c640474727565c60104010504626f6c64046e756c6c00",
  ])
  assert_eq(
    hex(doc.encode_state_as_update()),
    "01050100010101740184010004656c6c6f8401040620776f726c64c60100010104626f6c640474727565c60104010504626f6c64046e756c6c0101010001",
  )
  inspect(t.to_string(), content="ello world")
  json_inspect(@ymoon.delta_to_json(t.to_delta()), content=[
    { "insert": "ello", "attributes": { "bold": true } },
    { "insert": " world" },
  ])
}

///|
test "apply yjs update" {
  let doc = @ymoon.Doc(client_id=2)
  doc.apply_update(
    unhex(
      "01050100010101740184010004656c6c6f8401040620776f726c64c60100010104626f6c640474727565c60104010504626f6c64046e756c6c0101010001",
    ),
  )
  let t = doc.get_text("t")
  inspect(t.to_string(), content="ello world")
  json_inspect(@ymoon.delta_to_json(t.to_delta()), content=[
    { "insert": "ello", "attributes": { "bold": true } },
    { "insert": " world" },
  ])
}
