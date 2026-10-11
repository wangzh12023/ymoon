// Byte-level decoder compatible with lib0/decoding.

///|
/// Errors raised while decoding lib0 / Yjs binary data.
pub(all) suberror DecodeError {
  /// The input ended before the value was complete.
  UnexpectedEnd(pos~ : Int)
  /// A variable length integer does not fit in 53 bits (JavaScript's safe
  /// integer range), or does not fit the requested MoonBit integer type.
  IntegerOutOfRange(pos~ : Int)
  /// A string payload is not valid UTF-8.
  InvalidUtf8(pos~ : Int)
  /// A tag byte or enum discriminant has no meaning in this position.
  UnknownTag(pos~ : Int, tag~ : Int)
  /// Structural error in an otherwise well formed byte stream.
  Malformed(pos~ : Int, reason~ : String)
} derive(Debug, Eq)

///|
/// A cursor over a byte slice.
pub struct Decoder {
  priv data : BytesView
  priv mut pos : Int
}

///|
/// Creates a decoder positioned at the beginning of `data`.
pub fn Decoder::Decoder(data : BytesView) -> Decoder {
  { data, pos: 0, }
}

///|
/// Current read offset.
pub fn Decoder::pos(self : Decoder) -> Int {
  self.pos
}

///|
/// Total number of bytes in the underlying slice.
pub fn Decoder::length(self : Decoder) -> Int {
  self.data.length()
}

///|
/// Whether unread bytes remain (`hasContent`).
pub fn Decoder::has_content(self : Decoder) -> Bool {
  self.pos < self.data.length()
}

///|
/// Reads one byte (`readUint8`).
pub fn Decoder::read_u8(self : Decoder) -> Int raise DecodeError {
  guard self.pos < self.data.length() else { raise UnexpectedEnd(pos=self.pos) }
  let b = self.data[self.pos].to_int()
  self.pos += 1
  b
}

///|
/// Reads `len` raw bytes (`readUint8Array`).
pub fn Decoder::read_raw(
  self : Decoder,
  len : Int,
) -> BytesView raise DecodeError {
  guard len >= 0 && self.pos + len <= self.data.length() else {
    raise UnexpectedEnd(pos=self.pos)
  }
  let v = self.data[self.pos:self.pos + len]
  self.pos += len
  v
}

///|
/// Reads an unsigned variable length integer (`readVarUint`) as `UInt64`.
///
/// Like lib0, values above 2^53 - 1 are rejected.
pub fn Decoder::read_var_uint64(self : Decoder) -> UInt64 raise DecodeError {
  let start = self.pos
  let mut num = 0UL
  let mut shift = 0
  for ;; {
    guard self.pos < self.data.length() else { raise UnexpectedEnd(pos=start) }
    let r = self.data[self.pos].to_uint64()
    self.pos += 1
    if shift > 49 && (r & 0x7fUL) >> (53 - shift) != 0UL {
      raise IntegerOutOfRange(pos=start)
    }
    num = num | ((r & 0x7fUL) << shift)
    shift += 7
    if r < 0x80UL {
      return num
    }
    if shift > 53 {
      raise IntegerOutOfRange(pos=start)
    }
  }
}

///|
/// Reads an unsigned variable length integer that must fit in a
/// non-negative `Int` (used for lengths, clocks and offsets).
pub fn Decoder::read_var_uint(self : Decoder) -> Int raise DecodeError {
  let start = self.pos
  let n = self.read_var_uint64()
  guard n <= 0x7fffffffUL else { raise IntegerOutOfRange(pos=start) }
  n.to_int()
}

///|
/// Reads a variable length signed integer (`readVarInt`).
///
/// Returns the value and whether it was an explicitly negative zero.
pub fn Decoder::read_var_int64_ext(
  self : Decoder,
) -> (Int64, Bool) raise DecodeError {
  let start = self.pos
  let first = self.read_u8()
  let negative = (first & 0x40) != 0
  let mut num = (first & 0x3f).to_uint64()
  let mut shift = 6
  if (first & 0x80) != 0 {
    for ;; {
      guard self.pos < self.data.length() else {
        raise UnexpectedEnd(pos=start)
      }
      let r = self.data[self.pos].to_uint64()
      self.pos += 1
      if shift > 49 && (r & 0x7fUL) >> (53 - shift) != 0UL {
        raise IntegerOutOfRange(pos=start)
      }
      num = num | ((r & 0x7fUL) << shift)
      shift += 7
      if r < 0x80UL {
        break
      }
      if shift > 53 {
        raise IntegerOutOfRange(pos=start)
      }
    }
  }
  let v = num.reinterpret_as_int64()
  if negative {
    (-v, v == 0L)
  } else {
    (v, false)
  }
}

///|
/// Reads a variable length signed integer (`readVarInt`) as `Int64`.
pub fn Decoder::read_var_int64(self : Decoder) -> Int64 raise DecodeError {
  self.read_var_int64_ext().0
}

///|
/// Reads a UTF-8 string prefixed with its byte length (`readVarString`).
pub fn Decoder::read_var_string(self : Decoder) -> String raise DecodeError {
  let start = self.pos
  let len = self.read_var_uint()
  let bytes = self.read_raw(len)
  @utf8.decode(bytes, ignore_bom=true) catch {
    _ => raise InvalidUtf8(pos=start)
  }
}

///|
/// Reads a byte array prefixed with its length (`readVarUint8Array`).
pub fn Decoder::read_var_bytes(self : Decoder) -> Bytes raise DecodeError {
  let len = self.read_var_uint()
  self.read_raw(len).to_owned()
}

///|
/// Reads a big-endian IEEE-754 single precision float (`readFloat32`).
pub fn Decoder::read_float32(self : Decoder) -> Float raise DecodeError {
  let b = self.read_raw(4)
  let bits = (b[0].to_uint() << 24) |
    (b[1].to_uint() << 16) |
    (b[2].to_uint() << 8) |
    b[3].to_uint()
  Float::reinterpret_from_uint(bits)
}

///|
/// Reads a big-endian IEEE-754 double precision float (`readFloat64`).
pub fn Decoder::read_float64(self : Decoder) -> Double raise DecodeError {
  self.read_big_int64().reinterpret_as_double()
}

///|
/// Reads a big-endian signed 64 bit integer (`readBigInt64`).
pub fn Decoder::read_big_int64(self : Decoder) -> Int64 raise DecodeError {
  let b = self.read_raw(8)
  let mut v = 0UL
  for i in 0..<8 {
    v = (v << 8) | b[i].to_uint64()
  }
  v.reinterpret_as_int64()
}
