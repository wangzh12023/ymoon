// Item integration (the YATA algorithm), splitting, merging, deletion and
// garbage collection. Line-by-line port of yjs/src/structs/Item.js.

///|
/// Splits `left` at `diff`, returning the new right half (`splitItem`).
fn split_item(txn : Transaction, left : Item, diff : Int) -> Item {
  let client = left.id.client
  let clock = left.id.clock
  let (lc, rc) = left.content.split(diff)
  let right = Item::new_item(
    { client, clock: clock + diff, },
    Some(left),
    Some({ client, clock: clock + diff - 1, }),
    left.right,
    left.right_origin,
    left.parent,
    left.parent_sub,
    rc,
  )
  left.content = lc
  if left.deleted() {
    right.mark_deleted()
  }
  if left.keep() {
    right.info = right.info | INFO_KEEP
  }
  match left.redone {
    Some(r) => right.redone = Some({ client: r.client, clock: r.clock + diff, })
    None => ()
  }
  // update left (do not set left.right_origin, it would break syncing)
  left.right = Some(right)
  match right.right {
    Some(rr) => rr.left = Some(right)
    None => ()
  }
  txn.merge_structs.push(right)
  // the right half is now the most recent value of a map slot
  match (right.parent_sub, right.right, right.parent) {
    (Some(key), None, Branch(b)) => b.map[key] = right
    _ => ()
  }
  left.len = diff
  right
}

///|
/// Returns the client of a missing dependency, or resolves `left`, `right` and
/// `parent` when all dependencies are present (`getMissing`).
fn Item::get_missing(
  self : Item,
  txn : Transaction,
  store : StructStore,
) -> UInt? {
  match self.origin {
    Some(o) if o.client != self.id.client &&
      o.clock >= store.get_state(o.client) => return Some(o.client)
    _ => ()
  }
  match self.right_origin {
    Some(o) if o.client != self.id.client &&
      o.clock >= store.get_state(o.client) => return Some(o.client)
    _ => ()
  }
  match self.parent {
    PendingId(p) if self.id.client != p.client &&
      p.clock >= store.get_state(p.client) => return Some(p.client)
    _ => ()
  }
  // All dependencies are known; resolve neighbours.
  let mut left_is_gc = false
  let mut right_is_gc = false
  match self.origin {
    Some(o) => {
      let l = store.get_item_clean_end(txn, o)
      match l {
        Item(li) => {
          self.left = Some(li)
          self.origin = Some(li.last_id())
        }
        GC(g) | Skip(g) => {
          left_is_gc = true
          self.left = None
          self.origin = Some({
            client: g.id.client,
            clock: g.id.clock + g.len - 1,
          })
        }
      }
    }
    None => ()
  }
  match self.right_origin {
    Some(ro) => {
      let r = store.get_item_clean_start(txn, ro)
      match r {
        Item(ri) => {
          self.right = Some(ri)
          self.right_origin = Some(ri.id)
        }
        GC(g) | Skip(g) => {
          right_is_gc = true
          self.right = None
          self.right_origin = Some(g.id)
        }
      }
    }
    None => ()
  }
  if left_is_gc || right_is_gc {
    self.parent = Gone
  } else {
    match self.parent {
      Unknown =>
        match self.left {
          Some(l) => {
            self.parent = l.parent
            self.parent_sub = l.parent_sub
          }
          None =>
            match self.right {
              Some(r) => {
                self.parent = r.parent
                self.parent_sub = r.parent_sub
              }
              None => ()
            }
        }
      PendingId(pid) =>
        match store.find(pid) {
          Item(pi) =>
            match pi.content {
              Type(b) => self.parent = Branch(b)
              _ => self.parent = Gone
            }
          _ => self.parent = Gone
        }
      _ => ()
    }
  }
  None
}

///|
/// Integrates the item into the document (`Item.integrate`).
fn Item::integrate(self : Item, txn : Transaction, offset : Int) -> Unit {
  let store = txn.doc.store
  if offset > 0 {
    self.id = { client: self.id.client, clock: self.id.clock + offset, }
    let l = store.get_item_clean_end(txn, {
      client: self.id.client,
      clock: self.id.clock - 1,
    })
    match l {
      Item(li) => {
        self.left = Some(li)
        self.origin = Some(li.last_id())
      }
      GC(g) | Skip(g) => {
        self.left = None
        self.origin = Some({
          client: g.id.client,
          clock: g.id.clock + g.len - 1,
        })
      }
    }
    let (_, rc) = self.content.split(offset)
    self.content = rc
    self.len -= offset
  }
  let parent = match self.parent {
    Branch(b) => Some(b)
    _ => None
  }
  match parent {
    None => {
      // parent is not defined: integrate a GC struct instead
      let g : GCRange = { id: self.id, len: self.len, }
      store.add_struct(GC(g))
      return
    }
    Some(parent) => {
      let needs_conflict_resolution = match self.left {
        None =>
          match self.right {
            None => true
            Some(r) => r.left is Some(_)
          }
        Some(l) => !item_opt_same(l.right, self.right)
      }
      if needs_conflict_resolution {
        let mut left = self.left
        // o = first conflicting item
        let mut o : Item? = match left {
          Some(l) => l.right
          None =>
            match self.parent_sub {
              Some(key) => {
                let mut cur = parent.map.get(key)
                while cur is Some(c) && c.left is Some(cl) {
                  cur = Some(cl)
                }
                cur
              }
              None => parent.start
            }
        }
        // identity sets keyed by item ID (items are unique per ID here)
        let conflicting : @hashset.HashSet[ID] = @hashset.HashSet([])
        let before_origin : @hashset.HashSet[ID] = @hashset.HashSet([])
        while o is Some(oi) && !item_opt_same(Some(oi), self.right) {
          before_origin.add(oi.id)
          conflicting.add(oi.id)
          if id_opt_eq(self.origin, oi.origin) {
            // case 1
            if oi.id.client < self.id.client {
              left = Some(oi)
              conflicting.clear()
            } else if id_opt_eq(self.right_origin, oi.right_origin) {
              // this and o point to the same integration points; the id
              // decides which comes first and this is to the left of o
              break
            }
          } else if oi.origin is Some(oo) &&
            before_origin.contains(store.find(oo).id()) {
            // case 2
            if !conflicting.contains(store.find(oo).id()) {
              left = Some(oi)
              conflicting.clear()
            }
          } else {
            break
          }
          o = oi.right
        }
        self.left = left
      }
      // reconnect left/right and update parent map/start
      match self.left {
        Some(l) => {
          self.right = l.right
          l.right = Some(self)
        }
        None => {
          let r = match self.parent_sub {
            Some(key) => {
              let mut cur = parent.map.get(key)
              while cur is Some(c) && c.left is Some(cl) {
                cur = Some(cl)
              }
              cur
            }
            None => {
              let s = parent.start
              parent.start = Some(self)
              s
            }
          }
          self.right = r
        }
      }
      match self.right {
        Some(r) => r.left = Some(self)
        None =>
          match self.parent_sub {
            Some(key) => {
              // this is the current value of the map slot
              parent.map[key] = self
              match self.left {
                Some(l) => l.delete(txn)
                None => ()
              }
            }
            None => ()
          }
      }
      // adjust length of parent
      if self.parent_sub is None && self.countable() && !self.deleted() {
        parent.length += self.len
      }
      store.add_struct(Item(self))
      self.content_integrate(txn)
      txn.add_changed_type(parent, self.parent_sub)
      let parent_deleted = match parent.item {
        Some(pi) => pi.deleted()
        None => false
      }
      if parent_deleted || (self.parent_sub is Some(_) && self.right is Some(_)) {
        // delete if parent is deleted or if this is not the current value
        self.delete(txn)
      }
    }
  }
}

///|
fn item_opt_same(a : Item?, b : Item?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => physical_equal(x, y)
    _ => false
  }
}

///|
/// Content-specific integration hook (`content.integrate`).
fn Item::content_integrate(self : Item, txn : Transaction) -> Unit {
  match self.content {
    Deleted(n) => {
      txn.delete_set.add(self.id.client, self.id.clock, n)
      self.mark_deleted()
    }
    Type(b) => {
      b.doc = Some(txn.doc)
      b.item = Some(self)
    }
    Format(_, _) =>
      match self.parent {
        Branch(b) => {
          b.search_markers = None
          b.has_formatting = true
        }
        _ => ()
      }
    _ => ()
  }
}

///|
/// Marks the item deleted (`Item.delete`).
fn Item::delete(self : Item, txn : Transaction) -> Unit {
  if self.deleted() {
    return
  }
  let parent = self.branch()
  if self.countable() && self.parent_sub is None {
    parent.length -= self.len
  }
  self.mark_deleted()
  txn.delete_set.add(self.id.client, self.id.clock, self.len)
  txn.add_changed_type(parent, self.parent_sub)
  match self.content {
    Type(b) => {
      // delete all children of a deleted shared type
      let mut it = b.start
      while it is Some(child) {
        if !child.deleted() {
          child.delete(txn)
        } else if child.id.clock < txn.before_state.get(child.id.client) {
          txn.merge_structs.push(child)
        }
        it = child.right
      }
      for _, child in b.map {
        if !child.deleted() {
          child.delete(txn)
        } else if child.id.clock < txn.before_state.get(child.id.client) {
          txn.merge_structs.push(child)
        }
      }
      txn.changed.remove(branch_key(b))
    }
    _ => ()
  }
}

///|
/// Garbage-collects a deleted item (`Item.gc`).
fn Item::gc(self : Item, store : StructStore, parent_gcd : Bool) -> Unit {
  guard self.deleted() else { abort("gc of a non-deleted item") }
  match self.content {
    Type(b) => {
      let mut it = b.start
      while it is Some(child) {
        child.gc(store, true)
        it = child.right
      }
      b.start = None
      for _, slot in b.map {
        let mut cur : Item? = Some(slot)
        while cur is Some(c) {
          c.gc(store, true)
          cur = c.left
        }
      }
      b.map.clear()
    }
    _ => ()
  }
  if parent_gcd {
    store.replace_struct(Item(self), GC({ id: self.id, len: self.len, }))
  } else {
    self.content = Deleted(self.len)
  }
}

///|
/// Tries to merge `right` into `self` (`Item.mergeWith`).
fn Item::merge_with(self : Item, right : Item) -> Bool {
  if self.content.ref_number() == right.content.ref_number() &&
    id_opt_eq(right.origin, Some(self.last_id())) &&
    item_opt_same(self.right, Some(right)) &&
    id_opt_eq(self.right_origin, right.right_origin) &&
    self.id.client == right.id.client &&
    self.id.clock + self.len == right.id.clock &&
    self.deleted() == right.deleted() &&
    self.redone is None &&
    right.redone is None {
    match self.content.try_merge(right.content) {
      Some(merged) => {
        self.content = merged
        match self.parent {
          Branch(b) =>
            match b.search_markers {
              Some(ms) =>
                for m in ms {
                  if physical_equal(m.p, right) {
                    // right is going to be "forgotten", move the marker
                    m.p = self
                    if !self.deleted() && self.countable() {
                      m.index -= self.len
                    }
                  }
                }
              None => ()
            }
          _ => ()
        }
        if right.keep() {
          self.info = self.info | INFO_KEEP
        }
        self.right = right.right
        match self.right {
          Some(r) => r.left = Some(self)
          None => ()
        }
        self.len += right.len
        true
      }
      None => false
    }
  } else {
    false
  }
}

///|
/// Previous non-deleted item to the left.
fn Item::prev_visible(self : Item) -> Item? {
  let mut n = self.left
  while n is Some(it) && it.deleted() {
    n = it.left
  }
  n
}
