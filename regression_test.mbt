// Regression tests for bugs found by the property tests.

///|
test "regression: re-applying an overlapping update after an offset split" {
  // Found by "property: diff_update gives exactly what a peer is missing".
  // Integrating a struct with offset > 0 used to cache the client clock as
  // old_start + new_length, so the next struct looked causally missing and
  // was parked as pending forever.
  let d0 = @ymoon.Doc(client_id=1)
  let d1 = @ymoon.Doc(client_id=2)
  let t = d0.get_text("t")
  t.insert(0, "中")
  d1.apply_update(d0.encode_state_as_update(target=d1.state_vector()))
  t.insert(1, "😀")
  t.insert(0, "a")
  let b = @ymoon.Doc(client_id=8)
  b.apply_update(d1.encode_state_as_update())
  b.apply_update(d0.encode_state_as_update())
  inspect(b.get_text("t").to_string(), content="a中😀")
  assert_false(b.has_pending())
}

///|
test "documented yjs behaviour: splitting a surrogate pair yields U+FFFD" {
  // Same result as yjs@13.6.33 (ContentString.splice, yjs issue #248).
  let a = @ymoon.Doc(client_id=1)
  let t = a.get_text("t")
  t.insert(0, "😀")
  let b = @ymoon.Doc(client_id=2)
  b.apply_update(a.encode_state_as_update())
  // insert in the middle of the pair on a remote peer
  b.get_text("t").insert(1, "x")
  a.apply_update(b.encode_state_as_update())
  inspect(a.get_text("t").to_string(), content="\u{FFFD}x\u{FFFD}")
}
