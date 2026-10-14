// A small handle-based API exported to JavaScript (compiled with the js
// backend). It powers the browser playground and the Node.js y-websocket
// server in `examples/`. Byte arrays cross the boundary as `Bytes`
// (Uint8Array on the JS side); structured values as JSON text.

///|
let docs : Map[Int, @ymoon.Doc] = Map([])

///|
let rooms : Map[Int, @protocols.Room] = Map([])

///|
let outboxes : Map[Int, Array[(Int, Bytes)]] = Map([])

///|
let update_log : Map[Int, Array[Bytes]] = Map([])

///|
let next_handle : Ref[Int] = Ref(1)

///|
fn fresh_handle() -> Int {
  let h = next_handle.val
  next_handle.val = h + 1
  h
}

///|
fn doc_of(h : Int) -> @ymoon.Doc {
  match docs.get(h) {
    Some(d) => d
    None => abort("unknown document handle \{h}")
  }
}

///|
/// Creates a document and returns its handle. `client_id` < 0 picks a
/// random id.
#export_name("doc_new")
pub fn doc_new(client_id : Int) -> Int {
  let doc = if client_id < 0 {
    @ymoon.Doc()
  } else {
    @ymoon.Doc(client_id=client_id.reinterpret_as_uint())
  }
  let h = fresh_handle()
  docs[h] = doc
  let log : Array[Bytes] = []
  update_log[h] = log
  doc.on_update((u, _) => log.push(u))
  h
}

///|
/// Client id of a document (as a signed 32-bit value).
#export_name("doc_client_id")
pub fn doc_client_id(h : Int) -> Int {
  doc_of(h).client_id().reinterpret_as_int()
}

///|
/// Takes all updates emitted by the document since the last call, merged
/// into a single update (empty bytes if nothing changed).
#export_name("doc_take_updates")
pub fn doc_take_updates(h : Int) -> Bytes {
  let log = update_log.get(h).unwrap()
  if log.length() == 0 {
    return b""
  }
  let merged = if log.length() == 1 {
    log[0]
  } else {
    @ymoon.merge_updates(log) catch {
      _ => log[log.length() - 1]
    }
  }
  log.clear()
  merged
}

///|
/// Applies a v1 update. Returns an empty string or an error message.
#export_name("doc_apply_update")
pub fn doc_apply_update(h : Int, update : Bytes) -> String {
  let doc = doc_of(h)
  // remote updates must not be echoed back as local changes
  let log = update_log.get(h).unwrap()
  let before = log.length()
  doc.apply_update(update, origin="remote") catch {
    e => return "\{e}"
  }
  log.truncate(before)
  ""
}

///|
/// Full state as a v1 update, or the diff for an encoded state vector.
#export_name("doc_encode_state_as_update")
pub fn doc_encode_state_as_update(h : Int, state_vector : Bytes) -> Bytes {
  let doc = doc_of(h)
  if state_vector.length() == 0 {
    doc.encode_state_as_update()
  } else {
    let sv = @ymoon.StateVector::decode(state_vector) catch {
      _ => @ymoon.StateVector()
    }
    doc.encode_state_as_update(target=sv)
  }
}

///|
/// Encoded state vector.
#export_name("doc_encode_state_vector")
pub fn doc_encode_state_vector(h : Int) -> Bytes {
  doc_of(h).encode_state_vector()
}

///|
/// Inserts text into the root text `name`.
#export_name("text_insert")
pub fn text_insert(
  h : Int,
  name : String,
  index : Int,
  text : String,
) -> String {
  doc_of(h).get_text(name).insert(index, text) catch {
    e => return "\{e}"
  }
  ""
}

///|
/// Inserts formatted text; `attrs_json` is a JSON object.
#export_name("text_insert_with")
pub fn text_insert_with(
  h : Int,
  name : String,
  index : Int,
  text : String,
  attrs_json : String,
) -> String {
  let attrs = parse_attrs(attrs_json)
  doc_of(h).get_text(name).insert(index, text, attributes=attrs) catch {
    e => return "\{e}"
  }
  ""
}

///|
/// Deletes text from the root text `name`.
#export_name("text_delete")
pub fn text_delete(h : Int, name : String, index : Int, length : Int) -> String {
  doc_of(h).get_text(name).delete(index, length) catch {
    e => return "\{e}"
  }
  ""
}

///|
/// Applies formatting attributes (`attrs_json`, a JSON object).
#export_name("text_format")
pub fn text_format(
  h : Int,
  name : String,
  index : Int,
  length : Int,
  attrs_json : String,
) -> Unit {
  doc_of(h).get_text(name).format(index, length, parse_attrs(attrs_json))
}

///|
fn parse_attrs(attrs_json : String) -> @ymoon.Attrs {
  let out : @ymoon.Attrs = Map([])
  let parsed = @lib0.parse_json(attrs_json) catch { _ => Null }
  match parsed {
    Object(m) =>
      for k, v in m {
        out[k] = v
      }
    _ => ()
  }
  out
}

///|
/// Plain content of the root text `name`.
#export_name("text_to_string")
pub fn text_to_string(h : Int, name : String) -> String {
  doc_of(h).get_text(name).to_string()
}

///|
/// Rich-text delta of the root text `name` as JSON.
#export_name("text_to_delta")
pub fn text_to_delta(h : Int, name : String) -> String {
  @ymoon.delta_to_json(doc_of(h).get_text(name).to_delta()).stringify()
}

///|
/// Sets `key` of the root map `name` to a JSON value.
#export_name("map_set_json")
pub fn map_set_json(
  h : Int,
  name : String,
  key : String,
  value_json : String,
) -> String {
  let v = @lib0.parse_json(value_json) catch { e => return "\{e}" }
  doc_of(h).get_map(name).set(key, Any(v))
  ""
}

///|
/// Deletes `key` from the root map `name`.
#export_name("map_delete")
pub fn map_delete(h : Int, name : String, key : String) -> Unit {
  doc_of(h).get_map(name).delete(key)
}

///|
/// Pushes JSON values (a JSON array) to the root array `name`.
#export_name("array_push_json")
pub fn array_push_json(h : Int, name : String, values_json : String) -> String {
  let parsed = @lib0.parse_json(values_json) catch { e => return "\{e}" }
  let values = match parsed {
    Array(xs) => xs.map(x => @ymoon.Value::Any(x))
    v => [@ymoon.Value::Any(v)]
  }
  doc_of(h).get_array(name).push(values)
  ""
}

///|
/// Deletes elements of the root array `name`.
#export_name("array_delete")
pub fn array_delete(
  h : Int,
  name : String,
  index : Int,
  length : Int,
) -> String {
  doc_of(h).get_array(name).delete(index, length~) catch {
    e => return "\{e}"
  }
  ""
}

///|
/// JSON view of every root type: `{ name: value }` (like `doc.toJSON()`).
#export_name("doc_to_json")
pub fn doc_to_json(h : Int) -> String {
  let doc = doc_of(h)
  let out : Map[String, Json] = Map([])
  for name in doc.root_names() {
    match doc.root(name) {
      Some(b) => out[name] = b.to_json()
      None => ()
    }
  }
  Json::object(out).stringify()
}

///|
/// Human-readable dump of an update (structs and delete set) as JSON.
#export_name("inspect_update")
pub fn inspect_update(update : Bytes) -> String {
  let (structs, ds) = @ymoon.decode_update(update) catch {
    e => return Json::object({ "error": Json::string("\{e}") }).stringify()
  }
  let items = structs.map(s => {
    match s {
      GC(client~, clock~, len~) =>
        Json::object({
          "kind": Json::string("GC"),
          "client": Json::number(client.to_double()),
          "clock": Json::number(clock.to_double()),
          "len": Json::number(len.to_double()),
        })
      Skip(client~, clock~, len~) =>
        Json::object({
          "kind": Json::string("Skip"),
          "client": Json::number(client.to_double()),
          "clock": Json::number(clock.to_double()),
          "len": Json::number(len.to_double()),
        })
      Item(
        client~,
        clock~,
        len~,
        origin~,
        right_origin~,
        parent~,
        parent_sub~,
        content~
      ) => {
        let o : Map[String, Json] = {
          "kind": Json::string("Item"),
          "client": Json::number(client.to_double()),
          "clock": Json::number(clock.to_double()),
          "len": Json::number(len.to_double()),
          "content": Json::string(content),
        }
        match origin {
          Some(id) => o["origin"] = Json::string("\{id.client}:\{id.clock}")
          None => ()
        }
        match right_origin {
          Some(id) =>
            o["rightOrigin"] = Json::string("\{id.client}:\{id.clock}")
          None => ()
        }
        match parent {
          Some(p) => o["parent"] = Json::string(p)
          None => ()
        }
        match parent_sub {
          Some(p) => o["parentSub"] = Json::string(p)
          None => ()
        }
        Json::object(o)
      }
    }
  })
  let dels : Array[Json] = []
  for client in ds.clients() {
    for r in ds.ranges(client) {
      dels.push(
        Json::object({
          "client": Json::number(client.to_double()),
          "clock": Json::number(r.clock.to_double()),
          "len": Json::number(r.len.to_double()),
        }),
      )
    }
  }
  Json::object({ "structs": Json::array(items), "deleteSet": Json::array(dels) }).stringify()
}

///|
/// Merges a JSON array of hex-encoded updates; returns the hex result.
#export_name("merge_updates")
pub fn merge_updates_bytes(a : Bytes, b : Bytes) -> Bytes {
  @ymoon.merge_updates([a, b]) catch {
    _ => b""
  }
}

///|
/// Creates a server room (y-websocket semantics) and returns its handle.
#export_name("room_new")
pub fn room_new(name : String) -> Int {
  let h = fresh_handle()
  rooms[h] = @protocols.Room(name)
  outboxes[h] = []
  h
}

///|
/// Attaches a connection to a room. Outgoing messages are queued; fetch
/// them with `room_take_outgoing`.
#export_name("room_connect")
pub fn room_connect(room : Int, conn : Int) -> Unit {
  let outbox = outboxes.get(room).unwrap()
  rooms.get(room).unwrap().connect(conn, b => outbox.push((conn, b)))
}

///|
/// Handles a binary message from `conn`. Returns an error message or "".
#export_name("room_receive")
pub fn room_receive(room : Int, conn : Int, data : Bytes) -> String {
  rooms.get(room).unwrap().receive(conn, data) catch {
    e => return "\{e}"
  }
  ""
}

///|
/// Detaches a connection.
#export_name("room_disconnect")
pub fn room_disconnect(room : Int, conn : Int) -> Unit {
  rooms.get(room).unwrap().disconnect(conn)
}

///|
/// Number of queued outgoing messages.
#export_name("room_outgoing_count")
pub fn room_outgoing_count(room : Int) -> Int {
  outboxes.get(room).unwrap().length()
}

///|
/// Connection id of the next queued outgoing message.
#export_name("room_peek_conn")
pub fn room_peek_conn(room : Int) -> Int {
  outboxes.get(room).unwrap()[0].0
}

///|
/// Pops the next queued outgoing message.
#export_name("room_pop_message")
pub fn room_pop_message(room : Int) -> Bytes {
  outboxes.get(room).unwrap().remove(0).1
}

///|
/// Plain text of `name` inside the room's server-side document.
#export_name("room_text")
pub fn room_text(room : Int, name : String) -> String {
  // read through the raw root branch: a relay server never upgrades roots
  // to a concrete type, exactly like the y-websocket server
  match rooms.get(room).unwrap().doc.root(name) {
    Some(b) => @ymoon.TextRef::from_branch(b).to_string()
    None => ""
  }
}

///|
/// A JSON snapshot of the server-side copy of a room, for dashboards:
/// `{ connections, awareness, stateVector, updateBytes, roots, deltas }`.
/// `roots` holds the JSON view of every root type; `deltas` the rich-text
/// delta of roots that hold text. Reading never changes the document.
#export_name("room_snapshot")
pub fn room_snapshot(room : Int) -> String {
  let r = rooms.get(room).unwrap()
  let doc = r.doc
  let roots : Map[String, Json] = Map([])
  let deltas : Map[String, Json] = Map([])
  for name in doc.root_names() {
    match doc.root(name) {
      Some(b) => {
        roots[name] = b.to_json()
        if b.inferred_kind() is Some(YText) {
          deltas[name] = @ymoon.delta_to_json(
            @ymoon.TextRef::from_branch(b).to_delta(),
          )
        }
      }
      None => ()
    }
  }
  let sv = doc
    .state_vector()
    .entries()
    .map(e => {
      Json::array([Json::number(e.0.to_double()), Json::number(e.1.to_double())])
    })
  Json::object({
    "room": Json::string(r.name),
    "connections": Json::number(r.connection_count().to_double()),
    "awareness": Json::number(r.awareness.states().length().to_double()),
    "stateVector": Json::array(sv),
    "updateBytes": Json::number(
      doc.encode_state_as_update().length().to_double(),
    ),
    "roots": Json::object(roots),
    "deltas": Json::object(deltas),
  }).stringify()
}

///|
/// JSON view of the room document.
#export_name("room_to_json")
pub fn room_to_json(room : Int) -> String {
  let doc = rooms.get(room).unwrap().doc
  let out : Map[String, Json] = Map([])
  for name in doc.root_names() {
    match doc.root(name) {
      Some(b) => out[name] = b.to_json()
      None => ()
    }
  }
  Json::object(out).stringify()
}

///|
/// Byte-level annotation of an update as JSON:
/// `[{ "start", "end", "kind", "label" }]`, or `{ "error" }`.
#export_name("annotate_update")
pub fn annotate_update_json(update : Bytes) -> String {
  let segs = @ymoon.annotate_update(update) catch {
    e => return Json::object({ "error": Json::string("\{e}") }).stringify()
  }
  Json::array(
    segs.map(s => {
      Json::object({
        "start": Json::number(s.start.to_double()),
        "end": Json::number(s.end.to_double()),
        "kind": Json::string(s.kind.name()),
        "label": Json::string(s.label),
      })
    }),
  ).stringify()
}

///|
/// Plain text length in UTF-16 code units of the root text `name`.
#export_name("text_length")
pub fn text_length(h : Int, name : String) -> Int {
  doc_of(h).get_text(name).length()
}

///|
/// Applies a plain-text change (as produced by a textarea edit) to the root
/// text `name`: delete `del` units at `index`, then insert `ins` there.
#export_name("text_splice")
pub fn text_splice(
  h : Int,
  name : String,
  index : Int,
  del : Int,
  ins : String,
) -> String {
  let t = doc_of(h).get_text(name)
  doc_of(h).transact(_ => {
    if del > 0 {
      t.delete(index, del)
    }
    if ins.length() > 0 {
      t.insert(index, ins)
    }
  }) catch {
    e => return "\{e}"
  }
  ""
}
