// Byte-level annotation of v1 updates, for protocol inspectors and debugging:
// every byte range of an update is labelled with the field it encodes.

///|
/// What a run of bytes in an update encodes.
pub(all) enum SegmentKind {
  /// Counts and other framing.
  Header
  /// A client id.
  Client
  /// A clock value or length.
  Clock
  /// The info byte of a struct (content kind and flags).
  Info
  /// The left origin ID of an item.
  Origin
  /// The right origin ID of an item.
  RightOrigin
  /// Parent information (root name or parent item ID).
  Parent
  /// A map key (`parentSub`).
  Key
  /// Item content, GC or skip length.
  Content
  /// Delete set entries.
  Deletes
} derive(Eq, Debug)

///|
/// Short machine name of a segment kind.
pub fn SegmentKind::name(self : SegmentKind) -> String {
  match self {
    Header => "header"
    Client => "client"
    Clock => "clock"
    Info => "info"
    Origin => "origin"
    RightOrigin => "right-origin"
    Parent => "parent"
    Key => "key"
    Content => "content"
    Deletes => "delete-set"
  }
}

///|
/// A labelled byte range `[start, end)` of an update.
pub(all) struct Segment {
  start : Int32
  end : Int32
  kind : SegmentKind
  label : String
} derive(Eq, Debug)

///|
fn content_kind_name(info : Int32) -> String {
  match info & BITS5 {
    0 => "GC"
    1 => "Deleted"
    2 => "JSON"
    3 => "Binary"
    4 => "String"
    5 => "Embed"
    6 => "Format"
    7 => "Type"
    8 => "Any"
    9 => "Doc"
    10 => "Skip"
    _ => "unknown"
  }
}

///|
/// Splits a v1 update into labelled byte ranges covering every byte, in
/// order. Raises on malformed input, like `apply_update`.
pub fn annotate_update(
  update : BytesView,
) -> Array[Segment] raise @lib0.DecodeError {
  let dec = @lib0.Decoder(update)
  let segs : Array[Segment] = []
  fn mark(start : Int32, kind : SegmentKind, label : String) -> Unit {
    segs.push({ start, end: dec.pos(), kind, label, })
  }

  let mut p = dec.pos()
  let num_clients = dec.read_var_uint()
  mark(p, Header, "structs from \{num_clients} client(s)")
  for _ in 0..<num_clients {
    p = dec.pos()
    let n = dec.read_var_uint()
    mark(p, Header, "\{n} struct(s) follow")
    p = dec.pos()
    let client = read_client(dec)
    mark(p, Client, "client \{client}")
    p = dec.pos()
    let mut clock = dec.read_var_uint()
    mark(p, Clock, "first clock \{clock}")
    for _ in 0..<n {
      p = dec.pos()
      let info = dec.read_u8()
      let flags : Array[String] = []
      if (info & BIT8) != 0 {
        flags.push("origin")
      }
      if (info & BIT7) != 0 {
        flags.push("right origin")
      }
      if (info & BIT6) != 0 {
        flags.push("key")
      }
      let flag_text = if flags.length() > 0 {
        " + " + flags.join(", ")
      } else {
        ""
      }
      mark(
        p,
        Info,
        "\{content_kind_name(info)} at \{client}:\{clock}\{flag_text}",
      )
      match info & BITS5 {
        0 | 10 => {
          p = dec.pos()
          let len = dec.read_var_uint()
          mark(p, Content, "\{content_kind_name(info)} length \{len}")
          clock += len
        }
        _ => {
          let cant_copy_parent = (info & (BIT7 | BIT8)) == 0
          if (info & BIT8) != 0 {
            p = dec.pos()
            let id = read_id(dec)
            mark(p, Origin, "left origin \{id.client}:\{id.clock}")
          }
          if (info & BIT7) != 0 {
            p = dec.pos()
            let id = read_id(dec)
            mark(p, RightOrigin, "right origin \{id.client}:\{id.clock}")
          }
          if cant_copy_parent {
            p = dec.pos()
            let is_ykey = dec.read_var_uint()
            if is_ykey == 1 {
              let name = dec.read_var_string()
              mark(p, Parent, "parent: root type \"\{name}\"")
            } else {
              let id = read_id(dec)
              mark(
                p,
                Parent,
                "parent: nested type in item \{id.client}:\{id.clock}",
              )
            }
            if (info & BIT6) != 0 {
              p = dec.pos()
              let key = dec.read_var_string()
              mark(p, Key, "map key \"\{key}\"")
            }
          }
          p = dec.pos()
          let content = read_content(dec, info)
          mark(p, Content, describe_content(content))
          clock += content.len()
        }
      }
    }
  }
  p = dec.pos()
  let ds_clients = dec.read_var_uint()
  mark(p, Deletes, "delete set: \{ds_clients} client(s)")
  for _ in 0..<ds_clients {
    p = dec.pos()
    let client = read_client(dec)
    mark(p, Client, "deletions by client \{client}")
    p = dec.pos()
    let n = dec.read_var_uint()
    mark(p, Deletes, "\{n} deleted range(s)")
    for _ in 0..<n {
      p = dec.pos()
      let clock = dec.read_var_uint()
      let len = dec.read_var_uint()
      mark(p, Deletes, "deleted clocks \{clock}..\{clock + len - 1}")
    }
  }
  segs
}
