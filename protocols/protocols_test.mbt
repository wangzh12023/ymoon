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

///|
test "room: two clients converge through the server" {
  let hub = @protocols.Hub()
  let room = hub.room("demo")
  // two client documents talking to the room through in-memory queues
  let alice = @ymoon.Doc(client_id=101)
  let bob = @ymoon.Doc(client_id=202)
  let to_alice : Array[Bytes] = []
  let to_bob : Array[Bytes] = []
  room.connect(1, b => to_alice.push(b))
  room.connect(2, b => to_bob.push(b))
  fn pump(doc : @ymoon.Doc, inbox : Array[Bytes], conn : Int) raise {
    while inbox.length() > 0 {
      let msg = inbox.remove(0)
      match @protocols.Message::decode(msg) {
        Sync(m) =>
          match @protocols.handle_sync_message(doc, m) {
            Some(reply) =>
              room.receive(conn, @protocols.Message::Sync(reply).encode())
            None => ()
          }
        _ => ()
      }
    }
  }

  // each client forwards its local updates to the room
  alice.on_update((u, origin) => {
    if origin != "remote" {
      room.receive(1, @protocols.Message::Sync(Update(u)).encode()) catch {
        _ => ()
      }
    }
  })
  bob.on_update((u, origin) => {
    if origin != "remote" {
      room.receive(2, @protocols.Message::Sync(Update(u)).encode()) catch {
        _ => ()
      }
    }
  })
  pump(alice, to_alice, 1)
  pump(bob, to_bob, 2)
  alice.get_text("doc").insert(0, "Hello ")
  bob.get_text("doc").insert(0, "World")
  pump(alice, to_alice, 1)
  pump(bob, to_bob, 2)
  assert_eq(alice.get_text("doc").to_string(), bob.get_text("doc").to_string())
  assert_eq(
    room.doc.get_text("doc").to_string(),
    alice.get_text("doc").to_string(),
  )
  inspect(room.connection_count(), content="2")
  room.disconnect(1)
  inspect(room.connection_count(), content="1")
}
