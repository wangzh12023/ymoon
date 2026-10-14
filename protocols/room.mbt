// A transport-independent Yjs room server (the logic of y-websocket's
// `setupWSConnection`), usable from any WebSocket implementation: the native
// `moonbitlang/async` server, Node.js via the JS backend, or a test harness.

///|
/// Identifier of a connection inside a room.
pub type ConnId = Int32

///|
/// A shared document plus the awareness of everyone editing it.
pub struct Room {
  /// Room name (usually the document name from the URL).
  name : String
  /// The shared document held by the server.
  doc : @ymoon.Doc
  /// Awareness of all connected clients.
  awareness : Awareness
  /// Open connections and their outgoing message queues.
  priv conns : Map[Int32, Conn]
  /// Awareness client ids announced by each connection.
  priv controlled : Map[Int32, Array[UInt32]]
}

///|
/// An attached connection: messages are delivered through `send`.
priv struct Conn {
  send : (Bytes) -> Unit
}

///|
/// Creates an empty room. The server's own client id never edits content.
pub fn Room::Room(name : String, client_id~ : UInt32 = 0) -> Room {
  let doc = @ymoon.Doc(client_id~)
  let awareness = Awareness(client_id)
  // the server has no presence of its own
  awareness.set_local_state(None)
  let room = { name, doc, awareness, conns: Map([]), controlled: Map([]), }
  // broadcast every document change to all connections
  doc.on_update((update, origin) => {
    let msg = Message::Sync(Update(update)).encode()
    room.broadcast(msg, except=origin)
  })
  // broadcast awareness changes and remember who controls which client id
  awareness.on_update((change, origin) => {
    let changed = [..change.added, ..change.updated, ..change.removed]
    match parse_origin(origin) {
      Some(conn_id) =>
        match room.controlled.get(conn_id) {
          Some(ids) => {
            for id in change.added {
              ids.push(id)
            }
            for id in change.removed {
              match ids.search(id) {
                Some(i) => ids.remove(i) |> ignore
                None => ()
              }
            }
          }
          None => ()
        }
      None => ()
    }
    let msg = Message::AwarenessUpdate(room.awareness.encode_update(changed)).encode()
    room.broadcast(msg)
  })
  room
}

///|
fn origin_of(conn_id : Int32) -> String {
  "conn:\{conn_id}"
}

///|
fn parse_origin(origin : String) -> Int32? {
  guard origin.has_prefix("conn:") else { return None }
  Some(@string.parse_int(origin[5:])) catch {
    _ => None
  }
}

///|
fn Room::broadcast(self : Room, msg : Bytes, except~ : String = "") -> Unit {
  for id, conn in self.conns {
    if origin_of(id) != except {
      (conn.send)(msg)
    }
  }
}

///|
/// Number of open connections.
pub fn Room::connection_count(self : Room) -> Int32 {
  self.conns.length()
}

///|
/// Attaches a connection. Following y-websocket, the server immediately sends
/// sync step 1 and the current awareness states.
pub fn Room::connect(
  self : Room,
  conn_id : Int32,
  send : (Bytes) -> Unit,
) -> Unit {
  self.conns[conn_id] = { send, }
  self.controlled[conn_id] = []
  send(Message::Sync(sync_step1(self.doc)).encode())
  let clients = self.awareness.states().keys().collect()
  if clients.length() > 0 {
    send(
      Message::AwarenessUpdate(self.awareness.encode_update(clients)).encode(),
    )
  }
}

///|
/// Handles one binary message received from `conn_id`.
pub fn Room::receive(
  self : Room,
  conn_id : Int32,
  data : BytesView,
) -> Unit raise @lib0.DecodeError {
  guard self.conns.get(conn_id) is Some(conn) else { return }
  match Message::decode(data) {
    Sync(m) =>
      match handle_sync_message(self.doc, m, origin=origin_of(conn_id)) {
        Some(reply) => (conn.send)(Message::Sync(reply).encode())
        None => ()
      }
    AwarenessUpdate(update) =>
      self.awareness.apply_update(update, origin_of(conn_id))
    QueryAwareness => {
      let clients = self.awareness.states().keys().collect()
      (conn.send)(
        Message::AwarenessUpdate(self.awareness.encode_update(clients)).encode(),
      )
    }
    AuthPermissionDenied(_) => ()
  }
}

///|
/// Detaches a connection and removes the awareness states it controlled.
pub fn Room::disconnect(self : Room, conn_id : Int32) -> Unit {
  let ids = self.controlled.get(conn_id).unwrap_or([])
  self.conns.remove(conn_id)
  self.controlled.remove(conn_id)
  if ids.length() > 0 {
    self.awareness.remove_states(ids, origin_of(conn_id))
  }
}

///|
/// A set of rooms keyed by name, created on demand.
pub struct Hub {
  priv rooms : Map[String, Room]
}

///|
/// Creates an empty hub.
pub fn Hub::Hub() -> Hub {
  { rooms: Map([]), }
}

///|
/// Gets or creates the room `name`.
pub fn Hub::room(self : Hub, name : String) -> Room {
  match self.rooms.get(name) {
    Some(r) => r
    None => {
      let r = Room(name)
      self.rooms[name] = r
      r
    }
  }
}

///|
/// Names of all rooms.
pub fn Hub::room_names(self : Hub) -> Array[String] {
  self.rooms.keys().collect()
}
