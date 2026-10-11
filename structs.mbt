// Core data model of the YATA CRDT, mirroring yjs/src/structs and yjs/src/utils/ID.js.

///|
/// A Lamport-style identifier: `(client, clock)`.
///
/// `client` is a random 32-bit peer id (Yjs uses `random.uint32`), so it is
/// stored as `UInt`; clocks count UTF-16 code units / elements per client.
pub(all) struct ID {
  client : UInt
  clock : Int
} derive(Eq, Hash, Debug, Compare)

///|
pub fn ID::ID(client : UInt, clock : Int) -> ID {
  { client, clock, }
}

///|
fn id_opt_eq(a : ID?, b : ID?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x.client == y.client && x.clock == y.clock
    _ => false
  }
}

///|
/// Built-in shared type kinds and their wire reference numbers
/// (`ContentType` type refs in Yjs).
pub(all) enum TypeRef {
  YArray
  YMap
  YText
  YXmlElement(String)
  YXmlFragment
  YXmlHook(String)
  YXmlText
} derive(Eq, Debug)

///|
fn TypeRef::ref_number(self : TypeRef) -> Int {
  match self {
    YArray => 0
    YMap => 1
    YText => 2
    YXmlElement(_) => 3
    YXmlFragment => 4
    YXmlHook(_) => 5
    YXmlText => 6
  }
}

///|
/// The payload of an `Item`. Variants and wire numbers follow
/// `yjs/src/structs/Content*.js`.
pub(all) enum Content {
  /// ref 1 - tombstone payload after garbage collection of a deleted item.
  Deleted(Int)
  /// ref 2 - legacy JSON-encoded values (still decodable).
  JSON(Array[String])
  /// ref 3 - a binary blob (`Uint8Array`).
  Binary(Bytes)
  /// ref 4 - a run of UTF-16 text.
  String(String)
  /// ref 5 - an embed in rich text (stored as JSON text).
  Embed(String)
  /// ref 6 - a formatting marker in rich text: key + JSON value text.
  Format(String, String)
  /// ref 7 - a nested shared type.
  Type(Branch)
  /// ref 8 - plain values (Y.Array elements, Y.Map values).
  Any(Array[@lib0.Any])
  /// ref 9 - a sub-document reference: guid + options.
  Doc(String, @lib0.Any)
}

///|
fn Content::ref_number(self : Content) -> Int {
  match self {
    Deleted(_) => 1
    JSON(_) => 2
    Binary(_) => 3
    String(_) => 4
    Embed(_) => 5
    Format(_, _) => 6
    Type(_) => 7
    Any(_) => 8
    Doc(_, _) => 9
  }
}

///|
/// Length of a content run, measured in Yjs clock units.
fn Content::len(self : Content) -> Int {
  match self {
    Deleted(n) => n
    JSON(xs) => xs.length()
    String(s) => s.length()
    Any(xs) => xs.length()
    Binary(_) | Embed(_) | Format(_, _) | Type(_) | Doc(_, _) => 1
  }
}

///|
/// Whether the content contributes to the user-visible length of a list.
fn Content::is_countable(self : Content) -> Bool {
  match self {
    Deleted(_) | Format(_, _) => false
    _ => true
  }
}

///|
/// Splits content at `offset`, returning (left, right).
/// Mirrors `AbstractContent.splice`, including the surrogate pair fix-up.
fn Content::split(self : Content, offset : Int) -> (Content, Content) {
  match self {
    Deleted(n) => (Deleted(offset), Deleted(n - offset))
    JSON(xs) => (JSON(xs[:offset].to_owned()), JSON(xs[offset:].to_owned()))
    Any(xs) => (Any(xs[:offset].to_owned()), Any(xs[offset:].to_owned()))
    String(s) => {
      let mut left = s.unsafe_substring(start=0, end=offset)
      let mut right = s.unsafe_substring(start=offset, end=s.length())
      // Yjs replaces a surrogate pair broken by the split with U+FFFD on both
      // sides (yjs issue #248).
      let last = s[offset - 1].to_int()
      if last >= 0xD800 && last <= 0xDBFF {
        left = s.unsafe_substring(start=0, end=offset - 1) + "\u{FFFD}"
        right = "\u{FFFD}" +
          s.unsafe_substring(start=offset + 1, end=s.length())
      }
      (String(left), String(right))
    }
    _ => abort("content of this kind cannot be split")
  }
}

///|
/// Tries to append `right` to `self` (`mergeWith`), returning the merged content.
fn Content::try_merge(self : Content, right : Content) -> Content? {
  match (self, right) {
    (Deleted(a), Deleted(b)) => Some(Deleted(a + b))
    (JSON(a), JSON(b)) => Some(JSON([..a, ..b]))
    (Any(a), Any(b)) => Some(Any([..a, ..b]))
    (String(a), String(b)) => Some(String(a + b))
    _ => None
  }
}

///|
/// Flags stored in `Item::info`, matching the bit layout used by Yjs.
const INFO_KEEP : Int = 1

///|
const INFO_COUNTABLE : Int = 2

///|
const INFO_DELETED : Int = 4

///|
/// The item is referenced by a search marker.
const INFO_MARKER : Int = 8

///|
/// An integrated piece of content (`Item` in Yjs).
pub struct Item {
  mut id : ID
  mut len : Int
  /// The ID of the element that was to the left when this item was created.
  mut origin : ID?
  /// The item currently to the left in the parent's list.
  mut left : Item?
  /// The item currently to the right in the parent's list.
  mut right : Item?
  /// The ID of the element that was to the right when this item was created.
  mut right_origin : ID?
  /// The parent shared type (None for items whose parent was collected).
  mut parent : Parent
  /// Map key when the item belongs to a Y.Map-like slot.
  mut parent_sub : String?
  mut content : Content
  mut info : Int
  /// Undo/redo bookkeeping (kept for format compatibility).
  mut redone : ID?
}

///|
/// Where an item lives. Before integration Yjs keeps parents as ID or root
/// name; afterwards they always point at a branch.
pub enum Parent {
  /// Parent known and integrated.
  Branch(Branch)
  /// Parent given by the ID of the item holding a nested type.
  PendingId(ID)
  /// Parent is a root type, looked up by name.
  PendingRoot(String)
  /// Copy the parent from the left / right neighbour.
  Unknown
  /// The parent was garbage collected; the item integrates as a GC range.
  Gone
}

///|
fn Item::new_item(
  id : ID,
  left : Item?,
  origin : ID?,
  right : Item?,
  right_origin : ID?,
  parent : Parent,
  parent_sub : String?,
  content : Content,
) -> Item {
  {
    id,
    len: content.len(),
    origin,
    left,
    right,
    right_origin,
    parent,
    parent_sub,
    content,
    info: if content.is_countable() {
      INFO_COUNTABLE
    } else {
      0
    },
    redone: None,
  }
}

///|
pub fn Item::deleted(self : Item) -> Bool {
  (self.info & INFO_DELETED) != 0
}

///|
fn Item::countable(self : Item) -> Bool {
  (self.info & INFO_COUNTABLE) != 0
}

///|
fn Item::keep(self : Item) -> Bool {
  (self.info & INFO_KEEP) != 0
}

///|
fn Item::mark_deleted(self : Item) -> Unit {
  self.info = self.info | INFO_DELETED
}

///|
/// ID of the last clock unit covered by this item.
fn Item::last_id(self : Item) -> ID {
  if self.len == 1 {
    self.id
  } else {
    { client: self.id.client, clock: self.id.clock + self.len - 1, }
  }
}

///|
fn Item::branch(self : Item) -> Branch {
  match self.parent {
    Branch(b) => b
    _ => abort("item parent is not integrated")
  }
}

///|
/// A struct in the per-client struct store: `GC`, `Item` or (only inside
/// updates) `Skip`.
pub enum Struct {
  GC(GCRange)
  Item(Item)
  Skip(GCRange)
}

///|
/// A garbage-collected or skipped clock range.
pub struct GCRange {
  mut id : ID
  mut len : Int
}

///|
fn Struct::id(self : Struct) -> ID {
  match self {
    GC(g) | Skip(g) => g.id
    Item(i) => i.id
  }
}

///|
fn Struct::len(self : Struct) -> Int {
  match self {
    GC(g) | Skip(g) => g.len
    Item(i) => i.len
  }
}

///|
fn Struct::deleted(self : Struct) -> Bool {
  match self {
    GC(_) | Skip(_) => true
    Item(i) => i.deleted()
  }
}

///|
fn Struct::end_clock(self : Struct) -> Int {
  let id = self.id()
  id.clock + self.len()
}
