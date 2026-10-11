// Y.Array, Y.Map and the XML types. Ports of yjs/src/types/YArray.js,
// YMap.js, YXmlFragment.js, YXmlElement.js and YXmlText.js.

///|
/// A handle to a Y.Array.
pub struct ArrayRef {
  branch : Branch
}

///|
/// Gets (or creates) the root Y.Array called `name` (`doc.getArray(name)`).
pub fn Doc::get_array(self : Doc, name : String) -> ArrayRef {
  { branch: self.get_root(name, YArray), }
}

///|
/// Wraps a branch known to be an array.
pub fn ArrayRef::from_branch(b : Branch) -> ArrayRef {
  { branch: b, }
}

///|
/// The underlying branch.
pub fn ArrayRef::branch(self : ArrayRef) -> Branch {
  self.branch
}

///|
/// Number of elements.
pub fn ArrayRef::length(self : ArrayRef) -> Int {
  self.branch.length
}

///|
/// Inserts `values` at `index`.
pub fn ArrayRef::insert(
  self : ArrayRef,
  index : Int,
  values : ArrayView[Value],
) -> Unit raise TypeError {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => type_list_insert(txn, self.branch, index, values))
}

///|
/// Appends `values` at the end.
pub fn ArrayRef::push(self : ArrayRef, values : ArrayView[Value]) -> Unit {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => type_list_push(txn, self.branch, values))
}

///|
/// Prepends `values`.
pub fn ArrayRef::unshift(
  self : ArrayRef,
  values : ArrayView[Value],
) -> Unit raise TypeError {
  self.insert(0, values)
}

///|
/// Deletes `length` elements starting at `index`.
pub fn ArrayRef::delete(
  self : ArrayRef,
  index : Int,
  length? : Int = 1,
) -> Unit raise TypeError {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => type_list_delete(txn, self.branch, index, length))
}

///|
/// Element at `index`.
pub fn ArrayRef::get(self : ArrayRef, index : Int) -> Out? {
  type_list_get(self.branch, index)
}

///|
/// All elements.
pub fn ArrayRef::to_array(self : ArrayRef) -> Array[Out] {
  type_list_to_array(self.branch)
}

///|
/// JSON view of the array (`toJSON`).
pub fn ArrayRef::to_json(self : ArrayRef) -> Json {
  self.branch.to_json()
}

///|
/// Inserts a new nested shared type at `index` and returns its branch.
pub fn ArrayRef::insert_shared(
  self : ArrayRef,
  index : Int,
  kind : TypeRef,
) -> Branch raise TypeError {
  self.insert(index, [Shared(kind)])
  match self.get(index) {
    Some(Shared(b)) => b
    _ => abort("internal: nested type not found after insertion")
  }
}

///|
/// A handle to a Y.Map.
pub struct MapRef {
  branch : Branch
}

///|
/// Gets (or creates) the root Y.Map called `name` (`doc.getMap(name)`).
pub fn Doc::get_map(self : Doc, name : String) -> MapRef {
  { branch: self.get_root(name, YMap), }
}

///|
/// Wraps a branch known to be a map.
pub fn MapRef::from_branch(b : Branch) -> MapRef {
  { branch: b, }
}

///|
/// The underlying branch.
pub fn MapRef::branch(self : MapRef) -> Branch {
  self.branch
}

///|
/// Sets `key` to `value`.
pub fn MapRef::set(self : MapRef, key : String, value : Value) -> Unit {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => ignore(type_map_set(txn, self.branch, key, value)))
}

///|
/// Sets `key` to a new nested shared type and returns its branch.
pub fn MapRef::set_shared(
  self : MapRef,
  key : String,
  kind : TypeRef,
) -> Branch {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    let item = type_map_set(txn, self.branch, key, Shared(kind))
    match item.content {
      Type(b) => b
      _ => abort("internal: nested type expected")
    }
  })
}

///|
/// Value of `key`.
pub fn MapRef::get(self : MapRef, key : String) -> Out? {
  type_map_get(self.branch, key)
}

///|
/// Whether `key` currently has a value.
pub fn MapRef::has(self : MapRef, key : String) -> Bool {
  match self.branch.map.get(key) {
    Some(item) => !item.deleted()
    None => false
  }
}

///|
/// Deletes `key`.
pub fn MapRef::delete(self : MapRef, key : String) -> Unit {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => type_map_delete(txn, self.branch, key))
}

///|
/// Removes all keys (`clear`).
pub fn MapRef::clear(self : MapRef) -> Unit {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    for key in self.keys() {
      type_map_delete(txn, self.branch, key)
    }
  })
}

///|
/// Keys with a value, in first-insertion order (like a JavaScript `Map`).
pub fn MapRef::keys(self : MapRef) -> Array[String] {
  let out : Array[String] = []
  for key, item in self.branch.map {
    if !item.deleted() {
      out.push(key)
    }
  }
  out
}

///|
/// Number of keys with a value.
pub fn MapRef::size(self : MapRef) -> Int {
  self.keys().length()
}

///|
/// `(key, value)` pairs.
pub fn MapRef::entries(self : MapRef) -> Array[(String, Out)] {
  let out : Array[(String, Out)] = []
  for key, item in self.branch.map {
    if !item.deleted() {
      out.push((key, content_last_value(item)))
    }
  }
  out
}

///|
/// JSON view of the map (`toJSON`).
pub fn MapRef::to_json(self : MapRef) -> Json {
  self.branch.to_json()
}

///|
/// A handle to a Y.XmlFragment / Y.XmlElement.
pub struct XmlRef {
  branch : Branch
}

///|
/// Gets (or creates) the root Y.XmlFragment called `name`.
pub fn Doc::get_xml_fragment(self : Doc, name : String) -> XmlRef {
  { branch: self.get_root(name, YXmlFragment), }
}

///|
/// Wraps a branch known to be an XML fragment or element.
pub fn XmlRef::from_branch(b : Branch) -> XmlRef {
  { branch: b, }
}

///|
/// The underlying branch.
pub fn XmlRef::branch(self : XmlRef) -> Branch {
  self.branch
}

///|
/// Node name of an element (None for fragments).
pub fn XmlRef::node_name(self : XmlRef) -> String? {
  match self.branch.kind {
    Some(YXmlElement(name)) => Some(name)
    _ => None
  }
}

///|
/// Number of child nodes.
pub fn XmlRef::length(self : XmlRef) -> Int {
  self.branch.length
}

///|
/// Inserts a new element `<node_name>` at `index` and returns it.
pub fn XmlRef::insert_element(
  self : XmlRef,
  index : Int,
  node_name : String,
) -> XmlRef raise TypeError {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    type_list_insert(txn, self.branch, index, [Shared(YXmlElement(node_name))])
  })
  match type_list_get(self.branch, index) {
    Some(Shared(b)) => { branch: b, }
    _ => abort("internal: element not found after insertion")
  }
}

///|
/// Inserts a new text node at `index` and returns it.
pub fn XmlRef::insert_text(
  self : XmlRef,
  index : Int,
) -> TextRef raise TypeError {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    type_list_insert(txn, self.branch, index, [Shared(YXmlText)])
  })
  match type_list_get(self.branch, index) {
    Some(Shared(b)) => { branch: b, }
    _ => abort("internal: text node not found after insertion")
  }
}

///|
/// Deletes `length` children starting at `index`.
pub fn XmlRef::delete(
  self : XmlRef,
  index : Int,
  length? : Int = 1,
) -> Unit raise TypeError {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => type_list_delete(txn, self.branch, index, length))
}

///|
/// Sets an attribute of an element.
pub fn XmlRef::set_attribute(
  self : XmlRef,
  key : String,
  value : String,
) -> Unit {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => {
    ignore(type_map_set(txn, self.branch, key, Value::str(value)))
  })
}

///|
/// Gets an attribute of an element.
pub fn XmlRef::get_attribute(self : XmlRef, key : String) -> String? {
  match type_map_get(self.branch, key) {
    Some(Any(String(s))) => Some(s)
    _ => None
  }
}

///|
/// Removes an attribute.
pub fn XmlRef::remove_attribute(self : XmlRef, key : String) -> Unit {
  let doc = self.branch.doc_or_abort()
  doc.transact(txn => type_map_delete(txn, self.branch, key))
}

///|
/// Child nodes.
pub fn XmlRef::children(self : XmlRef) -> Array[Branch] {
  type_list_to_array(self.branch).filter_map(o => o.as_shared())
}

///|
/// Serialises the fragment / element as XML (`toString`).
pub fn XmlRef::to_string(self : XmlRef) -> String {
  self.branch.to_xml_string()
}

///|
fn Branch::to_xml_string(self : Branch) -> String {
  match self.kind {
    Some(YXmlText) => xml_text_to_string(self)
    Some(YXmlElement(name)) => {
      let sb = StringBuilder()
      sb.write_string("<")
      sb.write_string(name)
      // attributes sorted by key, like `getAttributes` + sort in Yjs
      let keys : Array[String] = []
      for key, item in self.map {
        if !item.deleted() {
          keys.push(key)
        }
      }
      keys.sort_by((a, b) => a.lexical_compare(b))
      for key in keys {
        let v = match type_map_get(self, key) {
          Some(Any(String(s))) => s
          Some(o) => o.to_json().stringify()
          None => ""
        }
        sb.write_string(" \{key}=\"\{v}\"")
      }
      sb.write_string(">")
      for child in type_list_to_array(self) {
        match child {
          Shared(b) => sb.write_string(b.to_xml_string())
          Any(a) => sb.write_string(any_to_json_string(a))
          SubDoc(_) => ()
        }
      }
      sb.write_string("</")
      sb.write_string(name)
      sb.write_string(">")
      sb.to_string()
    }
    _ => {
      let sb = StringBuilder()
      for child in type_list_to_array(self) {
        match child {
          Shared(b) => sb.write_string(b.to_xml_string())
          Any(a) => sb.write_string(any_to_json_string(a))
          SubDoc(_) => ()
        }
      }
      sb.to_string()
    }
  }
}

///|
/// XML serialisation of a Y.XmlText: formatted runs become nested tags
/// (`YXmlText.toString`).
fn xml_text_to_string(b : Branch) -> String {
  let sb = StringBuilder()
  for run in TextRef::from_branch(b).to_delta() {
    let nested : Array[(String, Array[(String, String)])] = []
    match run.attributes {
      Some(attrs) =>
        for node_name, v in attrs {
          let kv : Array[(String, String)] = []
          match v {
            Object(m) =>
              for k, vv in m {
                kv.push((k, js_display(vv)))
              }
            _ => ()
          }
          kv.sort_by((a, b) => a.0.lexical_compare(b.0))
          nested.push((node_name, kv))
        }
      None => ()
    }
    nested.sort_by((a, b) => a.0.lexical_compare(b.0))
    for node in nested {
      sb.write_string("<")
      sb.write_string(node.0)
      for attr in node.1 {
        sb.write_string(" \{attr.0}=\"\{attr.1}\"")
      }
      sb.write_string(">")
    }
    match run.insert {
      Text(s) => sb.write_string(s)
      Embed(v) => sb.write_string(js_display(v))
      Shared(nb) => sb.write_string(nb.to_xml_string())
    }
    for i = nested.length() - 1; i >= 0; i = i - 1 {
      sb.write_string("</\{nested[i].0}>")
    }
  }
  sb.to_string()
}

///|
/// String conversion of a value as JavaScript template literals do.
fn js_display(v : @lib0.Any) -> String {
  match v {
    String(s) => s
    Number(d) => Json::number(d).stringify()
    Bool(b) => if b { "true" } else { "false" }
    Null => "null"
    Undefined => "undefined"
    Object(_) => "[object Object]"
    _ => any_to_json_string(v)
  }
}
