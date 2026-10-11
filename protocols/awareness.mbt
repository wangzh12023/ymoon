// The awareness CRDT (y-protocols/awareness.js): ephemeral per-client state
// such as cursors, selections and user names, propagated next to documents.

///|
/// Clock and last-update time of a client's awareness state.
pub(all) struct MetaClientState {
  clock : Int
  last_updated : UInt64
} derive(Eq, Debug)

///|
/// Clients whose awareness changed, split by kind.
pub(all) struct AwarenessChange {
  added : Array[UInt]
  updated : Array[UInt]
  removed : Array[UInt]
} derive(Eq, Debug)

///|
/// Outdated states are removed after this many milliseconds
/// (`outdatedTimeout`).
pub const OUTDATED_TIMEOUT : UInt64 = 30000

///|
/// Awareness state of all known clients.
///
/// Unlike the JavaScript class this type does not start timers; call
/// `check_outdated` periodically (e.g. every 3 s) from your event loop.
pub struct Awareness {
  /// The local client id (same as the document's).
  client_id : UInt
  priv states : Map[UInt, @lib0.Any]
  priv meta : Map[UInt, MetaClientState]
  priv now : () -> UInt64
  priv change_handlers : Array[(AwarenessChange, String) -> Unit]
  priv update_handlers : Array[(AwarenessChange, String) -> Unit]
}

///|
/// Creates an awareness instance with an empty local state, like
/// `new Awareness(doc)`. `now` returns milliseconds (defaults to the system
/// clock); inject a fake clock for deterministic tests.
pub fn Awareness::Awareness(
  client_id : UInt,
  now? : () -> UInt64 = () => @env.now(),
) -> Awareness {
  let a : Awareness = {
    client_id,
    states: Map([]),
    meta: Map([]),
    now,
    change_handlers: [],
    update_handlers: [],
  }
  a.set_local_state(Some(@lib0.Any::Object(Map([]))))
  a
}

///|
/// Registers a handler for `change` events (state content changed).
pub fn Awareness::on_change(
  self : Awareness,
  f : (AwarenessChange, String) -> Unit,
) -> Unit {
  self.change_handlers.push(f)
}

///|
/// Registers a handler for `update` events (any state renewal, including
/// heartbeats with unchanged content).
pub fn Awareness::on_update(
  self : Awareness,
  f : (AwarenessChange, String) -> Unit,
) -> Unit {
  self.update_handlers.push(f)
}

///|
fn Awareness::emit_change(
  self : Awareness,
  c : AwarenessChange,
  origin : String,
) -> Unit {
  for f in self.change_handlers {
    f(c, origin)
  }
}

///|
fn Awareness::emit_update(
  self : Awareness,
  c : AwarenessChange,
  origin : String,
) -> Unit {
  for f in self.update_handlers {
    f(c, origin)
  }
}

///|
/// The local state, or None when it was removed.
pub fn Awareness::local_state(self : Awareness) -> @lib0.Any? {
  self.states.get(self.client_id)
}

///|
/// All known states by client id.
pub fn Awareness::states(self : Awareness) -> Map[UInt, @lib0.Any] {
  self.states
}

///|
/// Meta information of a client.
pub fn Awareness::meta(self : Awareness, client : UInt) -> MetaClientState? {
  self.meta.get(client)
}

///|
/// Sets (or with None removes) the local state (`setLocalState`).
pub fn Awareness::set_local_state(self : Awareness, state : @lib0.Any?) -> Unit {
  let client_id = self.client_id
  let clock = match self.meta.get(client_id) {
    None => 0
    Some(m) => m.clock + 1
  }
  let prev_state = self.states.get(client_id)
  match state {
    None => self.states.remove(client_id)
    Some(s) => self.states[client_id] = s
  }
  self.meta[client_id] = { clock, last_updated: (self.now)(), }
  let added : Array[UInt] = []
  let updated : Array[UInt] = []
  let filtered_updated : Array[UInt] = []
  let removed : Array[UInt] = []
  match (state, prev_state) {
    (None, _) => removed.push(client_id)
    (Some(_), None) => added.push(client_id)
    (Some(s), Some(p)) => {
      updated.push(client_id)
      if !deep_equal(p, s) {
        filtered_updated.push(client_id)
      }
    }
  }
  if added.length() > 0 || filtered_updated.length() > 0 || removed.length() > 0 {
    self.emit_change({ added, updated: filtered_updated, removed, }, "local")
  }
  self.emit_update({ added, updated, removed, }, "local")
}

///|
/// Sets one field of the local state object (`setLocalStateField`).
pub fn Awareness::set_local_state_field(
  self : Awareness,
  field : String,
  value : @lib0.Any,
) -> Unit {
  match self.local_state() {
    Some(Object(m)) => {
      let next : Map[String, @lib0.Any] = Map([])
      for k, v in m {
        next[k] = v
      }
      next[field] = value
      self.set_local_state(Some(Object(next)))
    }
    _ => ()
  }
}

///|
/// Removes the given clients (`removeAwarenessStates`).
pub fn Awareness::remove_states(
  self : Awareness,
  clients : ArrayView[UInt],
  origin : String,
) -> Unit {
  let removed : Array[UInt] = []
  for client in clients {
    if self.states.contains(client) {
      self.states.remove(client)
      if client == self.client_id {
        let cur = self.meta.get(client).unwrap()
        self.meta[client] = {
          clock: cur.clock + 1,
          last_updated: (self.now)(),
        }
      }
      removed.push(client)
    }
  }
  if removed.length() > 0 {
    let c = { added: [], updated: [], removed, }
    self.emit_change(c, origin)
    self.emit_update(c, origin)
  }
}

///|
/// Renews the local state if it is getting old and removes remote states that
/// have not been renewed within `OUTDATED_TIMEOUT` (the interval callback of
/// the JavaScript implementation).
pub fn Awareness::check_outdated(self : Awareness) -> Unit {
  let now = (self.now)()
  match (self.local_state(), self.meta.get(self.client_id)) {
    (Some(s), Some(m)) if OUTDATED_TIMEOUT / 2 <= now - m.last_updated =>
      self.set_local_state(Some(s))
    _ => ()
  }
  let remove : Array[UInt] = []
  for client, m in self.meta {
    if client != self.client_id &&
      OUTDATED_TIMEOUT <= now - m.last_updated &&
      self.states.contains(client) {
      remove.push(client)
    }
  }
  if remove.length() > 0 {
    self.remove_states(remove, "timeout")
  }
}

///|
/// Encodes the states of `clients` (`encodeAwarenessUpdate`).
pub fn Awareness::encode_update(
  self : Awareness,
  clients : ArrayView[UInt],
) -> Bytes {
  let enc = @lib0.Encoder()
  enc.write_var_uint(clients.length())
  for client in clients {
    let state = self.states.get(client).unwrap_or(Null)
    let clock = match self.meta.get(client) {
      Some(m) => m.clock
      None => 0
    }
    enc.write_var_uint64(client.to_uint64())
    enc.write_var_uint(clock)
    enc.write_var_string(state.to_json_string())
  }
  enc.to_bytes()
}

///|
/// Applies a remote awareness update (`applyAwarenessUpdate`).
pub fn Awareness::apply_update(
  self : Awareness,
  update : BytesView,
  origin : String,
) -> Unit raise @lib0.DecodeError {
  let dec = @lib0.Decoder(update)
  let timestamp = (self.now)()
  let added : Array[UInt] = []
  let updated : Array[UInt] = []
  let filtered_updated : Array[UInt] = []
  let removed : Array[UInt] = []
  let len = dec.read_var_uint()
  for _ in 0..<len {
    let pos = dec.pos()
    let client = dec.read_var_uint64()
    guard client <= 0xffffffffUL else { raise IntegerOutOfRange(pos~) }
    let client = client.to_uint()
    let mut clock = dec.read_var_uint()
    let state_pos = dec.pos()
    let state_text = dec.read_var_string()
    let state = @lib0.parse_json(state_text) catch {
      _ => raise Malformed(pos=state_pos, reason="awareness state is not JSON")
    }
    let client_meta = self.meta.get(client)
    let prev_state = self.states.get(client)
    let curr_clock = match client_meta {
      None => 0
      Some(m) => m.clock
    }
    if curr_clock < clock ||
      (curr_clock == clock && state is Null && self.states.contains(client)) {
      if state is Null {
        // never let a remote peer delete our own state
        if client == self.client_id && self.local_state() is Some(_) {
          clock += 1
        } else {
          self.states.remove(client)
        }
      } else {
        self.states[client] = state
      }
      self.meta[client] = { clock, last_updated: timestamp, }
      if client_meta is None && !(state is Null) {
        added.push(client)
      } else if client_meta is Some(_) && state is Null {
        removed.push(client)
      } else if !(state is Null) {
        match prev_state {
          Some(p) if deep_equal(state, p) => ()
          _ => filtered_updated.push(client)
        }
        updated.push(client)
      }
    }
  }
  if added.length() > 0 || filtered_updated.length() > 0 || removed.length() > 0 {
    self.emit_change({ added, updated: filtered_updated, removed, }, origin)
  }
  if added.length() > 0 || updated.length() > 0 || removed.length() > 0 {
    self.emit_update({ added, updated, removed, }, origin)
  }
}

///|
/// Rewrites every state of an encoded awareness update
/// (`modifyAwarenessUpdate`).
pub fn modify_awareness_update(
  update : BytesView,
  modify : (@lib0.Any) -> @lib0.Any,
) -> Bytes raise @lib0.DecodeError {
  let dec = @lib0.Decoder(update)
  let enc = @lib0.Encoder()
  let len = dec.read_var_uint()
  enc.write_var_uint(len)
  for _ in 0..<len {
    let client = dec.read_var_uint64()
    let clock = dec.read_var_uint()
    let pos = dec.pos()
    let state = @lib0.parse_json(dec.read_var_string()) catch {
      _ => raise Malformed(pos~, reason="awareness state is not JSON")
    }
    enc.write_var_uint64(client)
    enc.write_var_uint(clock)
    enc.write_var_string(modify(state).to_json_string())
  }
  enc.to_bytes()
}

///|
/// Deep structural equality (`f.equalityDeep`).
fn deep_equal(a : @lib0.Any, b : @lib0.Any) -> Bool {
  match (a, b) {
    (Object(x), Object(y)) => {
      if x.length() != y.length() {
        return false
      }
      for k, v in x {
        match y.get(k) {
          Some(w) => if !deep_equal(v, w) { return false }
          None => return false
        }
      }
      true
    }
    (Array(x), Array(y)) => {
      if x.length() != y.length() {
        return false
      }
      for i in 0..<x.length() {
        if !deep_equal(x[i], y[i]) {
          return false
        }
      }
      true
    }
    _ => a == b
  }
}
