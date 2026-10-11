// Y.Text: collaborative rich text. Port of yjs/src/types/YText.js.

///|
/// Formatting attributes: key -> value (as lib0 `Any`); `Null` removes a key.
pub type Attrs = Map[String, @lib0.Any]

///|
/// Value equality used for attributes (`equalAttrs`): identical primitives or
/// shallowly equal plain objects.
fn equal_attrs(a : @lib0.Any, b : @lib0.Any) -> Bool {
  match (a, b) {
    (Object(x), Object(y)) => {
      if x.length() != y.length() {
        return false
      }
      for k, v in x {
        match y.get(k) {
          Some(w) => if !js_strict_equal(v, w) { return false }
          None => return false
        }
      }
      true
    }
    _ => js_strict_equal(a, b)
  }
}

///|
/// JavaScript `===` on decoded values: primitives compare by value; objects,
/// arrays and byte arrays are distinct references (never equal).
fn js_strict_equal(a : @lib0.Any, b : @lib0.Any) -> Bool {
  match (a, b) {
    (Undefined, Undefined) | (Null, Null) => true
    (Bool(x), Bool(y)) => x == y
    (Number(x), Number(y)) => x == y
    (BigInt64(x), BigInt64(y)) => x == y
    (String(x), String(y)) => x == y
    // objects, arrays and byte arrays compare by reference
    (Object(x), Object(y)) => physical_equal(x, y)
    (Array(x), Array(y)) => physical_equal(x, y)
    (Bytes(x), Bytes(y)) => physical_equal(x, y)
    _ => false
  }
}

///|
/// Cursor through the item list of a text (`ItemTextListPosition`).
priv struct TextPos {
  mut left : Item?
  mut right : Item?
  mut index : Int
  current_attributes : Map[String, @lib0.Any]
}

///|
fn TextPos::forward(self : TextPos) -> Unit {
  guard self.right is Some(r) else { abort("unexpected case") }
  match r.content {
    CFormat(key, value) =>
      if !r.deleted() {
        update_current_attributes(self.current_attributes, key, value)
      }
    _ => if !r.deleted() { self.index += r.len }
  }
  self.left = Some(r)
  self.right = r.right
}

///|
fn update_current_attributes(
  attrs : Map[String, @lib0.Any],
  key : String,
  value : @lib0.Any,
) -> Unit {
  if value is Null {
    attrs.remove(key)
  } else {
    attrs[key] = value
  }
}

///|
/// Moves `pos` forward by `count` countable units, splitting items
/// (`findNextPosition`).
fn find_next_position(txn : Transaction, pos : TextPos, count : Int) -> TextPos {
  let mut count = count
  while pos.right is Some(r) && count > 0 {
    match r.content {
      CFormat(key, value) =>
        if !r.deleted() {
          update_current_attributes(pos.current_attributes, key, value)
        }
      _ =>
        if !r.deleted() {
          if count < r.len {
            // split right
            ignore(
              txn.doc.store.get_item_clean_start(txn, {
                client: r.id.client,
                clock: r.id.clock + count,
              }),
            )
          }
          pos.index += r.len
          count -= r.len
        }
    }
    pos.left = pos.right
    pos.right = r.right
    // pos.right may have been split, so read r.right after the split
  }
  pos
}

///|
/// Finds the position for `index` (`findPosition`).
fn find_position(
  txn : Transaction,
  parent : Branch,
  index : Int,
  use_search_marker : Bool,
) -> TextPos {
  let current_attributes : Map[String, @lib0.Any] = Map([])
  let marker = if use_search_marker { find_marker(parent, index) } else { None }
  match marker {
    Some(m) => {
      let pos = {
        left: m.p.left,
        right: Some(m.p),
        index: m.index,
        current_attributes,
      }
      find_next_position(txn, pos, index - m.index)
    }
    None => {
      let pos = {
        left: None,
        right: parent.start,
        index: 0,
        current_attributes,
      }
      find_next_position(txn, pos, index)
    }
  }
}

///|
fn new_local_item(
  txn : Transaction,
  parent : Branch,
  left : Item?,
  right : Item?,
  content : Content,
) -> Item {
  let doc = txn.doc
  let own_client = doc.client_id
  Item::new_item(
    { client: own_client, clock: doc.store.get_state(own_client), },
    left,
    left.map(l => l.last_id()),
    right,
    right.map(r => r.id),
    Branch(parent),
    None,
    content,
  )
}

///|
/// Inserts format items that undo `negated` after an insertion
/// (`insertNegatedAttributes`).
fn insert_negated_attributes(
  txn : Transaction,
  parent : Branch,
  curr : TextPos,
  negated : Map[String, @lib0.Any],
) -> Unit {
  // check if we really need to remove attributes
  while curr.right is Some(r) &&
        (
          r.deleted() ||
          (match r.content {
            CFormat(key, value) =>
              match negated.get(key) {
                Some(nv) => equal_attrs(nv, value)
                None => equal_attrs(Undefined, value)
              }
            _ => false
          })
        ) {
    if !r.deleted() {
      match r.content {
        CFormat(key, _) => negated.remove(key)
        _ => ()
      }
    }
    curr.forward()
  }
  for key, val in negated {
    let left = curr.left
    let right = curr.right
    let next_format = new_local_item(
      txn,
      parent,
      left,
      right,
      CFormat(key, val),
    )
    next_format.integrate(txn, 0)
    curr.right = Some(next_format)
    curr.forward()
  }
}

///|
/// Skips formatting items that already have the requested values
/// (`minimizeAttributeChanges`).
fn minimize_attribute_changes(curr : TextPos, attributes : Attrs) -> Unit {
  for ;; {
    guard curr.right is Some(r) else { break }
    let skip = r.deleted() ||
      (match r.content {
        CFormat(key, value) =>
          equal_attrs(attributes.get(key).unwrap_or(Null), value)
        _ => false
      })
    if !skip {
      break
    }
    curr.forward()
  }
}

///|
/// Inserts format items for `attributes`, returning the negations to apply
/// afterwards (`insertAttributes`).
fn insert_attributes(
  txn : Transaction,
  parent : Branch,
  curr : TextPos,
  attributes : Attrs,
) -> Map[String, @lib0.Any] {
  let negated : Map[String, @lib0.Any] = Map([])
  // insert format-start items
  for key in @lib0.js_object_keys(attributes) {
    let val = attributes[key]
    let current_val = curr.current_attributes.get(key).unwrap_or(Null)
    if !equal_attrs(current_val, val) {
      // save negated attribute (set null if current_val is undefined)
      negated[key] = current_val
      let left = curr.left
      let right = curr.right
      let item = new_local_item(txn, parent, left, right, CFormat(key, val))
      item.integrate(txn, 0)
      curr.right = Some(item)
      curr.forward()
    }
  }
  negated
}

///|
/// What can be inserted into a text.
pub(all) enum TextChunk {
  /// Plain text.
  Text(String)
  /// An embed (stored as JSON).
  Embed(@lib0.Any)
  /// A nested shared type embedded in the text.
  Shared(TypeRef)
}

///|
fn TextChunk::to_content(self : TextChunk) -> Content {
  match self {
    Text(s) => CString(s)
    Embed(v) => CEmbed(v)
    Shared(kind) => CType(Branch::new_branch(Some(kind)))
  }
}

///|
/// Inserts text / an embed with attributes at the cursor (`insertText`).
fn insert_text(
  txn : Transaction,
  parent : Branch,
  curr : TextPos,
  chunk : TextChunk,
  attributes : Attrs,
) -> Unit {
  for key, _ in curr.current_attributes {
    if !attributes.contains(key) {
      attributes[key] = Null
    }
  }
  minimize_attribute_changes(curr, attributes)
  let negated = insert_attributes(txn, parent, curr, attributes)
  let content = chunk.to_content()
  let left = curr.left
  let right = curr.right
  let index = curr.index
  match parent.markers() {
    Some(ms) => update_marker_changes(ms, curr.index, content.len())
    None => ()
  }
  let item = new_local_item(txn, parent, left, right, content)
  item.integrate(txn, 0)
  curr.right = Some(item)
  curr.index = index
  curr.forward()
  insert_negated_attributes(txn, parent, curr, negated)
}

///|
/// Applies `attributes` to `length` units at the cursor (`formatText`).
fn format_text(
  txn : Transaction,
  parent : Branch,
  curr : TextPos,
  length : Int,
  attributes : Attrs,
) -> Unit {
  minimize_attribute_changes(curr, attributes)
  let negated = insert_attributes(txn, parent, curr, attributes)
  let mut length = length
  // iterate until the first non-format or null is found; delete all formats
  // with attributes[format.key] != null
  while curr.right is Some(r) &&
        (
          length > 0 ||
          (negated.length() > 0 && (r.deleted() || r.content is CFormat(_, _)))
        ) {
    if !r.deleted() {
      match r.content {
        CFormat(key, value) => {
          let v = value
          match attributes.get(key) {
            Some(attr) => {
              if equal_attrs(attr, v) {
                negated.remove(key)
              } else {
                if length == 0 {
                  // no need to further extend negated attributes
                  break
                }
                negated[key] = v
              }
              r.delete(txn)
            }
            None => curr.current_attributes[key] = v
          }
        }
        _ => {
          if length < r.len {
            ignore(
              txn.doc.store.get_item_clean_start(txn, {
                client: r.id.client,
                clock: r.id.clock + length,
              }),
            )
          }
          length -= r.len
        }
      }
    }
    curr.forward()
  }
  // quill only: the cursor is at the end of the text, extend with newlines
  if length > 0 {
    let newlines = "\n".repeat(length)
    let item = new_local_item(
      txn,
      parent,
      curr.left,
      curr.right,
      CString(newlines),
    )
    item.integrate(txn, 0)
    curr.right = Some(item)
    curr.forward()
  }
  insert_negated_attributes(txn, parent, curr, negated)
}

///|
/// Removes redundant format items between `start` and the next countable item
/// (`cleanupFormattingGap`).
fn cleanup_formatting_gap(
  txn : Transaction,
  start : Item,
  curr : Item?,
  start_attributes : Map[String, @lib0.Any],
  curr_attributes : Map[String, @lib0.Any],
) -> Int {
  let mut end : Item? = Some(start)
  let end_formats : Map[String, Item] = Map([])
  while end is Some(e) && (!e.countable() || e.deleted()) {
    if !e.deleted() {
      match e.content {
        CFormat(key, _) => end_formats[key] = e
        _ => ()
      }
    }
    end = e.right
  }
  let mut cleanups = 0
  let mut reached_curr = false
  let mut s : Item? = Some(start)
  while !item_opt_same(s, end) {
    guard s is Some(si) else { break }
    if item_opt_same(curr, s) {
      reached_curr = true
    }
    if !si.deleted() {
      match si.content {
        CFormat(key, value_json) => {
          let value = value_json
          let start_attr_value = start_attributes.get(key).unwrap_or(Null)
          let is_end_format = match end_formats.get(key) {
            Some(ef) => physical_equal(ef, si)
            None => false
          }
          if !is_end_format || js_strict_equal(start_attr_value, value) {
            // either this format is overwritten or it is not necessary
            si.delete(txn)
            cleanups += 1
            if !reached_curr &&
              js_strict_equal(curr_attributes.get(key).unwrap_or(Null), value) &&
              !js_strict_equal(start_attr_value, value) {
              if start_attr_value is Null {
                curr_attributes.remove(key)
              } else {
                curr_attributes[key] = start_attr_value
              }
            }
          }
          if !reached_curr && !si.deleted() {
            update_current_attributes(curr_attributes, key, value_json)
          }
        }
        _ => ()
      }
    }
    s = si.right
  }
  cleanups
}

///|
/// Deletes duplicate formats around a deleted item without context
/// (`cleanupContextlessFormattingGap`).
fn cleanup_contextless_formatting_gap(txn : Transaction, item : Item) -> Unit {
  // iterate until item.right is null or content
  let mut it = item
  while it.right is Some(r) && (r.deleted() || !r.countable()) {
    it = r
  }
  let attrs : @hashset.HashSet[String] = @hashset.HashSet([])
  // iterate back until a content item is found
  let mut cur : Item? = Some(it)
  while cur is Some(c) && (c.deleted() || !c.countable()) {
    if !c.deleted() {
      match c.content {
        CFormat(key, _) =>
          if attrs.contains(key) {
            c.delete(txn)
          } else {
            attrs.add(key)
          }
        _ => ()
      }
    }
    cur = c.left
  }
}

///|
/// Removes all redundant formatting of a text (`cleanupYTextFormatting`).
fn cleanup_ytext_formatting(t : Branch) -> Int {
  let mut res = 0
  t
  .doc_or_abort()
  .transact(txn => {
    guard t.start is Some(first) else { return }
    let mut start = first
    let mut end : Item? = t.start
    let mut start_attributes : Map[String, @lib0.Any] = Map([])
    let current_attributes = copy_attrs(start_attributes)
    while end is Some(e) {
      if !e.deleted() {
        match e.content {
          CFormat(key, value) =>
            update_current_attributes(current_attributes, key, value)
          _ => {
            res += cleanup_formatting_gap(
              txn,
              start,
              Some(e),
              start_attributes,
              current_attributes,
            )
            start_attributes = copy_attrs(current_attributes)
            start = e
          }
        }
      }
      end = e.right
    }
  })
  res
}

///|
fn copy_attrs(m : Map[String, @lib0.Any]) -> Map[String, @lib0.Any] {
  let out : Map[String, @lib0.Any] = Map([])
  for k, v in m {
    out[k] = v
  }
  out
}

///|
/// Formatting cleanup after remote changes (`cleanupYTextAfterTransaction`).
fn cleanup_ytext_after_transaction(txn : Transaction) -> Unit {
  let need_full_cleanup : Array[Branch] = []
  fn add_full(b : Branch) -> Unit {
    if !need_full_cleanup.iter().any(x => physical_equal(x, b)) {
      need_full_cleanup.push(b)
    }
  }

  let doc = txn.doc
  // check if another formatting item was inserted
  for entry in txn.after_state.entries() {
    let (client, after_clock) = entry
    let clock = txn.before_state.get(client)
    if after_clock == clock {
      continue
    }
    iterate_structs(txn, doc.store.structs_of(client), clock, after_clock, s => {
      match s {
        Item(item) if !item.deleted() && item.content is CFormat(_, _) =>
          match item.parent {
            Branch(b) => add_full(b)
            _ => ()
          }
        _ => ()
      }
    })
  }
  // cleanup in a new transaction
  doc.transact(t => {
    iterate_deleted_structs(txn, txn.delete_set, s => {
      match s {
        Item(item) =>
          match item.parent {
            Branch(parent) =>
              if parent.has_formatting &&
                !need_full_cleanup.iter().any(x => physical_equal(x, parent)) {
                if item.content is CFormat(_, _) {
                  add_full(parent)
                } else {
                  cleanup_contextless_formatting_gap(t, item)
                }
              }
            _ => ()
          }
        _ => ()
      }
    })
    // if a formatting item was inserted, we simply clean the whole type
    for ytext in need_full_cleanup {
      ignore(cleanup_ytext_formatting(ytext))
    }
  })
}

///|
/// Calls `f` on every struct covered by `ds` (`iterateDeletedStructs`).
fn iterate_deleted_structs(
  txn : Transaction,
  ds : DeleteSet,
  f : (Struct) -> Unit,
) -> Unit {
  for client, deletes in ds.clients {
    match txn.doc.store.clients.get(client) {
      Some(structs) => {
        let last = structs[structs.length() - 1]
        let clock_state = last.end_clock()
        for del in deletes {
          if del.clock >= clock_state {
            break
          }
          iterate_structs(txn, structs, del.clock, del.len, f)
        }
      }
      None => ()
    }
  }
}

///|
/// Deletes `length` units at the cursor (`deleteText`).
fn delete_text(txn : Transaction, curr : TextPos, length : Int) -> TextPos {
  let start_length = length
  let start_attrs = copy_attrs(curr.current_attributes)
  let start = curr.right
  let mut length = length
  while length > 0 && curr.right is Some(r) {
    if !r.deleted() {
      match r.content {
        CType(_) | CEmbed(_) | CString(_) => {
          if length < r.len {
            ignore(
              txn.doc.store.get_item_clean_start(txn, {
                client: r.id.client,
                clock: r.id.clock + length,
              }),
            )
          }
          length -= r.len
          r.delete(txn)
        }
        _ => ()
      }
    }
    curr.forward()
  }
  match start {
    Some(s) =>
      ignore(
        cleanup_formatting_gap(
          txn,
          s,
          curr.right,
          start_attrs,
          curr.current_attributes,
        ),
      )
    None => ()
  }
  let parent = match curr.left {
    Some(l) => l.branch()
    None =>
      match curr.right {
        Some(r) => r.branch()
        None => return curr
      }
  }
  match parent.markers() {
    Some(ms) => update_marker_changes(ms, curr.index, -start_length + length)
    None => ()
  }
  curr
}

///|
/// A delta operation (`{ insert }`, `{ retain }` or `{ delete }`), as used by
/// Quill / ProseMirror bindings.
pub(all) enum Delta {
  /// Insert text or an embed with attributes.
  Insert(TextChunk, attributes~ : Attrs)
  /// Keep `n` units, optionally changing their attributes.
  Retain(Int, attributes~ : Attrs)
  /// Delete `n` units.
  Delete(Int)
}

///|
/// A handle to a Y.Text.
pub struct TextRef {
  branch : Branch
}

///|
/// Gets (or creates) the root Y.Text called `name` (`doc.getText(name)`).
pub fn Doc::get_text(self : Doc, name : String) -> TextRef {
  { branch: self.get_root(name, YText), }
}

///|
/// Wraps a branch known to be a text.
pub fn TextRef::from_branch(b : Branch) -> TextRef {
  { branch: b, }
}

///|
/// The underlying shared-type branch.
pub fn TextRef::branch(self : TextRef) -> Branch {
  self.branch
}

///|
/// Length in UTF-16 code units, like JavaScript string length.
pub fn TextRef::length(self : TextRef) -> Int {
  self.branch.length
}

///|
/// The plain text content (`toString`).
pub fn TextRef::to_string(self : TextRef) -> String {
  self.branch.text_to_string()
}

///|
fn Branch::text_to_string(self : Branch) -> String {
  let sb = StringBuilder()
  let mut n = self.start
  while n is Some(item) {
    if !item.deleted() && item.countable() {
      match item.content {
        CString(s) => sb.write_string(s)
        _ => ()
      }
    }
    n = item.right
  }
  sb.to_string()
}

///|
/// Inserts `text` at `index`. Without `attributes` the text inherits the
/// formatting at that position, like `Y.Text.insert`.
pub fn TextRef::insert(
  self : TextRef,
  index : Int,
  text : String,
  attributes? : Attrs,
) -> Unit raise TypeError {
  if text.length() <= 0 {
    return
  }
  check_index(index, self.branch.length)
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    let pos = find_position(txn, self.branch, index, attributes is None)
    let attrs = match attributes {
      Some(a) => copy_attrs(a)
      None => copy_attrs(pos.current_attributes)
    }
    insert_text(txn, self.branch, pos, Text(text), attrs)
  })
}

///|
fn check_index(index : Int, length : Int) -> Unit raise TypeError {
  if index < 0 || index > length {
    raise LengthExceeded(index~, length~)
  }
}

///|
/// Inserts an embed (image, mention, ...) at `index` (`insertEmbed`).
pub fn TextRef::insert_embed(
  self : TextRef,
  index : Int,
  embed : @lib0.Any,
  attributes? : Attrs,
) -> Unit raise TypeError {
  check_index(index, self.branch.length)
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    let pos = find_position(txn, self.branch, index, attributes is None)
    let attrs = match attributes {
      Some(a) => copy_attrs(a)
      None => Map([])
    }
    insert_text(txn, self.branch, pos, Embed(embed), attrs)
  })
}

///|
/// Deletes `length` UTF-16 code units starting at `index`.
pub fn TextRef::delete(
  self : TextRef,
  index : Int,
  length : Int,
) -> Unit raise TypeError {
  if length == 0 {
    return
  }
  if index < 0 || length < 0 || index + length > self.branch.length {
    raise LengthExceeded(index~, length=self.branch.length)
  }
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    ignore(
      delete_text(txn, find_position(txn, self.branch, index, true), length),
    )
  })
}

///|
/// Applies `attributes` to the range `[index, index + length)` (`format`).
pub fn TextRef::format(
  self : TextRef,
  index : Int,
  length : Int,
  attributes : Attrs,
) -> Unit {
  if length == 0 {
    return
  }
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    let pos = find_position(txn, self.branch, index, false)
    if pos.right is None {
      return
    }
    format_text(txn, self.branch, pos, length, copy_attrs(attributes))
  })
}

///|
/// Applies a delta (`applyDelta`), e.g. coming from a Quill editor.
pub fn TextRef::apply_delta(self : TextRef, delta : ArrayView[Delta]) -> Unit {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    let curr : TextPos = {
      left: None,
      right: self.branch.start,
      index: 0,
      current_attributes: Map([]),
    }
    for op in delta {
      match op {
        Insert(chunk, attributes~) => {
          let non_empty = match chunk {
            Text(s) => s.length() > 0
            _ => true
          }
          if non_empty {
            insert_text(txn, self.branch, curr, chunk, copy_attrs(attributes))
          }
        }
        Retain(n, attributes~) =>
          format_text(txn, self.branch, curr, n, copy_attrs(attributes))
        Delete(n) => ignore(delete_text(txn, curr, n))
      }
    }
  })
}

///|
/// One run of the rich-text content (`toDelta` entry).
pub(all) struct DeltaRun {
  insert : DeltaInsert
  attributes : Attrs?
}

///|
/// The inserted part of a delta run.
pub(all) enum DeltaInsert {
  /// A text run.
  Text(String)
  /// An embed value.
  Embed(@lib0.Any)
  /// A nested shared type.
  Shared(Branch)
}

///|
/// The rich-text content as a list of formatted runs (`toDelta`).
pub fn TextRef::to_delta(self : TextRef) -> Array[DeltaRun] {
  let ops : Array[DeltaRun] = []
  let current_attributes : Map[String, @lib0.Any] = Map([])
  let sb = StringBuilder()
  fn attrs_snapshot() -> Attrs? {
    if current_attributes.length() > 0 {
      Some(copy_attrs(current_attributes))
    } else {
      None
    }
  }

  fn pack_str() -> Unit {
    let s = sb.to_string()
    if s.length() > 0 {
      ops.push({ insert: Text(s), attributes: attrs_snapshot(), })
      sb.reset()
    }
  }

  let mut n = self.branch.start
  while n is Some(item) {
    if !item.deleted() {
      match item.content {
        CString(s) => sb.write_string(s)
        CType(b) => {
          pack_str()
          ops.push({ insert: Shared(b), attributes: attrs_snapshot(), })
        }
        CEmbed(j) => {
          pack_str()
          ops.push({ insert: Embed(j), attributes: attrs_snapshot(), })
        }
        CFormat(key, value) => {
          pack_str()
          update_current_attributes(current_attributes, key, value)
        }
        _ => ()
      }
    }
    n = item.right
  }
  pack_str()
  ops
}

///|
/// Converts a delta to JSON in the same shape as Yjs (`[{insert, attributes}]`).
pub fn delta_to_json(delta : ArrayView[DeltaRun]) -> Json {
  Json::array(
    delta
    .to_owned()
    .map(run => {
      let obj : Map[String, Json] = Map([])
      obj["insert"] = match run.insert {
        Text(s) => Json::string(s)
        Embed(v) => any_to_json(v)
        Shared(b) => b.to_json()
      }
      match run.attributes {
        Some(a) => {
          let am : Map[String, Json] = Map([])
          for k in @lib0.js_object_keys(a) {
            am[k] = any_to_json(a[k])
          }
          obj["attributes"] = Json::object(am)
        }
        None => ()
      }
      Json::object(obj)
    }),
  )
}
