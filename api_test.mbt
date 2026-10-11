// Behavioural tests of the public API. Expected values follow yjs@13.6.33.

///|
test "Y.Text basics" {
  let doc = @ymoon.Doc(client_id=1)
  let t = doc.get_text("t")
  t.insert(0, "Hello")
  t.insert(5, " MoonBit")
  t.delete(0, 1)
  inspect(t.to_string(), content="ello MoonBit")
  inspect(t.length(), content="12")
}

///|
test "Y.Text rejects out of range edits" {
  let doc = @ymoon.Doc(client_id=1)
  let t = doc.get_text("t")
  t.insert(0, "abc")
  let r : Result[Unit, @ymoon.TypeError] = Ok(t.insert(10, "x")) catch {
    e => Err(e)
  }
  debug_inspect(r, content="Err(LengthExceeded(index=10, length=3))")
  let r2 : Result[Unit, @ymoon.TypeError] = Ok(t.delete(1, 5)) catch {
    e => Err(e)
  }
  debug_inspect(r2, content="Err(LengthExceeded(index=1, length=3))")
}

///|
test "Y.Text rich text delta" {
  let doc = @ymoon.Doc(client_id=1)
  let t = doc.get_text("t")
  t.insert(0, "bold and plain")
  t.format(0, 4, { "bold": Bool(true) })
  t.format(5, 3, { "italic": Bool(true), "color": String("#f00") })
  json_inspect(@ymoon.delta_to_json(t.to_delta()), content=[
    { "insert": "bold", "attributes": { "bold": true } },
    { "insert": " " },
    { "insert": "and", "attributes": { "italic": true, "color": "#f00" } },
    { "insert": " plain" },
  ])
  // removing an attribute with null
  t.format(0, 4, { "bold": Null })
  json_inspect(@ymoon.delta_to_json(t.to_delta()), content=[
    { "insert": "bold " },
    { "insert": "and", "attributes": { "italic": true, "color": "#f00" } },
    { "insert": " plain" },
  ])
}

///|
test "Y.Text apply_delta (Quill style)" {
  let doc = @ymoon.Doc(client_id=1)
  let t = doc.get_text("t")
  t.apply_delta([
    Insert(Text("Gandalf"), attributes={ "bold": Bool(true) }),
    Insert(Text(" the "), attributes=Map([])),
    Insert(Text("Grey"), attributes={ "color": String("#ccc") }),
  ])
  t.apply_delta([Retain(12, attributes=Map([])), Delete(4)])
  t.apply_delta([
    Retain(12, attributes=Map([])),
    Insert(Text("White"), attributes=Map([])),
  ])
  inspect(t.to_string(), content="Gandalf the White")
}

///|
test "Y.Text embeds" {
  let doc = @ymoon.Doc(client_id=1)
  let t = doc.get_text("t")
  t.insert(0, "ab")
  t.insert_embed(1, @lib0.Any::object([("image", @lib0.Any::str("cat.png"))]))
  json_inspect(@ymoon.delta_to_json(t.to_delta()), content=[
    { "insert": "a" },
    { "insert": { "image": "cat.png" } },
    { "insert": "b" },
  ])
  inspect(t.length(), content="3")
}

///|
test "Y.Map semantics" {
  let doc = @ymoon.Doc(client_id=1)
  let m = doc.get_map("m")
  m.set("a", @ymoon.Value::int(1))
  m.set("b", @ymoon.Value::str("two"))
  m.set("a", @ymoon.Value::int(3))
  assert_true(m.has("a"))
  inspect(m.size(), content="2")
  m.delete("b")
  assert_false(m.has("b"))
  json_inspect(m.to_json(), content={ "a": 3 })
  m.clear()
  inspect(m.size(), content="0")
}

///|
test "Y.Map last writer wins by client id" {
  let a = @ymoon.Doc(client_id=1)
  let b = @ymoon.Doc(client_id=2)
  a.get_map("m").set("k", @ymoon.Value::str("from a"))
  b.get_map("m").set("k", @ymoon.Value::str("from b"))
  a.apply_update(b.encode_state_as_update())
  b.apply_update(a.encode_state_as_update())
  // concurrent writes: the higher client id wins, on both sides
  json_inspect(a.get_map("m").to_json(), content={ "k": "from b" })
  json_inspect(b.get_map("m").to_json(), content={ "k": "from b" })
}

///|
test "Y.Array operations" {
  let doc = @ymoon.Doc(client_id=1)
  let arr = doc.get_array("a")
  arr.push([@ymoon.Value::int(1), @ymoon.Value::int(2), @ymoon.Value::int(3)])
  arr.insert(1, [@ymoon.Value::str("x")])
  arr.unshift([@ymoon.Value::bool(true)])
  arr.delete(2, length=2)
  json_inspect(arr.to_json(), content=[true, 1, 3])
  match arr.get(1) {
    Some(Any(Number(n))) => inspect(n, content="1")
    _ => fail("unexpected element")
  }
}

///|
test "nested shared types" {
  let doc = @ymoon.Doc(client_id=1)
  let root = doc.get_map("root")
  let list = @ymoon.ArrayRef::from_branch(root.set_shared("list", YArray))
  list.push([@ymoon.Value::str("item")])
  let text = @ymoon.TextRef::from_branch(root.set_shared("note", YText))
  text.insert(0, "nested text")
  json_inspect(root.to_json(), content={
    "list": ["item"],
    "note": "nested text",
  })
  // nested content survives a round trip through the binary format
  let copy = @ymoon.Doc(client_id=2)
  copy.apply_update(doc.encode_state_as_update())
  json_inspect(copy.get_map("root").to_json(), content={
    "list": ["item"],
    "note": "nested text",
  })
}

///|
test "deleting a nested type deletes its content" {
  let doc = @ymoon.Doc(client_id=1)
  let root = doc.get_map("root")
  let list = @ymoon.ArrayRef::from_branch(root.set_shared("list", YArray))
  list.push([@ymoon.Value::int(1), @ymoon.Value::int(2)])
  root.delete("list")
  json_inspect(root.to_json(), content={})
  inspect(list.length(), content="0")
}

///|
test "XML fragments" {
  let doc = @ymoon.Doc(client_id=1)
  let frag = doc.get_xml_fragment("prosemirror")
  let p = frag.insert_element(0, "paragraph")
  p.set_attribute("align", "left")
  let txt = p.insert_text(0)
  txt.insert(0, "hello")
  txt.format(0, 5, { "strong": Object(Map([])) })
  inspect(
    frag.to_string(),
    content="<paragraph align=\"left\"><strong>hello</strong></paragraph>",
  )
}

///|
test "pending updates are applied once dependencies arrive" {
  let a = @ymoon.Doc(client_id=1)
  let updates : Array[Bytes] = []
  a.on_update((u, _) => updates.push(u))
  let t = a.get_text("t")
  t.insert(0, "a")
  t.insert(1, "b")
  t.insert(2, "c")
  let b = @ymoon.Doc(client_id=2)
  // deliver out of order
  b.apply_update(updates[2])
  b.apply_update(updates[1])
  assert_true(b.has_pending())
  inspect(b.get_text("t").to_string(), content="")
  b.apply_update(updates[0])
  assert_false(b.has_pending())
  inspect(b.get_text("t").to_string(), content="abc")
}

///|
test "state vectors and diffs" {
  let a = @ymoon.Doc(client_id=1)
  a.get_text("t").insert(0, "hello")
  let b = @ymoon.Doc(client_id=2)
  b.apply_update(a.encode_state_as_update())
  a.get_text("t").insert(5, " world")
  let diff = a.encode_state_as_update(target=b.state_vector())
  // only the new insertion travels
  let (structs, _) = @ymoon.decode_update(diff)
  inspect(structs.length(), content="1")
  b.apply_update(diff)
  inspect(b.get_text("t").to_string(), content="hello world")
  let sv = @ymoon.StateVector::decode(a.encode_state_vector())
  inspect(sv.get(1), content="11")
}

///|
test "encode_state_vector_from_update matches the document" {
  let a = @ymoon.Doc(client_id=5)
  a.get_text("t").insert(0, "xyz")
  a.get_map("m").set("k", @ymoon.Value::int(1))
  let u = a.encode_state_as_update()
  assert_eq(@ymoon.encode_state_vector_from_update(u), a.encode_state_vector())
}

///|
test "garbage collection keeps deleted content out of updates" {
  let gc_doc = @ymoon.Doc(client_id=1)
  let keep_doc = @ymoon.Doc(client_id=1, gc=false)
  for d in [gc_doc, keep_doc] {
    let t = d.get_text("t")
    t.insert(0, "a fairly long piece of text that gets deleted")
    t.delete(0, t.length())
  }
  let gc_size = gc_doc.encode_state_as_update().length()
  let keep_size = keep_doc.encode_state_as_update().length()
  assert_true(gc_size < keep_size)
}

///|
test "malformed updates raise instead of crashing" {
  let doc = @ymoon.Doc(client_id=1)
  let bad : Array[Bytes] = [
    b"\x01", b"\x01\x05\x01\x00\x04", b"\xff\xff\xff\xff\xff\xff\xff\xff\xff",
  ]
  for u in bad {
    let r : Result[Unit, @lib0.DecodeError] = Ok(doc.apply_update(u)) catch {
      e => Err(e)
    }
    assert_true(r is Err(_))
  }
}
