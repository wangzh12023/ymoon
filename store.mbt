// Per-client struct storage, mirroring yjs/src/utils/StructStore.js.

///|
/// All structs of a document, grouped by client and sorted by clock.
pub struct StructStore {
  priv clients : Map[UInt32, Array[Struct]]
}

///|
fn StructStore::new_store() -> StructStore {
  { clients: Map([]), }
}

///|
/// Next expected clock for `client` (`getState`).
pub fn StructStore::get_state(self : StructStore, client : UInt32) -> Int32 {
  match self.clients.get(client) {
    None => 0
    Some(structs) => structs[structs.length() - 1].end_clock()
  }
}

///|
/// The state vector of the store (`getStateVector`).
pub fn StructStore::state_vector(self : StructStore) -> StateVector {
  let sv : Map[UInt32, Int32] = Map([])
  for client, structs in self.clients {
    sv[client] = structs[structs.length() - 1].end_clock()
  }
  { clients: sv, }
}

///|
fn StructStore::add_struct(self : StructStore, s : Struct) -> Unit {
  let client = s.id().client
  match self.clients.get(client) {
    None => self.clients[client] = [s]
    Some(structs) => {
      let last = structs[structs.length() - 1]
      guard last.end_clock() == s.id().clock else {
        abort("struct store: non-contiguous struct for client \{client}")
      }
      structs.push(s)
    }
  }
}

///|
/// Binary search for the struct containing `clock` (`findIndexSS`).
fn find_index_ss(structs : Array[Struct], clock : Int32) -> Int32 {
  let mut left = 0
  let mut right = structs.length() - 1
  let last = structs[right]
  let last_id = last.id()
  if last_id.clock == clock {
    return right
  }
  // Pivot guess like Yjs: assume clocks are evenly spread.
  let denom = last_id.clock + last.len() - 1
  let mut mid = if denom > 0 {
    (clock.to_double() / denom.to_double() * right.to_double()).floor().to_int()
  } else {
    0
  }
  while left <= right {
    if mid < left || mid > right {
      mid = (left + right) / 2
    }
    let s = structs[mid]
    let mid_clock = s.id().clock
    if mid_clock <= clock {
      if clock < mid_clock + s.len() {
        return mid
      }
      left = mid + 1
    } else {
      right = mid - 1
    }
    mid = (left + right) / 2
  }
  abort("struct store: clock \{clock} not found")
}

///|
fn StructStore::structs_of(
  self : StructStore,
  client : UInt32,
) -> Array[Struct] {
  match self.clients.get(client) {
    Some(s) => s
    None => abort("struct store: unknown client \{client}")
  }
}

///|
/// Finds the struct that contains `id` (`find` / `getItem`).
fn StructStore::find(self : StructStore, id : ID) -> Struct {
  let structs = self.structs_of(id.client)
  structs[find_index_ss(structs, id.clock)]
}

///|
/// Like `find_index_ss` but splits an item so that a struct starts at `clock`
/// (`findIndexCleanStart`).
fn find_index_clean_start(
  txn : Transaction,
  structs : Array[Struct],
  clock : Int32,
) -> Int32 {
  let index = find_index_ss(structs, clock)
  match structs[index] {
    Item(item) if item.id.clock < clock => {
      let right = split_item(txn, item, clock - item.id.clock)
      structs.insert(index + 1, Item(right))
      index + 1
    }
    _ => index
  }
}

///|
/// Returns the item starting exactly at `id`, splitting if needed
/// (`getItemCleanStart`).
fn StructStore::get_item_clean_start(
  self : StructStore,
  txn : Transaction,
  id : ID,
) -> Struct {
  let structs = self.structs_of(id.client)
  structs[find_index_clean_start(txn, structs, id.clock)]
}

///|
/// Returns the item ending exactly at `id`, splitting if needed
/// (`getItemCleanEnd`).
fn StructStore::get_item_clean_end(
  self : StructStore,
  txn : Transaction,
  id : ID,
) -> Struct {
  let structs = self.structs_of(id.client)
  let index = find_index_ss(structs, id.clock)
  let s = structs[index]
  match s {
    Item(item) if id.clock != item.id.clock + item.len - 1 => {
      let right = split_item(txn, item, id.clock - item.id.clock + 1)
      structs.insert(index + 1, Item(right))
    }
    _ => ()
  }
  s
}

///|
fn StructStore::replace_struct(
  self : StructStore,
  old : Struct,
  new : Struct,
) -> Unit {
  let structs = self.structs_of(old.id().client)
  structs[find_index_ss(structs, old.id().clock)] = new
}

///|
/// Calls `f` on every struct overlapping `[clock_start, clock_start + len)`,
/// splitting items at the range boundaries (`iterateStructs`).
fn iterate_structs(
  txn : Transaction,
  structs : Array[Struct],
  clock_start : Int32,
  len : Int32,
  f : (Struct) -> Unit,
) -> Unit {
  if len == 0 {
    return
  }
  let clock_end = clock_start + len
  let mut index = find_index_clean_start(txn, structs, clock_start)
  for ;; {
    let s = structs[index]
    index += 1
    if clock_end < s.end_clock() {
      ignore(find_index_clean_start(txn, structs, clock_end))
    }
    f(s)
    if !(index < structs.length() && structs[index].id().clock < clock_end) {
      break
    }
  }
}
