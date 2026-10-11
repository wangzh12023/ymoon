// Document-free update utilities: merging, diffing and inspecting v1 updates
// without instantiating a document (yjs/src/utils/updates.js).

///|
/// Sequential reader over the structs of an update (`LazyStructReader`).
priv struct LazyStructReader {
  dec : @lib0.Decoder
  filter_skips : Bool
  mut remaining_clients : Int
  mut remaining_structs : Int
  mut client : UInt
  mut clock : Int
  mut curr : Struct?
}

///|
fn LazyStructReader::new_reader(
  dec : @lib0.Decoder,
  filter_skips : Bool,
) -> LazyStructReader raise @lib0.DecodeError {
  let r : LazyStructReader = {
    dec,
    filter_skips,
    remaining_clients: dec.read_var_uint(),
    remaining_structs: 0,
    client: 0,
    clock: 0,
    curr: None,
  }
  r.next() |> ignore
  r
}

///|
fn LazyStructReader::read_one(
  self : LazyStructReader,
) -> Struct? raise @lib0.DecodeError {
  while self.remaining_structs == 0 {
    if self.remaining_clients == 0 {
      return None
    }
    self.remaining_clients -= 1
    self.remaining_structs = self.dec.read_var_uint()
    self.client = read_client(self.dec)
    self.clock = self.dec.read_var_uint()
  }
  self.remaining_structs -= 1
  let s = read_struct(self.dec, self.client, self.clock, None)
  self.clock += s.len()
  Some(s)
}

///|
fn LazyStructReader::next(
  self : LazyStructReader,
) -> Struct? raise @lib0.DecodeError {
  for ;; {
    let s = self.read_one()
    self.curr = s
    match s {
      Some(Skip(_)) if self.filter_skips => continue
      _ => return s
    }
  }
}

///|
/// Accumulates structs grouped per client (`LazyStructWriter`).
priv struct LazyStructWriter {
  mut curr_client : UInt
  mut written : Int
  mut rest : @lib0.Encoder
  client_structs : Array[(Int, Bytes)]
}

///|
fn LazyStructWriter::new_writer() -> LazyStructWriter {
  { curr_client: 0, written: 0, rest: @lib0.Encoder(), client_structs: [], }
}

///|
fn LazyStructWriter::flush(self : LazyStructWriter) -> Unit {
  if self.written > 0 {
    self.client_structs.push((self.written, self.rest.to_bytes()))
    self.rest = @lib0.Encoder()
    self.written = 0
  }
}

///|
fn LazyStructWriter::write(
  self : LazyStructWriter,
  s : Struct,
  offset : Int,
) -> Unit {
  let id = s.id()
  if self.written > 0 && self.curr_client != id.client {
    self.flush()
  }
  if self.written == 0 {
    self.curr_client = id.client
    self.rest.write_var_uint64(id.client.to_uint64())
    self.rest.write_var_uint(id.clock + offset)
  }
  write_struct(self.rest, s, offset)
  self.written += 1
}

///|
fn LazyStructWriter::finish(
  self : LazyStructWriter,
  out : @lib0.Encoder,
) -> Unit {
  self.flush()
  out.write_var_uint(self.client_structs.length())
  for part in self.client_structs {
    out.write_var_uint(part.0)
    out.write_raw(part.1)
  }
}

///|
/// Slices a struct at `diff` (`sliceStruct`).
fn slice_struct(left : Struct, diff : Int) -> Struct {
  match left {
    GC(g) =>
      GC({
        id: { client: g.id.client, clock: g.id.clock + diff, },
        len: g.len - diff,
      })
    Skip(g) =>
      Skip({
        id: { client: g.id.client, clock: g.id.clock + diff, },
        len: g.len - diff,
      })
    Item(item) => {
      let (_, rc) = item.content.split(diff)
      Item(
        Item::new_item(
          { client: item.id.client, clock: item.id.clock + diff, },
          None,
          Some({ client: item.id.client, clock: item.id.clock + diff - 1, }),
          None,
          item.right_origin,
          item.parent,
          item.parent_sub,
          rc,
        ),
      )
    }
  }
}

///|
/// `mergeWith` on detached structs (used while merging updates).
fn struct_merge_with(left : Struct, right : Struct) -> Bool {
  match (left, right) {
    (GC(l), GC(r)) | (Skip(l), Skip(r)) => {
      l.len += r.len
      true
    }
    (Item(l), Item(r)) =>
      // detached items: right/left pointers are unset, so check origins only
      if l.content.ref_number() == r.content.ref_number() &&
        id_opt_eq(r.origin, Some(l.last_id())) &&
        id_opt_eq(l.right_origin, r.right_origin) &&
        l.id.client == r.id.client &&
        l.id.clock + l.len == r.id.clock &&
        l.deleted() == r.deleted() &&
        l.redone is None &&
        r.redone is None {
        match l.content.try_merge(r.content) {
          Some(m) => {
            l.content = m
            l.len += r.len
            true
          }
          None => false
        }
      } else {
        false
      }
    _ => false
  }
}

///|
fn is_skip(s : Struct) -> Bool {
  s is Skip(_)
}

///|
/// Merges several v1 updates into one without a document (`Y.mergeUpdates`).
pub fn merge_updates(
  updates : ArrayView[Bytes],
) -> Bytes raise @lib0.DecodeError {
  if updates.length() == 1 {
    return updates[0]
  }
  let update_decoders = updates.map(u => @lib0.Decoder(u))
  let mut readers = update_decoders.map(d => {
    LazyStructReader::new_reader(d, true)
  })
  let mut curr_write : (Struct, Int)? = None
  let writer = LazyStructWriter::new_writer()
  for ;; {
    readers = readers.filter(r => r.curr is Some(_))
    readers.sort_by((r1, r2) => {
      let s1 = r1.curr.unwrap()
      let s2 = r2.curr.unwrap()
      let id1 = s1.id()
      let id2 = s2.id()
      if id1.client == id2.client {
        let clock_diff = id1.clock - id2.clock
        if clock_diff == 0 {
          if is_skip(s1) == is_skip(s2) {
            0
          } else if is_skip(s1) {
            1
          } else {
            -1
          }
        } else {
          clock_diff
        }
      } else {
        // higher client ids first
        id2.client.compare(id1.client)
      }
    })
    if readers.length() == 0 {
      break
    }
    let curr_decoder = readers[0]
    let first_client = curr_decoder.curr.unwrap().id().client
    match curr_write {
      Some((cw, cw_offset)) => {
        let mut curr = curr_decoder.curr
        let mut iterated = false
        // skip structs that are already covered
        while curr is Some(c) &&
              c.end_clock() <= cw.end_clock() &&
              c.id().client >= cw.id().client {
          curr = curr_decoder.next()
          iterated = true
        }
        guard curr is Some(c) else { continue }
        if c.id().client != first_client ||
          (iterated && c.id().clock > cw.end_clock()) {
          continue
        }
        if first_client != cw.id().client {
          writer.write(cw, cw_offset)
          curr_write = Some((c, 0))
          curr_decoder.next() |> ignore
        } else if cw.end_clock() < c.id().clock {
          // there is a gap: extend a Skip or write a new one
          match cw {
            Skip(g) => g.len = c.end_clock() - g.id.clock
            _ => {
              writer.write(cw, cw_offset)
              let diff = c.id().clock - cw.end_clock()
              curr_write = Some(
                (
                  Skip({
                    id: { client: first_client, clock: cw.end_clock(), },
                    len: diff,
                  }),
                  0,
                ),
              )
            }
          }
        } else {
          let diff = cw.end_clock() - c.id().clock
          let mut c = c
          if diff > 0 {
            match cw {
              Skip(g) => g.len -= diff
              _ => c = slice_struct(c, diff)
            }
          }
          if !struct_merge_with(cw, c) {
            writer.write(cw, cw_offset)
            curr_write = Some((c, 0))
            curr_decoder.next() |> ignore
          }
        }
      }
      None => {
        curr_write = Some((curr_decoder.curr.unwrap(), 0))
        curr_decoder.next() |> ignore
      }
    }
    // write directly adjacent structs of the same client
    for ;; {
      guard curr_write is Some((cw, cw_offset)) else { break }
      guard curr_decoder.curr is Some(next) else { break }
      if next.id().client == first_client &&
        next.id().clock == cw.end_clock() &&
        !is_skip(next) {
        writer.write(cw, cw_offset)
        curr_write = Some((next, 0))
        curr_decoder.next() |> ignore
      } else {
        break
      }
    }
  }
  match curr_write {
    Some((cw, off)) => writer.write(cw, off)
    None => ()
  }
  let out = @lib0.Encoder()
  writer.finish(out)
  let dss = update_decoders.map(d => DeleteSet::read(d))
  DeleteSet::merge_all(dss).write(out)
  out.to_bytes()
}

///|
/// Returns the part of `update` that a peer with state vector `sv` is missing
/// (`Y.diffUpdate`).
pub fn diff_update(
  update : BytesView,
  sv : BytesView,
) -> Bytes raise @lib0.DecodeError {
  let state = StateVector::decode(sv)
  let writer = LazyStructWriter::new_writer()
  let dec = @lib0.Decoder(update)
  let reader = LazyStructReader::new_reader(dec, false)
  while reader.curr is Some(curr) {
    let curr_client = curr.id().client
    let sv_clock = state.get(curr_client)
    if is_skip(curr) {
      reader.next() |> ignore
      continue
    }
    if curr.end_clock() > sv_clock {
      writer.write(curr, @cmp.maximum(sv_clock - curr.id().clock, 0))
      reader.next() |> ignore
      while reader.curr is Some(c) && c.id().client == curr_client {
        writer.write(c, 0)
        reader.next() |> ignore
      }
    } else {
      // read until something new comes up
      while reader.curr is Some(c) &&
            c.id().client == curr_client &&
            c.end_clock() <= sv_clock {
        reader.next() |> ignore
      }
    }
  }
  let out = @lib0.Encoder()
  writer.finish(out)
  DeleteSet::read(dec).write(out)
  out.to_bytes()
}

///|
/// Computes the state vector an update would produce on an empty document
/// (`Y.encodeStateVectorFromUpdate`).
pub fn encode_state_vector_from_update(
  update : BytesView,
) -> Bytes raise @lib0.DecodeError {
  let reader = LazyStructReader::new_reader(@lib0.Decoder(update), false)
  let pairs : Array[(UInt, Int)] = []
  match reader.curr {
    None => ()
    Some(first) => {
      let mut curr_client = first.id().client
      let mut stop_counting = first.id().clock != 0
      let mut curr_clock = if stop_counting { 0 } else { first.end_clock() }
      let mut cur = reader.next()
      while cur is Some(c) {
        if curr_client != c.id().client {
          if curr_clock != 0 {
            pairs.push((curr_client, curr_clock))
          }
          curr_client = c.id().client
          curr_clock = 0
          stop_counting = c.id().clock != 0
        }
        if is_skip(c) {
          stop_counting = true
        }
        if !stop_counting {
          curr_clock = c.end_clock()
        }
        cur = reader.next()
      }
      if curr_clock != 0 {
        pairs.push((curr_client, curr_clock))
      }
    }
  }
  let enc = @lib0.Encoder()
  enc.write_var_uint(pairs.length())
  for p in pairs {
    enc.write_var_uint64(p.0.to_uint64())
    enc.write_var_uint(p.1)
  }
  enc.to_bytes()
}

///|
/// A struct as seen in a decoded update (for inspection tools).
pub(all) enum DecodedStruct {
  /// A garbage-collected range.
  GC(client~ : UInt, clock~ : Int, len~ : Int)
  /// A gap of unknown structs.
  Skip(client~ : UInt, clock~ : Int, len~ : Int)
  /// An item.
  Item(
    client~ : UInt,
    clock~ : Int,
    len~ : Int,
    origin~ : ID?,
    right_origin~ : ID?,
    parent~ : String?,
    parent_sub~ : String?,
    content~ : String
  )
} derive(Debug, Eq)

///|
/// Decodes an update into a list of structs plus its delete set
/// (`Y.decodeUpdate`), for logging and inspection.
pub fn decode_update(
  update : BytesView,
) -> (Array[DecodedStruct], DeleteSet) raise @lib0.DecodeError {
  let dec = @lib0.Decoder(update)
  let reader = LazyStructReader::new_reader(dec, false)
  let out : Array[DecodedStruct] = []
  while reader.curr is Some(s) {
    let id = s.id()
    out.push(
      match s {
        GC(g) => GC(client=id.client, clock=id.clock, len=g.len)
        Skip(g) => Skip(client=id.client, clock=id.clock, len=g.len)
        Item(item) =>
          Item(
            client=id.client,
            clock=id.clock,
            len=item.len,
            origin=item.origin,
            right_origin=item.right_origin,
            parent=match item.parent {
              PendingRoot(name) => Some(name)
              PendingId(pid) => Some("#\{pid.client}:\{pid.clock}")
              _ => None
            },
            parent_sub=item.parent_sub,
            content=describe_content(item.content),
          )
      },
    )
    reader.next() |> ignore
  }
  let ds = DeleteSet::read(dec)
  (out, ds)
}

///|
fn describe_content(c : Content) -> String {
  match c {
    Deleted(n) => "Deleted(\{n})"
    JSON(xs) => "JSON(\{xs.length()})"
    Binary(b) => "Binary(\{b.length()} bytes)"
    String(s) => "String(\{s.escape()})"
    Embed(j) => "Embed(\{j})"
    Format(k, v) => "Format(\{k}=\{v})"
    Type(b) =>
      match b.kind {
        Some(k) => "Type(\{Repr(k)})"
        None => "Type(?)"
      }
    Any(xs) => "Any(\{xs.length()})"
    Doc(guid, _) => "Doc(\{guid})"
  }
}
