// Values crossing the public API boundary.

///|
/// A value to insert into a shared type.
pub(all) enum Value {
  /// A plain JSON-like value (stored as `ContentAny`).
  Any(@lib0.Any)
  /// A binary blob (stored as `ContentBinary`).
  Binary(Bytes)
  /// A new, empty nested shared type of the given kind.
  Shared(TypeRef)
  /// A sub-document reference: guid and options.
  SubDoc(String, @lib0.Any)
}

///|
/// Shorthand for a string value.
pub fn Value::str(s : StringView) -> Value {
  Any(String(s.to_owned()))
}

///|
/// Shorthand for a number value.
pub fn Value::num(d : Double) -> Value {
  Any(Number(d))
}

///|
/// Shorthand for an integral number value.
pub fn Value::int(n : Int32) -> Value {
  Any(Number(n.to_double()))
}

///|
/// Shorthand for a boolean value.
pub fn Value::bool(b : Bool) -> Value {
  Any(Bool(b))
}

///|
/// A value read from a shared type.
pub enum Out {
  /// A plain value.
  Any(@lib0.Any)
  /// A nested shared type.
  Shared(Branch)
  /// A sub-document reference (its guid).
  SubDoc(String)
}

///|
/// Converts a read value to JSON, recursively expanding nested shared types
/// the way `toJSON()` does in Yjs.
pub fn Out::to_json(self : Out) -> Json {
  match self {
    Any(a) => any_to_json(a)
    Shared(b) => b.to_json()
    SubDoc(guid) => Json::object({ "guid": Json::string(guid) })
  }
}

///|
/// The plain value, if this is one.
pub fn Out::as_any(self : Out) -> @lib0.Any? {
  match self {
    Any(a) => Some(a)
    _ => None
  }
}

///|
/// The nested shared type, if this is one.
pub fn Out::as_shared(self : Out) -> Branch? {
  match self {
    Shared(b) => Some(b)
    _ => None
  }
}

///|
/// JSON view of a shared type (`toJSON`).
///
/// Root types that were created by remote updates but never accessed with a
/// concrete kind (typical for servers that only relay data) are rendered by
/// inferring their shape: a list of string runs as text, other list content as
/// an array, keyed content as a map.
pub fn Branch::to_json(self : Branch) -> Json {
  match self.kind {
    Some(YArray) => Json::array(type_list_to_array(self).map(v => v.to_json()))
    Some(YXmlFragment) => Json::string(self.to_xml_string())
    Some(YText) => Json::string(self.text_to_string())
    Some(YXmlText) | Some(YXmlElement(_)) => Json::string(self.to_xml_string())
    Some(YXmlHook(_)) | Some(YMap) => self.map_to_json()
    None =>
      match self.inferred_kind() {
        Some(YText) => Json::string(self.text_to_string())
        Some(YArray) =>
          Json::array(type_list_to_array(self).map(v => v.to_json()))
        _ => self.map_to_json()
      }
  }
}

///|
fn Branch::map_to_json(self : Branch) -> Json {
  let out : Map[String, Json] = Map([])
  for key, item in self.map {
    if !item.deleted() {
      out[key] = content_last_value(item).to_json()
    }
  }
  Json::object(out)
}

///|
/// Guesses the kind of an untyped root from its content: list items made of
/// text runs / format markers suggest Y.Text, other list items Y.Array, keyed
/// items Y.Map.
pub fn Branch::inferred_kind(self : Branch) -> TypeRef? {
  match self.kind {
    Some(k) => return Some(k)
    None => ()
  }
  let mut n = self.start
  while n is Some(item) {
    match item.content {
      CString(_) | CFormat(_, _) | CEmbed(_) => return Some(YText)
      CAny(_) | CJson(_) | CBinary(_) | CType(_) | CDoc(_, _) =>
        return Some(YArray)
      CDeleted(_) => ()
    }
    n = item.right
  }
  if self.map.length() > 0 {
    Some(YMap)
  } else {
    None
  }
}
