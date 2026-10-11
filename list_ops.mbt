// List and map operations shared by all types, mirroring the type* helpers of
// yjs/src/types/AbstractType.js (including the search-marker index cache,
// which changes how items are split and therefore must match Yjs to produce
// byte-identical updates).

///|
const MAX_SEARCH_MARKER : Int = 80

///|
/// A cached (item, index) position used to speed up index lookups
/// (`ArraySearchMarker`). Markers influence which neighbours an insertion
/// sees, so they are ported exactly to keep updates byte-identical with Yjs.
struct SearchMarker {
  mut p : Item
  mut index : Int
  mut timestamp : Int
}

///|
/// Global marker clock (`globalSearchMarkerTimestamp`).
let marker_clock : Ref[Int] = Ref(0)

///|
fn next_timestamp() -> Int {
  let t = marker_clock.val
  marker_clock.val = t + 1
  t
}

///|
fn Branch::markers(self : Branch) -> Array[SearchMarker]? {
  self.search_markers
}

///|
/// Drops all markers of a branch (`_searchMarker.length = 0`).
fn Branch::clear_markers(self : Branch) -> Unit {
  match self.search_markers {
    Some(ms) => ms.clear()
    None => ()
  }
}

///|
fn set_marked(item : Item, flag : Bool) -> Unit {
  if flag {
    item.info = item.info | INFO_MARKER
  } else {
    item.info = item.info & INFO_MARKER.lnot()
  }
}

///|
fn is_marked(item : Item) -> Bool {
  (item.info & INFO_MARKER) != 0
}

///|
fn overwrite_marker(marker : SearchMarker, p : Item, index : Int) -> Unit {
  set_marked(marker.p, false)
  marker.p = p
  set_marked(p, true)
  marker.index = index
  marker.timestamp = next_timestamp()
}

///|
fn mark_position(
  search_marker : Array[SearchMarker],
  p : Item,
  index : Int,
) -> SearchMarker {
  if search_marker.length() >= MAX_SEARCH_MARKER {
    // override the oldest marker (reduce keeps the later one on ties)
    let mut oldest = search_marker[0]
    for i in 1..<search_marker.length() {
      let m = search_marker[i]
      if !(oldest.timestamp < m.timestamp) {
        oldest = m
      }
    }
    overwrite_marker(oldest, p, index)
    oldest
  } else {
    set_marked(p, true)
    let pm = { p, index, timestamp: next_timestamp(), }
    search_marker.push(pm)
    pm
  }
}

///|
/// Finds (or creates) a search marker close to `index` (`findMarker`).
fn find_marker(parent : Branch, index : Int) -> SearchMarker? {
  guard parent.start is Some(start) && index != 0 else { return None }
  guard parent.markers() is Some(search_marker) else { return None }
  let marker = if search_marker.length() == 0 {
    None
  } else {
    let mut best = search_marker[0]
    for i in 1..<search_marker.length() {
      let m = search_marker[i]
      if !((index - best.index).abs() < (index - m.index).abs()) {
        best = m
      }
    }
    Some(best)
  }
  let mut p = start
  let mut pindex = 0
  match marker {
    Some(m) => {
      p = m.p
      pindex = m.index
      m.timestamp = next_timestamp()
    }
    None => ()
  }
  // iterate to right if possible
  while p.right is Some(r) && pindex < index {
    if !p.deleted() && p.countable() {
      if index < pindex + p.len {
        break
      }
      pindex += p.len
    }
    p = r
  }
  // iterate to left if necessary
  while p.left is Some(l) && pindex > index {
    p = l
    if !p.deleted() && p.countable() {
      pindex -= p.len
    }
  }
  // make sure p can't be merged with left: otherwise the marker could be lost
  while p.left is Some(l) &&
        l.id.client == p.id.client &&
        l.id.clock + l.len == p.id.clock {
    p = l
    if !p.deleted() && p.countable() {
      pindex -= p.len
    }
  }
  match marker {
    Some(m) if (m.index - pindex).abs().to_double() <
      parent.length.to_double() / MAX_SEARCH_MARKER.to_double() => {
      // adjust the existing marker
      overwrite_marker(m, p, pindex)
      Some(m)
    }
    _ => Some(mark_position(search_marker, p, pindex))
  }
}

///|
/// Updates markers after an insertion (`len > 0`) or deletion (`len < 0`)
/// at `index` (`updateMarkerChanges`).
fn update_marker_changes(
  search_marker : Array[SearchMarker],
  index : Int,
  len : Int,
) -> Unit {
  let mut i = search_marker.length() - 1
  while i >= 0 {
    let m = search_marker[i]
    if len > 0 {
      // a simple index <= m.index check would actually suffice
      let mut p : Item? = Some(m.p)
      set_marked(m.p, false)
      // ideally the marker points to an undeleted countable item
      while p is Some(pi) && (pi.deleted() || !pi.countable()) {
        p = pi.left
        match p {
          Some(np) if !np.deleted() && np.countable() =>
            // adjust index for the left item
            m.index -= np.len
          _ => ()
        }
      }
      match p {
        None => {
          search_marker.remove(i) |> ignore
          i -= 1
          continue
        }
        Some(np) =>
          if is_marked(np) {
            // remove the duplicate marker
            search_marker.remove(i) |> ignore
            i -= 1
            continue
          } else {
            m.p = np
            set_marked(np, true)
          }
      }
    }
    if index < m.index || (len > 0 && index == m.index) {
      m.index = @cmp.maximum(index, m.index + len)
    }
    i -= 1
  }
}

///|
/// Inserts `content` after `reference` (`typeListInsertGenericsAfter`).
/// Consecutive plain values are packed into a single `Any` item.
fn type_list_insert_after(
  txn : Transaction,
  parent : Branch,
  reference : Item?,
  content : ArrayView[Value],
) -> Unit {
  let doc = txn.doc
  let own_client = doc.client_id
  let store = doc.store
  let mut left = reference
  let right = match reference {
    None => parent.start
    Some(r) => r.right
  }
  let json_content : Array[@lib0.Any] = []
  fn pack_json() -> Unit {
    if json_content.length() > 0 {
      let item = Item::new_item(
        { client: own_client, clock: store.get_state(own_client), },
        left,
        left.map(l => l.last_id()),
        right,
        right.map(r => r.id),
        Branch(parent),
        None,
        Any(json_content.copy()),
      )
      item.integrate(txn, 0)
      left = Some(item)
      json_content.clear()
    }
  }

  for c in content {
    match c {
      Any(v) => json_content.push(v)
      _ => {
        pack_json()
        let ct : Content = match c {
          Binary(b) => Binary(b)
          Shared(kind) => Type(Branch::new_branch(Some(kind)))
          SubDoc(guid, opts) => Doc(guid, opts)
          Any(_) => abort("unreachable")
        }
        let item = Item::new_item(
          { client: own_client, clock: store.get_state(own_client), },
          left,
          left.map(l => l.last_id()),
          right,
          right.map(r => r.id),
          Branch(parent),
          None,
          ct,
        )
        item.integrate(txn, 0)
        left = Some(item)
      }
    }
  }
  pack_json()
}

///|
/// Errors raised by index based operations on shared types.
pub(all) suberror TypeError {
  /// An index or length exceeds the current length of the type.
  LengthExceeded(index~ : Int, length~ : Int)
} derive(Debug, Eq)

///|
/// Inserts `content` at `index` (`typeListInsertGenerics`).
fn type_list_insert(
  txn : Transaction,
  parent : Branch,
  index : Int,
  content : ArrayView[Value],
) -> Unit raise TypeError {
  if index > parent.length || index < 0 {
    raise LengthExceeded(index~, length=parent.length)
  }
  if index == 0 {
    match parent.markers() {
      Some(ms) => update_marker_changes(ms, index, content.length())
      None => ()
    }
    type_list_insert_after(txn, parent, None, content)
    return
  }
  let start_index = index
  let marker = find_marker(parent, index)
  let mut n = parent.start
  let mut index = index
  match marker {
    Some(m) => {
      n = Some(m.p)
      index -= m.index
      // we need to iterate one to the left so that the algorithm works
      if index == 0 {
        // get the left undeleted item so that we can actually decrease index
        n = m.p.prev_visible()
        index += match n {
          Some(ni) if ni.countable() && !ni.deleted() => ni.len
          _ => 0
        }
      }
    }
    None => ()
  }
  while n is Some(ni) {
    if !ni.deleted() && ni.countable() {
      if index <= ni.len {
        if index < ni.len {
          // insert in-between
          ignore(
            txn.doc.store.get_item_clean_start(txn, {
              client: ni.id.client,
              clock: ni.id.clock + index,
            }),
          )
        }
        break
      }
      index -= ni.len
    }
    n = ni.right
  }
  match parent.markers() {
    Some(ms) => update_marker_changes(ms, start_index, content.length())
    None => ()
  }
  type_list_insert_after(txn, parent, n, content)
}

///|
/// Appends `content` at the end (`typeListPushGenerics`).
fn type_list_push(
  txn : Transaction,
  parent : Branch,
  content : ArrayView[Value],
) -> Unit {
  // use the marker with the highest index and iterate to the right
  let mut n = parent.start
  match parent.markers() {
    Some(ms) => {
      let mut best_index = 0
      for m in ms {
        if m.index > best_index {
          best_index = m.index
          n = Some(m.p)
        }
      }
    }
    None => ()
  }
  match n {
    Some(start) => {
      let mut cur = start
      while cur.right is Some(r) {
        cur = r
      }
      type_list_insert_after(txn, parent, Some(cur), content)
    }
    None => type_list_insert_after(txn, parent, None, content)
  }
}

///|
/// Deletes `length` elements starting at `index` (`typeListDelete`).
fn type_list_delete(
  txn : Transaction,
  parent : Branch,
  index : Int,
  length : Int,
) -> Unit raise TypeError {
  if length == 0 {
    return
  }
  if index < 0 || length < 0 || index + length > parent.length {
    raise LengthExceeded(index~, length=parent.length)
  }
  let start_index = index
  let start_length = length
  let marker = find_marker(parent, index)
  let mut n = parent.start
  let mut index = index
  let mut length = length
  match marker {
    Some(m) => {
      n = Some(m.p)
      index -= m.index
    }
    None => ()
  }
  let store = txn.doc.store
  // compute the first item to be deleted
  while n is Some(ni) && index > 0 {
    if !ni.deleted() && ni.countable() {
      if index < ni.len {
        ignore(
          store.get_item_clean_start(txn, {
            client: ni.id.client,
            clock: ni.id.clock + index,
          }),
        )
      }
      index -= ni.len
    }
    n = ni.right
  }
  // delete all items until done
  while length > 0 && n is Some(ni) {
    if !ni.deleted() {
      if length < ni.len {
        ignore(
          store.get_item_clean_start(txn, {
            client: ni.id.client,
            clock: ni.id.clock + length,
          }),
        )
      }
      ni.delete(txn)
      length -= ni.len
    }
    n = ni.right
  }
  match parent.markers() {
    Some(ms) => update_marker_changes(ms, start_index, -start_length + length)
    None => ()
  }
}

///|
/// Deletes the value at `key` (`typeMapDelete`).
fn type_map_delete(txn : Transaction, parent : Branch, key : String) -> Unit {
  match parent.map.get(key) {
    Some(c) => c.delete(txn)
    None => ()
  }
}

///|
/// Sets `key` to `value` (`typeMapSet`).
fn type_map_set(
  txn : Transaction,
  parent : Branch,
  key : String,
  value : Value,
) -> Item {
  let left = parent.map.get(key)
  let doc = txn.doc
  let own_client = doc.client_id
  let content : Content = match value {
    Any(v) => Any([v])
    Binary(b) => Binary(b)
    Shared(kind) => Type(Branch::new_branch(Some(kind)))
    SubDoc(guid, opts) => Doc(guid, opts)
  }
  let item = Item::new_item(
    { client: own_client, clock: doc.store.get_state(own_client), },
    left,
    left.map(l => l.last_id()),
    None,
    None,
    Branch(parent),
    Some(key),
    content,
  )
  item.integrate(txn, 0)
  item
}

///|
/// Last value of a content run, as an `Out` value.
fn content_last_value(item : Item) -> Out {
  match item.content {
    Any(xs) => Any(xs[xs.length() - 1])
    JSON(xs) => Any(parse_json_any(xs[xs.length() - 1]))
    Binary(b) => Any(Bytes(b))
    String(s) =>
      Any(String(s.unsafe_substring(start=s.length() - 1, end=s.length())))
    Embed(j) => Any(parse_json_any(j))
    Type(b) => Shared(b)
    Doc(guid, _) => SubDoc(guid)
    Deleted(_) | Format(_, _) => Any(Undefined)
  }
}

///|
/// Value of `key` (`typeMapGet`).
fn type_map_get(parent : Branch, key : String) -> Out? {
  match parent.map.get(key) {
    Some(item) if !item.deleted() => Some(content_last_value(item))
    _ => None
  }
}

///|
/// All visible elements of a list type (`typeListToArray`).
fn type_list_to_array(parent : Branch) -> Array[Out] {
  let out : Array[Out] = []
  let mut n = parent.start
  while n is Some(item) {
    if item.countable() && !item.deleted() {
      append_content_values(out, item)
    }
    n = item.right
  }
  out
}

///|
fn append_content_values(out : Array[Out], item : Item) -> Unit {
  match item.content {
    Any(xs) =>
      for x in xs {
        out.push(Any(x))
      }
    JSON(xs) =>
      for x in xs {
        out.push(Any(parse_json_any(x)))
      }
    String(s) =>
      for i in 0..<s.length() {
        out.push(Any(String(s.unsafe_substring(start=i, end=i + 1))))
      }
    Binary(b) => out.push(Any(Bytes(b)))
    Embed(j) => out.push(Any(parse_json_any(j)))
    Type(b) => out.push(Shared(b))
    Doc(guid, _) => out.push(SubDoc(guid))
    Deleted(_) | Format(_, _) => ()
  }
}

///|
/// Element at `index` of a list type (`typeListGet`).
fn type_list_get(parent : Branch, index : Int) -> Out? {
  let marker = find_marker(parent, index)
  let mut n = parent.start
  let mut index = index
  match marker {
    Some(m) => {
      n = Some(m.p)
      index -= m.index
    }
    None => ()
  }
  while n is Some(item) {
    if !item.deleted() && item.countable() {
      if index < item.len {
        let vals : Array[Out] = []
        append_content_values(vals, item)
        return vals.get(index)
      }
      index -= item.len
    }
    n = item.right
  }
  None
}

///|
/// Converts a JSON text (legacy `ContentJSON` / embeds / format values) into
/// an `Any` value.
fn parse_json_any(text : String) -> @lib0.Any {
  if text == "undefined" {
    return Undefined
  }
  let j = @json.parse(text) catch { _ => return String(text) }
  json_to_any(j)
}

///|
/// Converts `Json` to an `Any` value.
pub fn json_to_any(j : Json) -> @lib0.Any {
  match j {
    Null => Null
    True => Bool(true)
    False => Bool(false)
    Number(d, ..) => Number(d)
    String(s) => String(s)
    Array(xs) => Array(xs.map(json_to_any))
    Object(m) => {
      let out : Map[String, @lib0.Any] = Map([])
      for k, v in m {
        out[k] = json_to_any(v)
      }
      Object(out)
    }
  }
}

///|
/// Converts an `Any` value to `Json` (`undefined` becomes null, bytes become an
/// array of numbers, bigints become numbers).
pub fn any_to_json(a : @lib0.Any) -> Json {
  match a {
    Undefined | Null => Json::null()
    Bool(b) => Json::boolean(b)
    Number(d) => Json::number(d)
    BigInt64(n) => Json::number(n.to_double())
    String(s) => Json::string(s)
    Bytes(b) => Json::array(b.to_array().map(x => Json::number(x.to_double())))
    Array(xs) => Json::array(xs.map(any_to_json))
    Object(m) => {
      let out : Map[String, Json] = Map([])
      for k in @lib0.js_object_keys(m) {
        out[k] = any_to_json(m[k])
      }
      Json::object(out)
    }
  }
}

///|
/// Serialises an `Any` value as JSON text exactly like `JSON.stringify`
/// for the subset Yjs uses (format attributes and embeds).
pub fn any_to_json_string(a : @lib0.Any) -> String {
  any_to_json(a).stringify()
}
