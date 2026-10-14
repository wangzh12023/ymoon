// JavaScript-compatible JSON serialisation of lib0 values.
//
// Yjs stores rich-text attributes and embeds as `JSON.stringify` output, so the
// exact text (number formatting, escaping, key order) is part of the wire
// format and must match V8 byte for byte.

///|
/// Formats a double exactly like JavaScript's `Number.prototype.toString()`
/// (ECMA-262 Number::toString with radix 10).
pub fn js_number_to_string(d : Double) -> String {
  if d != d {
    return "NaN"
  }
  if d == 0.0 {
    return "0"
  }
  if d == @double.infinity {
    return "Infinity"
  }
  if d == @double.neg_infinity {
    return "-Infinity"
  }
  let negative = d < 0.0
  let (digits, n) = shortest_digits(d.abs())
  let k = digits.length()
  let sb = StringBuilder()
  if negative {
    sb.write_char('-')
  }
  if k <= n && n <= 21 {
    // integer: digits followed by n - k zeros
    sb.write_string(digits)
    for _ in 0..<(n - k) {
      sb.write_char('0')
    }
  } else if 0 < n && n <= 21 {
    sb.write_string(digits.unsafe_substring(start=0, end=n))
    sb.write_char('.')
    sb.write_string(digits.unsafe_substring(start=n, end=k))
  } else if -6 < n && n <= 0 {
    sb.write_string("0.")
    for _ in 0..<-n {
      sb.write_char('0')
    }
    sb.write_string(digits)
  } else {
    let e = n - 1
    sb.write_string(digits.unsafe_substring(start=0, end=1))
    if k > 1 {
      sb.write_char('.')
      sb.write_string(digits.unsafe_substring(start=1, end=k))
    }
    sb.write_char('e')
    sb.write_char(if e >= 0 { '+' } else { '-' })
    sb.write_string(e.abs().to_string())
  }
  sb.to_string()
}

///|
/// Shortest round-tripping decimal digits of a positive finite double and
/// the decimal exponent `n` such that value = 0.digits * 10^n.
///
/// Uses MoonBit's shortest round-trip formatter (Ryu) and re-parses its
/// output into (digits, exponent), which is backend independent.
fn shortest_digits(d : Double) -> (String, Int32) {
  let s = d.to_string()
  // s looks like "123", "0.000123", "1.5e-7", "1e+21", "123456789.12345679"
  let mut mantissa = s
  let mut exp = 0
  match s.find("e") {
    Some(i) => {
      mantissa = s.unsafe_substring(start=0, end=i)
      let es = s.unsafe_substring(start=i + 1, end=s.length())
      let es = if es.has_prefix("+") {
        es.unsafe_substring(start=1, end=es.length())
      } else {
        es
      }
      exp = @string.parse_int(es) catch { _ => 0 }
    }
    None => ()
  }
  // split mantissa into integer and fraction digits
  let (int_part, frac_part) = match mantissa.find(".") {
    Some(i) =>
      (
        mantissa.unsafe_substring(start=0, end=i),
        mantissa.unsafe_substring(start=i + 1, end=mantissa.length()),
      )
    None => (mantissa, "")
  }
  let all = int_part + frac_part
  // strip leading zeros (adjusting the exponent) and trailing zeros
  let mut start = 0
  while start < all.length() - 1 && all[start] == '0' {
    start += 1
  }
  let mut end = all.length()
  while end > start + 1 && all[end - 1] == '0' {
    end -= 1
  }
  let digits = all.unsafe_substring(start~, end~)
  let n = int_part.length() - start + exp
  (digits, n)
}

///|
/// Appends `s` as a JSON string literal using V8's escaping rules
/// (well-formed `JSON.stringify`: lone surrogates become `\uXXXX`).
pub fn write_json_string(sb : StringBuilder, s : StringView) -> Unit {
  let hexd = "0123456789abcdef"
  sb.write_char('"')
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.at(i).to_int()
    match c {
      0x22 => sb.write_string("\\\"")
      0x5c => sb.write_string("\\\\")
      0x08 => sb.write_string("\\b")
      0x0c => sb.write_string("\\f")
      0x0a => sb.write_string("\\n")
      0x0d => sb.write_string("\\r")
      0x09 => sb.write_string("\\t")
      _ =>
        if c < 0x20 {
          sb.write_string("\\u00")
          sb.write_char(hexd.get_char(c >> 4).unwrap())
          sb.write_char(hexd.get_char(c & 15).unwrap())
        } else if c >= 0xD800 &&
          c <= 0xDBFF &&
          i + 1 < n &&
          s.at(i + 1).to_int() >= 0xDC00 &&
          s.at(i + 1).to_int() <= 0xDFFF {
          let d = s.at(i + 1).to_int()
          sb.write_char(
            (0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)).unsafe_to_char(),
          )
          i += 1
        } else if c >= 0xD800 && c <= 0xDFFF {
          sb.write_string("\\u")
          for shift in [12, 8, 4, 0] {
            sb.write_char(hexd.get_char((c >> shift) & 15).unwrap())
          }
        } else {
          sb.write_char(c.unsafe_to_char())
        }
    }
    i += 1
  }
  sb.write_char('"')
}

///|
/// Serialises a value like `JSON.stringify`. `undefined` (top level or in an
/// array) becomes `null`, object properties holding `undefined` are skipped,
/// non-finite numbers become `null` and bigints are rejected by JavaScript,
/// so they are written as plain numbers here.
pub fn Any::to_json_string(self : Any) -> String {
  let sb = StringBuilder()
  write_json_any(sb, self, true)
  sb.to_string()
}

///|
fn write_json_any(sb : StringBuilder, v : Any, top : Bool) -> Unit {
  match v {
    Undefined =>
      if top {
        sb.write_string("undefined")
      } else {
        sb.write_string("null")
      }
    Null => sb.write_string("null")
    Bool(b) => sb.write_string(if b { "true" } else { "false" })
    Number(d) =>
      if d != d || d == @double.infinity || d == @double.neg_infinity {
        sb.write_string("null")
      } else {
        sb.write_string(js_number_to_string(d))
      }
    BigInt64(n) => sb.write_string(n.to_string())
    String(s) => write_json_string(sb, s)
    Bytes(b) => {
      // a Uint8Array serialises as an object with index keys
      sb.write_char('{')
      for i, byte in b {
        if i > 0 {
          sb.write_char(',')
        }
        sb.write_string("\"\{i}\":\{byte.to_int()}")
      }
      sb.write_char('}')
    }
    Array(xs) => {
      sb.write_char('[')
      for i, x in xs {
        if i > 0 {
          sb.write_char(',')
        }
        write_json_any(sb, x, false)
      }
      sb.write_char(']')
    }
    Object(m) => {
      sb.write_char('{')
      let mut first = true
      for k in js_object_keys(m) {
        let x = m.get(k).unwrap()
        if x is Undefined {
          continue
        }
        if !first {
          sb.write_char(',')
        }
        first = false
        write_json_string(sb, k)
        sb.write_char(':')
        write_json_any(sb, x, false)
      }
      sb.write_char('}')
    }
  }
}

///|
/// Errors from `parse_json`.
pub(all) suberror JsonError {
  /// Invalid JSON text at the given UTF-16 offset.
  InvalidJson(pos~ : Int32)
} derive(Debug, Eq)

///|
/// Parses JSON text into an `Any` value following `JSON.parse`, keeping
/// object keys in JavaScript property order and numbers as doubles.
pub fn parse_json(text : StringView) -> Any raise JsonError {
  let p = { s: text, pos: 0, }
  p.skip_ws()
  let v = p.value(0)
  p.skip_ws()
  if p.pos != text.length() {
    raise InvalidJson(pos=p.pos)
  }
  v
}

///|
priv struct JsonParser {
  s : StringView
  mut pos : Int32
}

///|
fn JsonParser::peek(self : JsonParser) -> Int32 {
  if self.pos < self.s.length() {
    self.s.at(self.pos).to_int()
  } else {
    -1
  }
}

///|
fn JsonParser::skip_ws(self : JsonParser) -> Unit {
  while self.pos < self.s.length() {
    match self.s.at(self.pos).to_int() {
      0x20 | 0x09 | 0x0a | 0x0d => self.pos += 1
      _ => break
    }
  }
}

///|
fn JsonParser::expect(self : JsonParser, lit : String) -> Unit raise JsonError {
  for i in 0..<lit.length() {
    if self.pos + i >= self.s.length() || self.s.at(self.pos + i) != lit[i] {
      raise InvalidJson(pos=self.pos)
    }
  }
  self.pos += lit.length()
}

///|
fn JsonParser::value(self : JsonParser, depth : Int32) -> Any raise JsonError {
  if depth > 1000 {
    raise InvalidJson(pos=self.pos)
  }
  self.skip_ws()
  match self.peek() {
    0x7b => {
      self.pos += 1
      let m : Map[String, Any] = Map([])
      self.skip_ws()
      if self.peek() == 0x7d {
        self.pos += 1
        return Object(m)
      }
      for ;; {
        self.skip_ws()
        let key = self.string()
        self.skip_ws()
        self.expect(":")
        m[key] = self.value(depth + 1)
        self.skip_ws()
        match self.peek() {
          0x2c => self.pos += 1
          0x7d => {
            self.pos += 1
            break
          }
          _ => raise InvalidJson(pos=self.pos)
        }
      }
      Object(m)
    }
    0x5b => {
      self.pos += 1
      let xs : Array[Any] = []
      self.skip_ws()
      if self.peek() == 0x5d {
        self.pos += 1
        return Array(xs)
      }
      for ;; {
        xs.push(self.value(depth + 1))
        self.skip_ws()
        match self.peek() {
          0x2c => self.pos += 1
          0x5d => {
            self.pos += 1
            break
          }
          _ => raise InvalidJson(pos=self.pos)
        }
      }
      Array(xs)
    }
    0x22 => String(self.string())
    0x74 => {
      self.expect("true")
      Bool(true)
    }
    0x66 => {
      self.expect("false")
      Bool(false)
    }
    0x6e => {
      self.expect("null")
      Null
    }
    _ => self.number()
  }
}

///|
fn JsonParser::string(self : JsonParser) -> String raise JsonError {
  if self.peek() != 0x22 {
    raise InvalidJson(pos=self.pos)
  }
  self.pos += 1
  let sb = StringBuilder()
  for ;; {
    if self.pos >= self.s.length() {
      raise InvalidJson(pos=self.pos)
    }
    let c = self.s.at(self.pos).to_int()
    self.pos += 1
    if c == 0x22 {
      break
    } else if c == 0x5c {
      let e = self.peek()
      self.pos += 1
      match e {
        0x22 => sb.write_char('"')
        0x5c => sb.write_char('\\')
        0x2f => sb.write_char('/')
        0x62 => sb.write_char('\b')
        0x66 => sb.write_char('\u{0C}')
        0x6e => sb.write_char('\n')
        0x72 => sb.write_char('\r')
        0x74 => sb.write_char('\t')
        0x75 => {
          let mut v = 0
          for _ in 0..<4 {
            let h = self.peek()
            self.pos += 1
            let d = if h >= 0x30 && h <= 0x39 {
              h - 0x30
            } else if h >= 0x61 && h <= 0x66 {
              h - 0x61 + 10
            } else if h >= 0x41 && h <= 0x46 {
              h - 0x41 + 10
            } else {
              raise InvalidJson(pos=self.pos - 1)
            }
            v = v * 16 + d
          }
          // keep code units as-is (lone surrogates allowed, like JS)
          sb.write_char(v.unsafe_to_char())
        }
        _ => raise InvalidJson(pos=self.pos - 1)
      }
    } else if c < 0x20 {
      raise InvalidJson(pos=self.pos - 1)
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
  sb.to_string()
}

///|
fn JsonParser::number(self : JsonParser) -> Any raise JsonError {
  let start = self.pos
  if self.peek() == 0x2d {
    self.pos += 1
  }
  let digits_start = self.pos
  while self.peek() >= 0x30 && self.peek() <= 0x39 {
    self.pos += 1
  }
  if self.pos == digits_start {
    raise InvalidJson(pos=start)
  }
  if self.peek() == 0x2e {
    self.pos += 1
    let f = self.pos
    while self.peek() >= 0x30 && self.peek() <= 0x39 {
      self.pos += 1
    }
    if self.pos == f {
      raise InvalidJson(pos=start)
    }
  }
  if self.peek() == 0x65 || self.peek() == 0x45 {
    self.pos += 1
    if self.peek() == 0x2b || self.peek() == 0x2d {
      self.pos += 1
    }
    let e = self.pos
    while self.peek() >= 0x30 && self.peek() <= 0x39 {
      self.pos += 1
    }
    if self.pos == e {
      raise InvalidJson(pos=start)
    }
  }
  let text = self.s.clamped_view(start~, end=self.pos)
  Number(@string.parse_double(text) catch { _ => raise InvalidJson(pos=start) })
}
