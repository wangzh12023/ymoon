// Fixtures in testdata/ were written by yjs@13.6.33 (JavaScript).

///|
test "argument parsing" {
  let inv = @cli.parse_args(["merge", "a.ybin", "b.ybin", "-o", "out.ybin"])
  inspect(inv.name, content="merge")
  debug_inspect(
    inv.inputs,
    content=(
      #|["a.ybin", "b.ybin"]
    ),
  )
  debug_inspect(
    inv.output,
    content=(
      #|Some("out.ybin")
    ),
  )
}

///|
test "dump a document written by JavaScript yjs" {
  let a = @fs.read_file_to_bytes("testdata/js-notes-a.ybin")
  let b = @fs.read_file_to_bytes("testdata/js-notes-b.ybin")
  let out = @cli.run(@cli.parse_args(["dump", "a", "b"]), [a, b])
  guard out is Text(s) else { fail("expected text") }
  json_inspect(@json.parse(s), content={
    "meta": { "owner": "alice" },
    "notes": "Hello big Yjs from JavaScript",
    "todo": ["ship ymoon"],
  })
}

///|
test "merge and diff are consistent" {
  let a = @fs.read_file_to_bytes("testdata/js-notes-a.ybin")
  let b = @fs.read_file_to_bytes("testdata/js-notes-b.ybin")
  guard @cli.run(@cli.parse_args(["merge", "a", "b", "-o", "x"]), [a, b])
    is Binary(merged) else {
    fail("expected bytes")
  }
  guard @cli.run(@cli.parse_args(["diff", "a", "b", "-o", "x"]), [a, b])
    is Binary(delta) else {
    fail("expected bytes")
  }
  // a + delta reaches the same state as the merged update
  let d1 = @ymoon.Doc(client_id=1)
  d1.apply_update(a)
  d1.apply_update(delta)
  let d2 = @ymoon.Doc(client_id=2)
  d2.apply_update(merged)
  assert_eq(@cli.doc_to_json(d1).stringify(), @cli.doc_to_json(d2).stringify())
  // the delta only carries client 9's edits
  inspect(delta.length() < b.length(), content="true")
}

///|
test "inspect summary" {
  let a = @fs.read_file_to_bytes("testdata/js-notes-a.ybin")
  let s = @cli.inspect_updates([a])
  inspect(
    s.split("\n").take(1).collect()[0],
    content="update #0: 92 bytes, 5 items, 0 gc, 0 skip, 28 clock units, 1 clients, 0 deleted units in 0 ranges",
  )
}
