// Reference vectors produced with y-protocols@1.0.7 (oracle/gen-protocol-vectors.mjs).

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
test "sync handshake between two documents" {
  let a = @ymoon.Doc(client_id=1)
  let b = @ymoon.Doc(client_id=2)
  a.get_text("t").insert(0, "hello from A")
  b.get_text("t").insert(0, "B says hi")
  // A -> B: step 1, B answers with step 2 and sends its own step 1
  let step1_a = @protocols.sync_step1(a)
  let reply = @protocols.handle_sync_message(b, step1_a).unwrap()
  ignore(@protocols.handle_sync_message(a, reply))
  let step1_b = @protocols.sync_step1(b)
  let reply2 = @protocols.handle_sync_message(a, step1_b).unwrap()
  ignore(@protocols.handle_sync_message(b, reply2))
  assert_eq(a.get_text("t").to_string(), b.get_text("t").to_string())
  // same converged order as yjs (client 1 sorts before client 2)
  inspect(a.get_text("t").to_string(), content="hello from AB says hi")
}

///|
test "y-websocket message framing round trip" {
  let doc = @ymoon.Doc(client_id=7)
  doc.get_map("m").set("k", @ymoon.Value::str("v"))
  let msgs : Array[@protocols.Message] = [
    Sync(@protocols.sync_step1(doc)),
    Sync(Update(doc.encode_state_as_update())),
    AwarenessUpdate(b"\x01\x07\x01\x02{}"),
    QueryAwareness,
    AuthPermissionDenied("nope"),
  ]
  for m in msgs {
    let bytes = m.encode()
    assert_eq(@protocols.Message::decode(bytes), m)
  }
  assert_eq(hex(msgs[0].encode()), ws_sync_step1)
}

///|
test "sync messages match y-protocols byte for byte" {
  let doc = @ymoon.Doc(client_id=7)
  doc.get_map("m").set("k", @ymoon.Value::str("v"))
  let empty = @ymoon.Doc(client_id=9)
  assert_eq(
    hex(@protocols.Message::Sync(@protocols.sync_step1(doc)).encode()),
    ws_sync_step1,
  )
  let step2 = @protocols.sync_step2(doc, empty.encode_state_vector())
  assert_eq(hex(@protocols.Message::Sync(step2).encode()), ws_sync_step2)
  let update : @protocols.SyncMessage = Update(doc.encode_state_as_update())
  assert_eq(hex(@protocols.Message::Sync(update).encode()), ws_sync_update)
}

///|
test "awareness updates match y-protocols byte for byte" {
  let a = @protocols.Awareness(7, now=() => 0UL)
  a.set_local_state_field(
    "user",
    @lib0.Any::object([
      ("name", @lib0.Any::str("alice")),
      ("color", @lib0.Any::str("#ff0000")),
    ]),
  )
  a.set_local_state_field(
    "cursor",
    @lib0.Any::object([
      ("anchor", @lib0.Any::int(3)),
      ("head", @lib0.Any::int(5)),
    ]),
  )
  assert_eq(hex(a.encode_update([7])), awareness_update)
  a.set_local_state(None)
  assert_eq(hex(a.encode_update([7])), awareness_removed)
}

///|
test "awareness: local state, remote update, timeout" {
  let now = Ref(1000UL)
  let a = @protocols.Awareness(1, now=() => now.val)
  let b = @protocols.Awareness(2, now=() => now.val)
  let changes : Array[String] = []
  b.on_change((c, origin) => changes.push("\{origin}:\{Repr(c)}"))
  a.set_local_state_field("user", @lib0.Any::str("alice"))
  b.apply_update(a.encode_update([1]), "ws")
  debug_inspect(
    b.states().get(1U),
    content=(
      #|Some(Object({ "user": String("alice") }))
    ),
  )
  // 30 s later without renewal the remote state is dropped
  now.val = now.val + 30000UL
  b.check_outdated()
  debug_inspect(b.states().get(1U), content="None")
  // "ws" added alice, then "timeout" removed her
  inspect(changes.length(), content="2")
}
