// The lib0 "any" value model (lib0/encoding.writeAny, lib0/decoding.readAny).
//
// Yjs stores user values (Y.Map values, Y.Array elements, ...) in this format.
// Numbers follow JavaScript semantics: every number is an IEEE-754 double and
// the wire representation (varint / float32 / float64) is chosen from the value.

///|
/// A JavaScript-like value that can be stored inside a Yjs document.
pub(all) enum Any {
  /// JavaScript `undefined`.
  Undefined
  /// JavaScript `null`.
  Null
  /// A boolean.
  Bool(Bool)
  /// A JavaScript number (always a double).
  Number(Double)
  /// A JavaScript `bigint` restricted to 64 bits (lib0 `writeBigInt64`).
  BigInt64(Int64)
  /// A string.
  String(String)
  /// A `Uint8Array`.
  Bytes(Bytes)
  /// An array.
  Array(Array[Any])
  /// A plain object. Iteration and encoding use JavaScript property order,
  /// see `js_object_keys`.
  Object(Map[String, Any])
} derive(Eq, Debug)

///|
/// Convenience constructor for integral numbers.
pub fn Any::int(n : Int32) -> Any {
  Number(n.to_double())
}

///|
/// Convenience constructor for strings.
pub fn Any::str(s : StringView) -> Any {
  String(s.to_owned())
}

///|
/// Builds an object value from key/value pairs.
pub fn Any::object(pairs : ArrayView[(String, Any)]) -> Any {
  let m : Map[String, Any] = Map([])
  for pair in pairs {
    m[pair.0] = pair.1
  }
  Object(m)
}

///|
fn is_negative_zero(d : Double) -> Bool {
  d == 0.0 && d.reinterpret_as_uint64() >> 63 == 1UL
}

///|
fn is_js_integer(d : Double) -> Bool {
  d == d && d.trunc() == d && d != @double.infinity && d != @double.neg_infinity
}

///|
fn is_float32(d : Double) -> Bool {
  Float::from_double(d).to_double() == d
}

///|
/// Whether `k` is a JavaScript array index ("0", "1", ..., "4294967294").
/// Such keys are enumerated first, in ascending numeric order.
pub fn is_js_array_index(k : StringView) -> Bool {
  let n = k.length()
  if n == 0 || n > 10 {
    return false
  }
  if k.at(0) == '0' {
    return n == 1
  }
  let mut v = 0UL
  for i in 0..<n {
    let c = k.at(i).to_int()
    if c < '0'.to_int() || c > '9'.to_int() {
      return false
    }
    v = v * 10UL + (c - '0'.to_int()).to_uint64()
  }
  v < 4294967295UL
}

///|
/// Keys of `m` in JavaScript `Object.keys` order: array-index keys in
/// ascending numeric order, then the remaining keys in insertion order.
pub fn js_object_keys(m : Map[String, Any]) -> Array[String] {
  let indices : Array[(UInt64, String)] = []
  let rest : Array[String] = []
  for k, _ in m {
    if is_js_array_index(k) {
      let mut v = 0UL
      for i in 0..<k.length() {
        v = v * 10UL + (k[i].to_int() - '0'.to_int()).to_uint64()
      }
      indices.push((v, k))
    } else {
      rest.push(k)
    }
  }
  indices.sort_by((a, b) => a.0.compare(b.0))
  let out : Array[String] = Array(capacity=m.length())
  for p in indices {
    out.push(p.1)
  }
  for k in rest {
    out.push(k)
  }
  out
}

///|
/// Encodes a value with lib0's `writeAny`.
pub fn Encoder::write_any(self : Encoder, value : Any) -> Unit {
  match value {
    String(s) => {
      self.write_u8(119)
      self.write_var_string(s)
    }
    Number(d) =>
      if is_js_integer(d) && d.abs() <= 2147483647.0 {
        self.write_u8(125)
        self.write_var_int64(d.to_int64(), negative_zero=is_negative_zero(d))
      } else if is_float32(d) {
        self.write_u8(124)
        self.write_float32(Float::from_double(d))
      } else {
        self.write_u8(123)
        self.write_float64(d)
      }
    BigInt64(n) => {
      self.write_u8(122)
      self.write_big_int64(n)
    }
    Null => self.write_u8(126)
    Array(xs) => {
      self.write_u8(117)
      self.write_var_uint(xs.length())
      for x in xs {
        self.write_any(x)
      }
    }
    Bytes(b) => {
      self.write_u8(116)
      self.write_var_bytes(b)
    }
    Object(m) => {
      self.write_u8(118)
      let keys = js_object_keys(m)
      self.write_var_uint(keys.length())
      for k in keys {
        self.write_var_string(k)
        self.write_any(m.get(k).unwrap())
      }
    }
    Bool(b) => self.write_u8(if b { 120 } else { 121 })
    Undefined => self.write_u8(127)
  }
}

///|
/// Maximum nesting depth accepted by `read_any`, protecting against stack
/// exhaustion on hostile input.
pub let max_any_depth : Int32 = 1000

///|
/// Decodes a value written by lib0's `writeAny`.
pub fn Decoder::read_any(self : Decoder) -> Any raise DecodeError {
  self.read_any_depth(0)
}

///|
fn Decoder::read_any_depth(
  self : Decoder,
  depth : Int32,
) -> Any raise DecodeError {
  let start = self.pos()
  if depth > max_any_depth {
    raise Malformed(pos=start, reason="value nested too deeply")
  }
  let tag = self.read_u8()
  match tag {
    127 => Undefined
    126 => Null
    125 => {
      let (v, neg_zero) = self.read_var_int64_ext()
      Number(if neg_zero { -0.0 } else { v.to_double() })
    }
    124 => Number(self.read_float32().to_double())
    123 => Number(self.read_float64())
    122 => BigInt64(self.read_big_int64())
    121 => Bool(false)
    120 => Bool(true)
    119 => String(self.read_var_string())
    118 => {
      let len = self.read_var_uint()
      let m : Map[String, Any] = Map([])
      for _ in 0..<len {
        let key = self.read_var_string()
        m[key] = self.read_any_depth(depth + 1)
      }
      Object(m)
    }
    117 => {
      let len = self.read_var_uint()
      guard len <= self.length() - self.pos() else {
        raise UnexpectedEnd(pos=start)
      }
      let xs : Array[Any] = Array(capacity=len)
      for _ in 0..<len {
        xs.push(self.read_any_depth(depth + 1))
      }
      Array(xs)
    }
    116 => Bytes(self.read_var_bytes())
    _ => raise UnknownTag(pos=start, tag~)
  }
}
