// Transactions, mirroring yjs/src/utils/Transaction.js.

///|
/// A batch of changes applied atomically to a document.
pub struct Transaction {
  /// The document this transaction belongs to.
  doc : Doc
  /// Items deleted in this transaction.
  delete_set : DeleteSet
  /// State vector before the transaction.
  before_state : StateVector
  /// State vector after the transaction (set during cleanup).
  mut after_state : StateVector
  /// Changed shared types, keyed by `branch_key`, with the changed map keys
  /// (`None` = the list part changed).
  priv changed : Map[Int32, (Branch, Array[String?])]
  /// Items that may be mergeable with their neighbours after cleanup.
  priv merge_structs : Array[Item]
  /// User supplied origin label.
  origin : String
  /// Whether the change was created locally.
  mut is_local : Bool
  priv mut need_formatting_cleanup : Bool
}

///|
/// Identity of a branch usable as a map key.
fn branch_key(b : Branch) -> Int32 {
  b.uid
}

///|
fn Transaction::new_txn(
  doc : Doc,
  origin : String,
  is_local : Bool,
) -> Transaction {
  {
    doc,
    delete_set: DeleteSet(),
    before_state: doc.store.state_vector(),
    after_state: StateVector(),
    changed: Map([]),
    merge_structs: [],
    origin,
    is_local,
    need_formatting_cleanup: false,
  }
}

///|
/// Records that `t` (and optionally its map key `parent_sub`) changed
/// (`addChangedTypeToTransaction`).
fn Transaction::add_changed_type(
  self : Transaction,
  t : Branch,
  parent_sub : String?,
) -> Unit {
  let record = match t.item {
    None => true
    Some(it) =>
      it.id.clock < self.before_state.get(it.id.client) && !it.deleted()
  }
  if record {
    let key = branch_key(t)
    match self.changed.get(key) {
      Some((_, subs)) =>
        if !subs.iter().any(s => s == parent_sub) {
          subs.push(parent_sub)
        }
      None => self.changed[key] = (t, [parent_sub])
    }
  }
}

///|
/// Shared types changed by this transaction, with the changed map keys
/// (`None` stands for the list / text part).
pub fn Transaction::changed_types(
  self : Transaction,
) -> Array[(Branch, Array[String?])] {
  self.changed.values().collect()
}

///|
/// Runs `f` inside a transaction (`transact`). Nested calls reuse the
/// running transaction.
pub fn[T] Doc::transact(
  self : Doc,
  f : (Transaction) -> T raise?,
  origin~ : String = "",
  is_local~ : Bool = true,
) -> T raise? {
  match self.transaction {
    Some(t) => f(t)
    None => {
      let txn = Transaction::new_txn(self, origin, is_local)
      self.transaction = Some(txn)
      defer {
        self.transaction = None
        cleanup_transaction(txn)
      }
      f(txn)
    }
  }
}

///|
/// Merges `structs[pos]` into its left neighbours where possible, returning
/// the number of merged structs (`tryToMergeWithLefts`).
fn try_to_merge_with_lefts(structs : Array[Struct], pos : Int32) -> Int32 {
  let mut right = structs[pos]
  let mut i = pos
  while i > 0 {
    let left = structs[i - 1]
    let merged = if left.deleted() == right.deleted() {
      match (left, right) {
        (GC(l), GC(r)) => {
          l.len += r.len
          true
        }
        (Item(l), Item(r)) =>
          if l.merge_with(r) {
            // the merged item replaces right as the current map value
            match (r.parent_sub, r.parent) {
              (Some(key), Branch(b)) =>
                match b.map.get(key) {
                  Some(cur) if physical_equal(cur, r) => b.map[key] = l
                  _ => ()
                }
              _ => ()
            }
            true
          } else {
            false
          }
        _ => false
      }
    } else {
      false
    }
    if !merged {
      break
    }
    right = left
    i -= 1
  }
  let merged = pos - i
  if merged > 0 {
    // remove all merged structs from the array in one shift
    let start = pos + 1 - merged
    ignore(structs.drain(start, start + merged))
  }
  merged
}

///|
/// Garbage-collects deleted items covered by `ds` (`tryGcDeleteSet`).
fn try_gc_delete_set(ds : DeleteSet, store : StructStore) -> Unit {
  for client, delete_items in ds.clients {
    let structs = store.structs_of(client)
    for di = delete_items.length() - 1; di >= 0; di = di - 1 {
      let delete_item = delete_items[di]
      let end_clock = delete_item.clock + delete_item.len
      let mut si = find_index_ss(structs, delete_item.clock)
      while si < structs.length() && structs[si].id().clock < end_clock {
        match structs[si] {
          Item(item) if item.deleted() && !item.keep() => item.gc(store, false)
          _ => ()
        }
        si += 1
      }
    }
  }
}

///|
/// Merges deleted / collected structs covered by `ds` (`tryMergeDeleteSet`).
fn try_merge_delete_set(ds : DeleteSet, store : StructStore) -> Unit {
  for client, delete_items in ds.clients {
    let structs = store.structs_of(client)
    for di = delete_items.length() - 1; di >= 0; di = di - 1 {
      let delete_item = delete_items[di]
      // start with merging the item next to the last deleted item
      let most_right = @cmp.minimum(
        structs.length() - 1,
        1 + find_index_ss(structs, delete_item.clock + delete_item.len - 1),
      )
      let mut si = most_right
      while si > 0 && structs[si].id().clock >= delete_item.clock {
        si -= 1 + try_to_merge_with_lefts(structs, si)
      }
    }
  }
}

///|
/// Finishes a transaction: formatting cleanup, GC, struct merging and update
/// emission (`cleanupTransactions`).
fn cleanup_transaction(txn : Transaction) -> Unit {
  let doc = txn.doc
  let store = doc.store
  let ds = txn.delete_set
  ds.sort_and_merge()
  txn.after_state = store.state_vector()
  // observer phase: remote changes reset the index caches of changed list
  // types and request a formatting cleanup of formatted texts
  // (`AbstractType._callObserver` / `YText._callObserver`)
  for _, entry in txn.changed {
    let (t, _) = entry
    let alive = match t.item {
      None => true
      Some(it) => !it.deleted()
    }
    if alive && !txn.is_local {
      t.clear_markers()
      match t.kind {
        Some(YText) | Some(YXmlText) =>
          if t.has_formatting {
            txn.need_formatting_cleanup = true
          }
        _ => ()
      }
    }
  }
  for f in doc.observers {
    f(txn)
  }
  if txn.need_formatting_cleanup {
    cleanup_ytext_after_transaction(txn)
  }
  // Replace deleted items with tombstones / GC structs.
  if !ds.is_empty() {
    if doc.gc {
      try_gc_delete_set(ds, store)
    }
    try_merge_delete_set(ds, store)
  }
  // on all affected clients, try to merge structs (any client order)
  for client, clock in txn.after_state.clients {
    let before_clock = txn.before_state.get(client)
    if before_clock != clock {
      let structs = store.structs_of(client)
      // iterate from right to left so entries can be removed safely
      let first_change = @cmp.maximum(find_index_ss(structs, before_clock), 1)
      let mut i = structs.length() - 1
      while i >= first_change {
        i -= 1 + try_to_merge_with_lefts(structs, i)
      }
    }
  }
  // try to merge merge_structs
  for i = txn.merge_structs.length() - 1; i >= 0; i = i - 1 {
    let id = txn.merge_structs[i].id
    let structs = store.structs_of(id.client)
    let replaced_pos = find_index_ss(structs, id.clock)
    if replaced_pos + 1 < structs.length() {
      if try_to_merge_with_lefts(structs, replaced_pos + 1) > 1 {
        continue // both are already merged
      }
    }
    if replaced_pos > 0 {
      ignore(try_to_merge_with_lefts(structs, replaced_pos))
    }
  }
  if !txn.is_local &&
    txn.after_state.get(doc.client_id) != txn.before_state.get(doc.client_id) {
    // another peer seems to use our client id
    doc.client_id = random_client_id()
  }
  for f in doc.after_transaction_handlers {
    f(txn)
  }
  if doc.update_handlers.length() > 0 {
    match encode_transaction_update(txn) {
      Some(update) =>
        for f in doc.update_handlers {
          f(update, txn.origin)
        }
      None => ()
    }
  }
}

///|
/// Encodes the changes of a transaction as a v1 update
/// (`writeUpdateMessageFromTransaction`), or None if nothing changed.
fn encode_transaction_update(txn : Transaction) -> Bytes? {
  let mut changed = !txn.delete_set.is_empty()
  if !changed {
    for client, clock in txn.after_state.clients {
      if txn.before_state.get(client) != clock ||
        !txn.before_state.contains(client) {
        changed = true
        break
      }
    }
  }
  if !changed {
    return None
  }
  txn.delete_set.sort_and_merge()
  let enc = @lib0.Encoder()
  write_clients_structs(enc, txn.doc.store, txn.before_state)
  txn.delete_set.write(enc)
  Some(enc.to_bytes())
}
