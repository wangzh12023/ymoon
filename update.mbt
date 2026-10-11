// Update (v1) encoding and decoding, mirroring yjs/src/utils/encoding.js and
// the struct writers of yjs/src/structs.

///|
const BIT6 : Int = 0x20

///|
const BIT7 : Int = 0x40

///|
const BIT8 : Int = 0x80

///|
const BITS5 : Int = 0x1f

///|
/// Writes a content payload (`AbstractContent.write`) starting at `offset`.
fn write_content(enc : @lib0.Encoder, content : Content, offset : Int) -> Unit {
  match content {
    CDeleted(n) => enc.write_var_uint(n - offset)
    CJson(xs) => {
      enc.write_var_uint(xs.length() - offset)
      for i in offset..<xs.length() {
        enc.write_var_string(
          if xs[i] is Undefined {
            "undefined"
          } else {
            xs[i].to_json_string()
          },
        )
      }
    }
    CBinary(b) => enc.write_var_bytes(b)
    CString(s) =>
      enc.write_var_string(
        if offset == 0 {
          s
        } else {
          s.unsafe_substring(start=offset, end=s.length())
        },
      )
    CEmbed(v) => enc.write_var_string(v.to_json_string())
    CFormat(key, v) => {
      enc.write_var_string(key)
      enc.write_var_string(v.to_json_string())
    }
    CType(b) => {
      let kind = match b.kind {
        Some(k) => k
        None => YMap
      }
      enc.write_var_uint(kind.ref_number())
      match kind {
        YXmlElement(name) | YXmlHook(name) => enc.write_var_string(name)
        _ => ()
      }
    }
    CAny(xs) => {
      enc.write_var_uint(xs.length() - offset)
      for i in offset..<xs.length() {
        enc.write_any(xs[i])
      }
    }
    CDoc(guid, opts) => {
      enc.write_var_string(guid)
      enc.write_any(opts)
    }
  }
}

///|
/// Reads a content payload for the given info byte (`readItemContent`).
fn read_content(
  dec : @lib0.Decoder,
  info : Int,
) -> Content raise @lib0.DecodeError {
  let pos = dec.pos()
  match info & BITS5 {
    1 => CDeleted(dec.read_var_uint())
    2 => {
      let len = dec.read_var_uint()
      guard len <= dec.length() - dec.pos() else { raise UnexpectedEnd(pos~) }
      let xs : Array[@lib0.Any] = Array(capacity=len)
      for _ in 0..<len {
        let s = dec.read_var_string()
        xs.push(
          if s == "undefined" {
            Undefined
          } else {
            read_json_value(s, pos)
          },
        )
      }
      CJson(xs)
    }
    3 => CBinary(dec.read_var_bytes())
    4 => CString(dec.read_var_string())
    5 => CEmbed(read_json_value(dec.read_var_string(), pos))
    6 => {
      let key = dec.read_var_string()
      let value = read_json_value(dec.read_var_string(), pos)
      CFormat(key, value)
    }
    7 => {
      let type_ref = dec.read_var_uint()
      let kind : TypeRef = match type_ref {
        0 => YArray
        1 => YMap
        2 => YText
        3 => YXmlElement(dec.read_var_string())
        4 => YXmlFragment
        5 => YXmlHook(dec.read_var_string())
        6 => YXmlText
        _ => raise UnknownTag(pos~, tag=type_ref)
      }
      CType(Branch::new_branch(Some(kind)))
    }
    8 => {
      let len = dec.read_var_uint()
      guard len <= dec.length() - dec.pos() else { raise UnexpectedEnd(pos~) }
      let xs : Array[@lib0.Any] = Array(capacity=len)
      for _ in 0..<len {
        xs.push(dec.read_any())
      }
      CAny(xs)
    }
    9 => {
      let guid = dec.read_var_string()
      let opts = dec.read_any()
      CDoc(guid, opts)
    }
    tag => raise UnknownTag(pos~, tag~)
  }
}

///|
/// Parses JSON text found in an update (`JSON.parse` in `readJSON`).
fn read_json_value(
  text : String,
  pos : Int,
) -> @lib0.Any raise @lib0.DecodeError {
  @lib0.parse_json(text) catch {
    _ => raise Malformed(pos~, reason="invalid JSON in content")
  }
}

///|
/// Finds the name under which a root branch is registered (`findRootTypeKey`).
fn find_root_type_key(b : Branch) -> String {
  let doc = b.doc_or_abort()
  for name, root in doc.share {
    if physical_equal(root, b) {
      return name
    }
  }
  abort("root type is not registered in its document")
}

///|
/// Writes an item starting at `offset` (`Item.write`).
fn write_item(enc : @lib0.Encoder, item : Item, offset : Int) -> Unit {
  let origin : ID? = if offset > 0 {
    Some({ client: item.id.client, clock: item.id.clock + offset - 1, })
  } else {
    item.origin
  }
  let right_origin = item.right_origin
  let parent_sub = item.parent_sub
  let info = (item.content.ref_number() & BITS5) |
    (if origin is None { 0 } else { BIT8 }) |
    (if right_origin is None { 0 } else { BIT7 }) |
    (if parent_sub is None { 0 } else { BIT6 })
  enc.write_u8(info)
  match origin {
    Some(o) => write_id(enc, o)
    None => ()
  }
  match right_origin {
    Some(o) => write_id(enc, o)
    None => ()
  }
  if origin is None && right_origin is None {
    match item.parent {
      Branch(b) =>
        match b.item {
          None => {
            // parent is a root type
            enc.write_var_uint(1)
            enc.write_var_string(find_root_type_key(b))
          }
          Some(parent_item) => {
            enc.write_var_uint(0)
            write_id(enc, parent_item.id)
          }
        }
      PendingRoot(name) => {
        enc.write_var_uint(1)
        enc.write_var_string(name)
      }
      PendingId(id) => {
        enc.write_var_uint(0)
        write_id(enc, id)
      }
      Unknown | Gone =>
        abort("cannot encode an item without parent information")
    }
    match parent_sub {
      Some(key) => enc.write_var_string(key)
      None => ()
    }
  }
  write_content(enc, item.content, offset)
}

///|
fn write_id(enc : @lib0.Encoder, id : ID) -> Unit {
  enc.write_var_uint64(id.client.to_uint64())
  enc.write_var_uint(id.clock)
}

///|
fn read_id(dec : @lib0.Decoder) -> ID raise @lib0.DecodeError {
  let client = read_client(dec)
  let clock = dec.read_var_uint()
  { client, clock, }
}

///|
/// Writes one struct starting at `offset`.
fn write_struct(enc : @lib0.Encoder, s : Struct, offset : Int) -> Unit {
  match s {
    GC(g) => {
      enc.write_u8(0)
      enc.write_var_uint(g.len - offset)
    }
    Skip(g) => {
      enc.write_u8(10)
      enc.write_var_uint(g.len - offset)
    }
    Item(item) => write_item(enc, item, offset)
  }
}

///|
/// Writes structs of one client starting at `clock` (`writeStructs`).
fn write_structs(
  enc : @lib0.Encoder,
  structs : Array[Struct],
  client : UInt,
  clock : Int,
) -> Unit {
  // make sure the first id exists
  let clock = @cmp.maximum(clock, structs[0].id().clock)
  let start = find_index_ss(structs, clock)
  enc.write_var_uint(structs.length() - start)
  enc.write_var_uint64(client.to_uint64())
  enc.write_var_uint(clock)
  let first = structs[start]
  write_struct(enc, first, clock - first.id().clock)
  for i in (start + 1)..<structs.length() {
    write_struct(enc, structs[i], 0)
  }
}

///|
/// Writes all structs that `sv` does not know about (`writeClientsStructs`).
fn write_clients_structs(
  enc : @lib0.Encoder,
  store : StructStore,
  sv : StateVector,
) -> Unit {
  let sm : Map[UInt, Int] = Map([])
  for entry in sv.entries() {
    let (client, clock) = entry
    if store.get_state(client) > clock {
      sm[client] = clock
    }
  }
  for client, _ in store.clients {
    if !sv.contains(client) {
      sm[client] = 0
    }
  }
  enc.write_var_uint(sm.length())
  // write items with higher client ids first
  for client in sorted_clients_desc(sm.keys()) {
    write_structs(enc, store.structs_of(client), client, sm[client])
  }
}

///|
/// Encodes the document state as a v1 update (`Y.encodeStateAsUpdate`).
///
/// When `target` is given, only the changes the target state vector is missing
/// are included (delete sets are always complete, like in Yjs).
pub fn Doc::encode_state_as_update(
  self : Doc,
  target? : StateVector = StateVector(),
) -> Bytes {
  let enc = @lib0.Encoder()
  write_clients_structs(enc, self.store, target)
  DeleteSet::from_store(self.store).write(enc)
  let updates = [enc.to_bytes()]
  match self.pending_ds {
    Some(ds) => updates.push(ds)
    None => ()
  }
  match self.pending_structs {
    Some(p) =>
      updates.push(
        diff_update(p.update, target.encode()) catch {
          _ => abort("internal: corrupt pending update")
        },
      )
    None => ()
  }
  if updates.length() > 1 {
    merge_updates(updates) catch {
      _ => abort("internal: corrupt pending update")
    }
  } else {
    updates[0]
  }
}

///|
/// Decoded refs of one client, consumed front to back.
priv struct ClientRefs {
  mut i : Int
  mut refs : Array[Struct]
}

///|
/// Reads all structs of an update (`readClientsStructRefs`).
fn read_clients_struct_refs(
  dec : @lib0.Decoder,
  doc : Doc,
) -> Map[UInt, ClientRefs] raise @lib0.DecodeError {
  let client_refs : Map[UInt, ClientRefs] = Map([])
  let num_of_state_updates = dec.read_var_uint()
  for _ in 0..<num_of_state_updates {
    let number_of_structs = dec.read_var_uint()
    guard number_of_structs <= dec.length() - dec.pos() else {
      raise UnexpectedEnd(pos=dec.pos())
    }
    let refs : Array[Struct] = Array(capacity=number_of_structs)
    let client = read_client(dec)
    let mut clock = dec.read_var_uint()
    client_refs[client] = { i: 0, refs, }
    for _ in 0..<number_of_structs {
      let s = read_struct(dec, client, clock, Some(doc))
      refs.push(s)
      clock += s.len()
    }
  }
  client_refs
}

///|
/// Reads one struct at `(client, clock)`. With `doc` = None parents keep their
/// raw form (used by the document-free update utilities).
fn read_struct(
  dec : @lib0.Decoder,
  client : UInt,
  clock : Int,
  doc : Doc?,
) -> Struct raise @lib0.DecodeError {
  let pos = dec.pos()
  let info = dec.read_u8()
  match info & BITS5 {
    0 => GC({ id: { client, clock, }, len: dec.read_var_uint(), })
    10 => Skip({ id: { client, clock, }, len: dec.read_var_uint(), })
    _ => {
      let cant_copy_parent_info = (info & (BIT7 | BIT8)) == 0
      let origin = if (info & BIT8) == BIT8 { Some(read_id(dec)) } else { None }
      let right_origin = if (info & BIT7) == BIT7 {
        Some(read_id(dec))
      } else {
        None
      }
      let parent : Parent = if cant_copy_parent_info {
        let is_ykey = dec.read_var_uint()
        if is_ykey == 1 {
          let name = dec.read_var_string()
          match doc {
            Some(d) => Branch(d.root_for_decode(name))
            None => PendingRoot(name)
          }
        } else if is_ykey == 0 {
          PendingId(read_id(dec))
        } else {
          raise UnknownTag(pos~, tag=is_ykey)
        }
      } else {
        Unknown
      }
      let parent_sub = if cant_copy_parent_info && (info & BIT6) == BIT6 {
        Some(dec.read_var_string())
      } else {
        None
      }
      let content = read_content(dec, info)
      let item = Item::new_item(
        { client, clock, },
        None,
        origin,
        None,
        right_origin,
        parent,
        parent_sub,
        content,
      )
      if item.len == 0 {
        raise Malformed(pos~, reason="zero-length item")
      }
      Item(item)
    }
  }
}

///|
/// Integrates decoded structs in causal order (`integrateStructs`). Returns the
/// structs that could not be applied yet, encoded as a v1 update.
fn integrate_structs(
  txn : Transaction,
  store : StructStore,
  clients_struct_refs : Map[UInt, ClientRefs],
) -> PendingStructs? {
  let stack : Array[Struct] = []
  // take the higher client ids first
  let mut ids = clients_struct_refs.keys().collect()
  ids.sort()
  if ids.length() == 0 {
    return None
  }
  fn get_next_struct_target() -> ClientRefs? {
    if ids.length() == 0 {
      return None
    }
    let mut target = clients_struct_refs[ids[ids.length() - 1]]
    while target.refs.length() == target.i {
      ids.unsafe_pop() |> ignore
      if ids.length() > 0 {
        target = clients_struct_refs[ids[ids.length() - 1]]
      } else {
        return None
      }
    }
    Some(target)
  }

  let mut cur_target = get_next_struct_target()
  guard cur_target is Some(first_target) else { return None }
  let rest_structs = StructStore::new_store()
  let missing_sv : Map[UInt, Int] = Map([])
  fn update_missing_sv(client : UInt, clock : Int) -> Unit {
    match missing_sv.get(client) {
      Some(m) if m <= clock => ()
      _ => missing_sv[client] = clock
    }
  }

  let mut stack_head = first_target.refs[first_target.i]
  first_target.i += 1
  // cache of client states
  let state : Map[UInt, Int] = Map([])
  fn add_stack_to_rest_ss() -> Unit {
    for item in stack {
      let client = item.id().client
      match clients_struct_refs.get(client) {
        Some(inapplicable) => {
          // decrement because we weren't able to apply previous operation
          inapplicable.i -= 1
          rest_structs.clients[client] = inapplicable.refs[inapplicable.i:].to_owned()
          clients_struct_refs.remove(client)
          inapplicable.i = 0
          inapplicable.refs = []
        }
        None =>
          // item was the last item on clients_struct_refs; add it alone
          rest_structs.clients[client] = [item]
      }
      // remove client to prevent applying the same update again
      ids = ids.filter(c => c != client)
    }
    stack.clear()
  }

  for ;; {
    match stack_head {
      Skip(_) => ()
      _ => {
        let head_id = stack_head.id()
        let local_clock = match state.get(head_id.client) {
          Some(c) => c
          None => {
            let c = store.get_state(head_id.client)
            state[head_id.client] = c
            c
          }
        }
        let offset = local_clock - head_id.clock
        if offset < 0 {
          // update from the same client is missing
          stack.push(stack_head)
          update_missing_sv(head_id.client, head_id.clock - 1)
          add_stack_to_rest_ss()
        } else {
          let missing = match stack_head {
            Item(item) => item.get_missing(txn, store)
            _ => None
          }
          match missing {
            Some(missing_client) => {
              stack.push(stack_head)
              let struct_refs = match clients_struct_refs.get(missing_client) {
                Some(r) => r
                None => { i: 0, refs: [], }
              }
              if struct_refs.refs.length() == struct_refs.i {
                // causally depends on an update that doesn't exist yet
                update_missing_sv(
                  missing_client,
                  store.get_state(missing_client),
                )
                add_stack_to_rest_ss()
              } else {
                stack_head = struct_refs.refs[struct_refs.i]
                struct_refs.i += 1
                continue
              }
            }
            None =>
              if offset == 0 || offset < stack_head.len() {
                // all fine, apply the stack head
                match stack_head {
                  Item(item) => item.integrate(txn, offset)
                  GC(g) => {
                    if offset > 0 {
                      g.id = {
                        client: g.id.client,
                        clock: g.id.clock + offset,
                      }
                      g.len -= offset
                    }
                    store.add_struct(GC(g))
                  }
                  Skip(_) => ()
                }
                state[head_id.client] = head_id.clock + stack_head.len()
              }
          }
        }
      }
    }
    // iterate to next stack head
    if stack.length() > 0 {
      stack_head = stack.unsafe_pop()
    } else {
      match cur_target {
        Some(t) if t.i < t.refs.length() => {
          stack_head = t.refs[t.i]
          t.i += 1
        }
        _ => {
          cur_target = get_next_struct_target()
          match cur_target {
            None => break
            Some(t) => {
              stack_head = t.refs[t.i]
              t.i += 1
            }
          }
        }
      }
    }
  }
  if rest_structs.clients.length() > 0 {
    let enc = @lib0.Encoder()
    write_clients_structs(enc, rest_structs, StateVector())
    // no deletes in the rest
    enc.write_var_uint(0)
    Some({ missing: missing_sv, update: enc.to_bytes(), })
  } else {
    None
  }
}

///|
/// Reads a delete set and applies it (`readAndApplyDeleteSet`). Returns the
/// part that refers to unknown structs, encoded as a v1 update.
fn read_and_apply_delete_set(
  dec : @lib0.Decoder,
  txn : Transaction,
  store : StructStore,
) -> Bytes? raise @lib0.DecodeError {
  let unapplied = DeleteSet()
  let num_clients = dec.read_var_uint()
  for _ in 0..<num_clients {
    let client = read_client(dec)
    let number_of_deletes = dec.read_var_uint()
    let structs = match store.clients.get(client) {
      Some(s) => s
      None => []
    }
    let state = store.get_state(client)
    for _ in 0..<number_of_deletes {
      let clock = dec.read_var_uint()
      let clock_end = clock + dec.read_var_uint()
      if clock < state {
        if state < clock_end {
          unapplied.add(client, state, clock_end - state)
        }
        let mut index = find_index_ss(structs, clock)
        // split the first item if necessary
        match structs[index] {
          Item(item) if !item.deleted() && item.id.clock < clock => {
            let right = split_item(txn, item, clock - item.id.clock)
            structs.insert(index + 1, Item(right))
            index += 1
          }
          _ => ()
        }
        while index < structs.length() {
          let s = structs[index]
          index += 1
          if s.id().clock < clock_end {
            match s {
              Item(item) if !item.deleted() => {
                if clock_end < item.id.clock + item.len {
                  let right = split_item(txn, item, clock_end - item.id.clock)
                  structs.insert(index, Item(right))
                }
                item.delete(txn)
              }
              _ => ()
            }
          } else {
            break
          }
        }
      } else {
        unapplied.add(client, clock, clock_end - clock)
      }
    }
  }
  if unapplied.clients.length() > 0 {
    let enc = @lib0.Encoder()
    enc.write_var_uint(0) // no structs
    unapplied.write(enc)
    Some(enc.to_bytes())
  } else {
    None
  }
}

///|
/// Applies a v1 update to the document (`Y.applyUpdate`).
///
/// Structs whose causal dependencies are missing are kept pending and applied
/// automatically once the missing updates arrive, exactly like Yjs.
pub fn Doc::apply_update(
  self : Doc,
  update : BytesView,
  origin? : String = "",
) -> Unit raise @lib0.DecodeError {
  let mut retry : Bytes? = None
  self.transact(
    txn => {
      txn.is_local = false
      let store = self.store
      let dec = @lib0.Decoder(update)
      let ss = read_clients_struct_refs(dec, self)
      let rest_structs = integrate_structs(txn, store, ss)
      match self.pending_structs {
        Some(pending) => {
          // check if we can apply something
          for client, clock in pending.missing {
            if clock < store.get_state(client) {
              retry = Some(pending.update)
              break
            }
          }
          match rest_structs {
            Some(rest) => {
              // merge rest into pending
              for client, clock in rest.missing {
                match pending.missing.get(client) {
                  Some(m) if m <= clock => ()
                  _ => pending.missing[client] = clock
                }
              }
              self.pending_structs = Some({
                missing: pending.missing,
                update: merge_updates([pending.update, rest.update]),
              })
            }
            None => ()
          }
        }
        None => self.pending_structs = rest_structs
      }
      let ds_rest = read_and_apply_delete_set(dec, txn, store)
      match self.pending_ds {
        Some(pending_ds) => {
          let pdec = @lib0.Decoder(pending_ds)
          ignore(pdec.read_var_uint()) // 0 structs
          let ds_rest2 = read_and_apply_delete_set(pdec, txn, store)
          self.pending_ds = match (ds_rest, ds_rest2) {
            (Some(a), Some(b)) => Some(merge_updates([a, b]))
            (Some(a), None) => Some(a)
            (None, b) => b
          }
        }
        None => self.pending_ds = ds_rest
      }
      if retry is Some(_) {
        // pending structs may be applicable now
        let p = self.pending_structs
        self.pending_structs = None
        match p {
          Some(p) => retry = Some(p.update)
          None => retry = None
        }
      }
    },
    origin~,
    is_local=false,
  )
  match retry {
    Some(u) => self.apply_update(u, origin~)
    None => ()
  }
}

///|
/// Whether the document holds structs waiting for missing dependencies.
pub fn Doc::has_pending(self : Doc) -> Bool {
  self.pending_structs is Some(_) || self.pending_ds is Some(_)
}
