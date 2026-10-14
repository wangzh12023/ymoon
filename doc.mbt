// Shared types ("branches") and the document, mirroring
// yjs/src/types/AbstractType.js and yjs/src/utils/Doc.js.

///|
/// The internal representation of every shared type (Y.Text, Y.Array, Y.Map,
/// Y.Xml*). Kind-specific APIs live in thin wrappers (`TextRef`, `ArrayRef`,
/// `MapRef`, ...).
pub struct Branch {
  /// The item that holds this branch, or None for root types.
  mut item : Item?
  /// Latest item per map key (`_map`).
  map : Map[String, Item]
  /// First item of the list part (`_start`).
  mut start : Item?
  /// Owning document.
  mut doc : Doc?
  /// Number of countable, non-deleted list elements (`_length`).
  mut length : Int32
  /// What kind of shared type this branch is. Root branches start as
  /// `None` until first accessed with a concrete kind (`Doc.get`).
  mut kind : TypeRef?
  /// Whether formatting attributes were ever inserted (Y.Text only).
  mut has_formatting : Bool
  /// Index cache (`_searchMarker`); None for types that never use markers.
  priv mut search_markers : Array[SearchMarker]?
  /// Process-unique identity, used as a cheap map key.
  priv uid : Int32
}

///|
let branch_uid_counter : Ref[Int32] = Ref(0)

///|
fn Branch::new_branch(kind : TypeRef?) -> Branch {
  {
    item: None,
    map: Map([]),
    start: None,
    doc: None,
    length: 0,
    kind,
    has_formatting: false,
    search_markers: initial_markers(kind),
    uid: {
      branch_uid_counter.val = branch_uid_counter.val + 1
      branch_uid_counter.val
    },
  }
}

///|
/// Y.Array, Y.Text and Y.XmlText keep a search-marker list; other types don't.
fn initial_markers(kind : TypeRef?) -> Array[SearchMarker]? {
  match kind {
    Some(YArray) | Some(YText) | Some(YXmlText) => Some([])
    _ => None
  }
}

///|
/// The kind of this shared type (`YArray`, `YMap`, `YText`, ...).
pub fn Branch::kind(self : Branch) -> TypeRef? {
  self.kind
}

///|
/// Number of visible list elements (text length in UTF-16 units for Y.Text).
pub fn Branch::len(self : Branch) -> Int32 {
  self.length
}

///|
fn Branch::doc_or_abort(self : Branch) -> Doc {
  match self.doc {
    Some(d) => d
    None => abort("shared type is not attached to a document")
  }
}

///|
/// The `ID` of the item that holds this branch, if nested.
pub fn Branch::id(self : Branch) -> ID? {
  match self.item {
    Some(it) => Some(it.id)
    None => None
  }
}

///|
/// A Yjs document: a set of named root shared types plus the struct store.
pub struct Doc {
  /// This peer's client id.
  mut client_id : UInt32
  /// Whether deleted content is garbage collected.
  gc : Bool
  /// Globally unique document id.
  guid : String
  /// Root types by name (`share`).
  share : Map[String, Branch]
  /// All structs.
  store : StructStore
  priv mut pending_structs : PendingStructs?
  priv mut pending_ds : Bytes?
  priv mut transaction : Transaction?
  priv update_handlers : Array[(Bytes, String) -> Unit]
  priv after_transaction_handlers : Array[(Transaction) -> Unit]
  priv observers : Array[(Transaction) -> Unit]
}

///|
/// Structs that could not be integrated yet because of missing dependencies.
priv struct PendingStructs {
  missing : Map[UInt32, Int32]
  update : Bytes
}

///|
/// Creates a document. When `client_id` is omitted, a random 32-bit id is
/// chosen like `random.uint32` in Yjs.
pub fn Doc::Doc(client_id? : UInt32, gc~ : Bool = true, guid? : String) -> Doc {
  let client_id = match client_id {
    Some(c) => c
    None => random_client_id()
  }
  let guid = match guid {
    Some(g) => g
    None => random_uuid()
  }
  {
    client_id,
    gc,
    guid,
    share: Map([]),
    store: StructStore::new_store(),
    pending_structs: None,
    pending_ds: None,
    transaction: None,
    update_handlers: [],
    after_transaction_handlers: [],
    observers: [],
  }
}

///|
/// This peer's client id.
pub fn Doc::client_id(self : Doc) -> UInt32 {
  self.client_id
}

///|
/// Registers a callback that receives every v1 update produced by a
/// transaction, together with the transaction origin.
pub fn Doc::on_update(self : Doc, f : (Bytes, String) -> Unit) -> Unit {
  self.update_handlers.push(f)
}

///|
/// Removes all update callbacks registered with `on_update`.
pub fn Doc::clear_update_handlers(self : Doc) -> Unit {
  self.update_handlers.clear()
}

///|
/// Registers an observer called with every transaction before cleanup
/// (equivalent to observing all types; use `Transaction::changed_types`).
pub fn Doc::observe(self : Doc, f : (Transaction) -> Unit) -> Unit {
  self.observers.push(f)
}

///|
/// Registers a callback that runs after each transaction has been cleaned up.
pub fn Doc::on_after_transaction(self : Doc, f : (Transaction) -> Unit) -> Unit {
  self.after_transaction_handlers.push(f)
}

///|
/// Gets (or creates) the root type `name`, upgrading an untyped root created by
/// a remote update to `kind` (`Doc.get`).
fn Doc::get_root(self : Doc, name : String, kind : TypeRef) -> Branch {
  match self.share.get(name) {
    Some(b) =>
      match b.kind {
        None => {
          // Yjs replaces the untyped placeholder with a fresh typed instance
          // that copies `_map`, `_start` and `_length` only: the formatting
          // flag is reset and the search-marker cache is re-enabled.
          b.kind = Some(kind)
          b.has_formatting = false
          b.search_markers = initial_markers(Some(kind))
          b
        }
        Some(k) =>
          if same_kind(k, kind) {
            b
          } else {
            abort(
              "Type with the name \{name} has already been defined with a different constructor",
            )
          }
      }
    None => {
      let b = Branch::new_branch(Some(kind))
      b.doc = Some(self)
      self.share[name] = b
      b
    }
  }
}

///|
fn same_kind(a : TypeRef, b : TypeRef) -> Bool {
  a.ref_number() == b.ref_number()
}

///|
/// Root branch lookup used when decoding: creates an untyped root if missing.
fn Doc::root_for_decode(self : Doc, name : String) -> Branch {
  match self.share.get(name) {
    Some(b) => b
    None => {
      let b = Branch::new_branch(None)
      b.doc = Some(self)
      self.share[name] = b
      b
    }
  }
}

///|
/// Root names currently known to this document, in creation order.
pub fn Doc::root_names(self : Doc) -> Array[String] {
  self.share.keys().collect()
}

///|
/// The root branch called `name`, if it exists.
pub fn Doc::root(self : Doc, name : String) -> Branch? {
  self.share.get(name)
}

///|
/// The state vector of this document.
pub fn Doc::state_vector(self : Doc) -> StateVector {
  self.store.state_vector()
}

///|
/// Encoded state vector (`Y.encodeStateVector`).
pub fn Doc::encode_state_vector(self : Doc) -> Bytes {
  self.store.state_vector().encode()
}

///|
fn random_client_id() -> UInt32 {
  match @env.rand(4) {
    Some(b) if b.length() == 4 =>
      (b[0].to_uint() << 24) |
      (b[1].to_uint() << 16) |
      (b[2].to_uint() << 8) |
      b[3].to_uint()
    _ => {
      // fall back to a time based seed
      let t = @env.now()
      (t ^ (t >> 32)).to_uint()
    }
  }
}

///|
fn random_uuid() -> String {
  let bytes = match @env.rand(16) {
    Some(b) if b.length() == 16 => b.to_array()
    _ => {
      let rng = @random.Rand()
      Array::makei(16, _ => rng.int(limit=256).to_byte())
    }
  }
  bytes[6] = ((bytes[6].to_int() & 0x0f) | 0x40).to_byte()
  bytes[8] = ((bytes[8].to_int() & 0x3f) | 0x80).to_byte()
  let digits = "0123456789abcdef"
  let sb = StringBuilder(size_hint=36)
  for i, b in bytes {
    if i == 4 || i == 6 || i == 8 || i == 10 {
      sb.write_char('-')
    }
    sb.write_char(digits.get_char(b.to_int() >> 4).unwrap())
    sb.write_char(digits.get_char(b.to_int() & 15).unwrap())
  }
  sb.to_string()
}
