// Byte-level encoder compatible with lib0/encoding (https://github.com/dmonad/lib0).
// Every write here mirrors the JavaScript reference bit for bit, because Yjs
// peers compare updates byte-wise.

///|
/// An append-only binary writer producing lib0-compatible output.
pub struct Encoder {
  priv buf : @buffer.Buffer
}

///|
/// Creates an empty encoder.
pub fn Encoder::Encoder(size_hint? : Int = 64) -> Encoder {
  { buf: @buffer.Buffer(size_hint~), }
}

///|
/// Number of bytes written so far.
pub fn Encoder::length(self : Encoder) -> Int {
  self.buf.length()
}

///|
/// Returns a copy of everything written so far.
pub fn Encoder::to_bytes(self : Encoder) -> Bytes {
  self.buf.to_bytes()
}

///|
/// Writes one byte (`writeUint8`). Only the low 8 bits of `b` are used.
pub fn Encoder::write_u8(self : Encoder, b : Int) -> Unit {
  self.buf.write_byte((b & 0xff).to_byte())
}

///|
/// Writes raw bytes without a length prefix (`writeUint8Array`).
pub fn Encoder::write_raw(self : Encoder, data : BytesView) -> Unit {
  self.buf.write_bytes(data)
}

///|
/// Writes an unsigned LEB128-style variable length integer (`writeVarUint`).
///
/// lib0 encodes JavaScript numbers up to 2^53; `UInt64` covers that range.
pub fn Encoder::write_var_uint64(self : Encoder, num : UInt64) -> Unit {
  let mut n = num
  while n > 0x7fUL {
    self.buf.write_byte((0x80UL | (n & 0x7fUL)).to_byte())
    n = n >> 7
  }
  self.buf.write_byte((n & 0x7fUL).to_byte())
}

///|
/// Writes a non-negative `Int` as a variable length unsigned integer.
///
/// Negative values are a programming error: Yjs never encodes them with
/// `writeVarUint`.
pub fn Encoder::write_var_uint(self : Encoder, num : Int) -> Unit {
  guard num >= 0 else { abort("write_var_uint: negative value \{num}") }
  self.write_var_uint64(num.to_uint64())
}

///|
/// Writes a variable length signed integer (`writeVarInt`).
///
/// Bit 7 of the first byte carries the sign, bits 0-5 the lowest 6 bits of the
/// magnitude. lib0 also distinguishes `-0`; pass `negative_zero=true` to
/// reproduce that encoding.
pub fn Encoder::write_var_int64(
  self : Encoder,
  num : Int64,
  negative_zero? : Bool = false,
) -> Unit {
  let is_negative = num < 0L || (num == 0L && negative_zero)
  // magnitude as unsigned to survive Int64::min_value
  let mut mag = if num < 0L {
    (-num).reinterpret_as_uint64()
  } else {
    num.reinterpret_as_uint64()
  }
  let first = (if mag > 0x3fUL { 0x80 } else { 0 }) |
    (if is_negative { 0x40 } else { 0 }) |
    (mag & 0x3fUL).to_int()
  self.write_u8(first)
  mag = mag >> 6
  while mag > 0UL {
    let cont = if mag > 0x7fUL { 0x80 } else { 0 }
    self.write_u8(cont | (mag & 0x7fUL).to_int())
    mag = mag >> 7
  }
}

///|
/// Writes a variable length signed `Int`.
pub fn Encoder::write_var_int(self : Encoder, num : Int) -> Unit {
  self.write_var_int64(num.to_int64())
}

///|
/// Writes a UTF-8 string prefixed with its byte length (`writeVarString`).
///
/// Unpaired surrogates are replaced by U+FFFD exactly like `TextEncoder`.
pub fn Encoder::write_var_string(self : Encoder, s : StringView) -> Unit {
  let bytes = @utf8.encode(utf16_well_formed(s))
  self.write_var_uint(bytes.length())
  self.buf.write_bytes(bytes)
}

///|
/// Writes a byte array prefixed with its length (`writeVarUint8Array`).
pub fn Encoder::write_var_bytes(self : Encoder, data : BytesView) -> Unit {
  self.write_var_uint(data.length())
  self.buf.write_bytes(data)
}

///|
/// Writes a big-endian IEEE-754 single precision float (`writeFloat32`).
pub fn Encoder::write_float32(self : Encoder, f : Float) -> Unit {
  self.buf.write_float_be(f)
}

///|
/// Writes a big-endian IEEE-754 double precision float (`writeFloat64`).
pub fn Encoder::write_float64(self : Encoder, d : Double) -> Unit {
  // JavaScript engines canonicalise NaN to 0x7ff8000000000000 when writing
  // through a DataView; reproduce that instead of leaking the payload bits.
  if d != d {
    self.buf.write_uint64_be(0x7ff8000000000000UL)
  } else {
    self.buf.write_double_be(d)
  }
}

///|
/// Writes a big-endian signed 64 bit integer (`writeBigInt64`).
pub fn Encoder::write_big_int64(self : Encoder, n : Int64) -> Unit {
  self.buf.write_int64_be(n)
}

///|
/// Replaces lone UTF-16 surrogates with U+FFFD, matching `TextEncoder`.
/// Returns the input unchanged (no copy) when it is already well formed.
pub fn utf16_well_formed(s : StringView) -> StringView {
  let n = s.length()
  let mut i = 0
  let mut ok = true
  while i < n {
    let c = s.at(i).to_int()
    if c >= 0xD800 && c <= 0xDBFF {
      if i + 1 < n {
        let d = s.at(i + 1).to_int()
        if d >= 0xDC00 && d <= 0xDFFF {
          i += 2
          continue
        }
      }
      ok = false
      break
    } else if c >= 0xDC00 && c <= 0xDFFF {
      ok = false
      break
    }
    i += 1
  }
  if ok {
    return s
  }
  let sb = StringBuilder(size_hint=n)
  let mut j = 0
  while j < n {
    let c = s.at(j).to_int()
    if c >= 0xD800 && c <= 0xDBFF && j + 1 < n {
      let d = s.at(j + 1).to_int()
      if d >= 0xDC00 && d <= 0xDFFF {
        let cp = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)
        sb.write_char(cp.unsafe_to_char())
        j += 2
        continue
      }
    }
    if c >= 0xD800 && c <= 0xDFFF {
      sb.write_char('\u{FFFD}')
    } else {
      sb.write_char(c.unsafe_to_char())
    }
    j += 1
  }
  sb.to_string()
}
