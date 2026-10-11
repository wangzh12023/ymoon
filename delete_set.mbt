// Delete sets and state vectors, mirroring yjs/src/utils/DeleteSet.js and the
// state-vector helpers of yjs/src/utils/encoding.js.

///|
/// A contiguous range of deleted clocks of one client.
pub(all) struct DeleteItem {
  clock : Int
  len : Int
} derive(Eq, Debug)

///|
/// Deleted clock ranges grouped by client.
pub struct DeleteSet {
  priv clients : Map[UInt, Array[DeleteItem]]
}

///|
/// Creates an empty delete set.
pub fn DeleteSet::DeleteSet() -> DeleteSet {
  { clients: Map([]), }
}

///|
/// Whether the delete set contains no ranges.
pub fn DeleteSet::is_empty(self : DeleteSet) -> Bool {
  self.clients.is_empty()
}

///|
/// Adds a range (`addToDeleteSet`). Call `sort_and_merge` afterwards to
/// normalise.
pub fn DeleteSet::add(
  self : DeleteSet,
  client : UInt,
  clock : Int,
  len : Int,
) -> Unit {
  match self.clients.get(client) {
    Some(items) => items.push({ clock, len, })
    None => self.clients[client] = [{ clock, len, }]
  }
}

///|
/// The ranges of `client` (sorted after `sort_and_merge`).
pub fn DeleteSet::ranges(self : DeleteSet, client : UInt) -> Array[DeleteItem] {
  match self.clients.get(client) {
    Some(items) => items
    None => []
  }
}

///|
/// Clients with at least one range, in insertion order.
pub fn DeleteSet::clients(self : DeleteSet) -> Array[UInt] {
  self.clients.keys().collect()
}

///|
/// Sorts each client's ranges and merges adjacent / overlapping ones
/// (`sortAndMergeDeleteSet`).
pub fn DeleteSet::sort_and_merge(self : DeleteSet) -> Unit {
  for _, dels in self.clients {
    dels.sort_by((a, b) => a.clock.compare(b.clock))
    let mut j = 1
    for i in 1..<dels.length() {
      let left = dels[j - 1]
      let right = dels[i]
      if left.clock + left.len >= right.clock {
        let merged_len = @cmp.maximum(
          left.len,
          right.clock + right.len - left.clock,
        )
        dels[j - 1] = { clock: left.clock, len: merged_len, }
      } else {
        if j < i {
          dels[j] = right
        }
        j += 1
      }
    }
    if dels.length() > 0 {
      dels.truncate(j)
    }
  }
}

///|
/// Whether `id` is covered by the (sorted) delete set (`isDeleted`).
///
/// The lookup runs `@verified.find_range`, whose correctness (result covers
/// the clock, `None` means no range does, no overflow) is machine-checked
/// with `moon prove`. Its precondition is established at runtime by the
/// proved-sound `@verified.check_ranges`; unnormalised sets fall back to a
/// linear scan.
pub fn DeleteSet::contains(self : DeleteSet, id : ID) -> Bool {
  match self.clients.get(id.client) {
    None => false
    Some(dis) => {
      let starts = FixedArray::makei(dis.length(), i => dis[i].clock)
      let lens = FixedArray::makei(dis.length(), i => dis[i].len)
      if @verified.check_ranges(starts, lens) {
        @verified.find_range(starts, lens, id.clock) is Some(_)
      } else {
        dis.iter().any(d => d.clock <= id.clock && id.clock - d.clock < d.len)
      }
    }
  }
}

///|
/// Merges several delete sets into a new, normalised one (`mergeDeleteSets`).
pub fn DeleteSet::merge_all(dss : ArrayView[DeleteSet]) -> DeleteSet {
  let merged = DeleteSet()
  for i, ds in dss {
    for client, dels_left in ds.clients {
      if !merged.clients.contains(client) {
        let dels = dels_left.copy()
        for k in (i + 1)..<dss.length() {
          match dss[k].clients.get(client) {
            Some(more) => dels.append(more)
            None => ()
          }
        }
        merged.clients[client] = dels
      }
    }
  }
  merged.sort_and_merge()
  merged
}

///|
/// Builds the delete set of everything deleted in a store
/// (`createDeleteSetFromStructStore`).
fn DeleteSet::from_store(ss : StructStore) -> DeleteSet {
  let ds = DeleteSet()
  for client, structs in ss.clients {
    let items : Array[DeleteItem] = []
    let mut i = 0
    while i < structs.length() {
      let s = structs[i]
      if s.deleted() {
        let clock = s.id().clock
        let mut len = s.len()
        while i + 1 < structs.length() && structs[i + 1].deleted() {
          i += 1
          len += structs[i].len()
        }
        items.push({ clock, len, })
      }
      i += 1
    }
    if items.length() > 0 {
      ds.clients[client] = items
    }
  }
  ds
}

///|
/// Clients sorted by descending id, the deterministic order Yjs uses when
/// writing.
fn sorted_clients_desc(keys : Iter[UInt]) -> Array[UInt] {
  let ks = keys.collect()
  ks.sort_by((a, b) => b.compare(a))
  ks
}

///|
/// Writes a delete set (`writeDeleteSet`, v1 encoding).
pub fn DeleteSet::write(self : DeleteSet, enc : @lib0.Encoder) -> Unit {
  enc.write_var_uint(self.clients.length())
  for client in sorted_clients_desc(self.clients.keys()) {
    let items = self.clients.get(client).unwrap()
    enc.write_var_uint64(client.to_uint64())
    enc.write_var_uint(items.length())
    for item in items {
      enc.write_var_uint(item.clock)
      enc.write_var_uint(item.len)
    }
  }
}

///|
/// Reads a delete set (`readDeleteSet`, v1 encoding).
pub fn DeleteSet::read(
  dec : @lib0.Decoder,
) -> DeleteSet raise @lib0.DecodeError {
  let ds = DeleteSet()
  let num_clients = dec.read_var_uint()
  for _ in 0..<num_clients {
    let client = read_client(dec)
    let n = dec.read_var_uint()
    if n > 0 {
      let items : Array[DeleteItem] = match ds.clients.get(client) {
        Some(items) => items
        None => {
          let items = []
          ds.clients[client] = items
          items
        }
      }
      for _ in 0..<n {
        let clock = dec.read_var_uint()
        let len = dec.read_var_uint()
        items.push({ clock, len, })
      }
    }
  }
  ds
}

///|
/// Reads a client id, which must fit in 32 bits.
fn read_client(dec : @lib0.Decoder) -> UInt raise @lib0.DecodeError {
  let pos = dec.pos()
  let c = dec.read_var_uint64()
  guard c <= 0xffffffffUL else { raise IntegerOutOfRange(pos~) }
  c.to_uint()
}

///|
/// Highest known clock (exclusive) per client.
pub struct StateVector {
  priv clients : Map[UInt, Int]
}

///|
/// Creates an empty state vector.
pub fn StateVector::StateVector() -> StateVector {
  { clients: Map([]), }
}

///|
/// The clock known for `client` (0 if unknown).
pub fn StateVector::get(self : StateVector, client : UInt) -> Int {
  self.clients.get(client).unwrap_or(0)
}

///|
/// Sets the clock of `client`.
pub fn StateVector::set(self : StateVector, client : UInt, clock : Int) -> Unit {
  self.clients[client] = clock
}

///|
/// Whether the vector mentions `client`.
pub fn StateVector::contains(self : StateVector, client : UInt) -> Bool {
  self.clients.contains(client)
}

///|
/// Number of clients in the vector.
pub fn StateVector::length(self : StateVector) -> Int {
  self.clients.length()
}

///|
/// `(client, clock)` pairs, sorted by descending client id.
pub fn StateVector::entries(self : StateVector) -> Array[(UInt, Int)] {
  sorted_clients_desc(self.clients.keys()).map(c => (c, self.clients[c]))
}

///|
/// Encodes the vector (`encodeStateVector`).
pub fn StateVector::encode(self : StateVector) -> Bytes {
  let enc = @lib0.Encoder()
  self.write(enc)
  enc.to_bytes()
}

///|
fn StateVector::write(self : StateVector, enc : @lib0.Encoder) -> Unit {
  enc.write_var_uint(self.clients.length())
  for client in sorted_clients_desc(self.clients.keys()) {
    enc.write_var_uint64(client.to_uint64())
    enc.write_var_uint(self.clients[client])
  }
}

///|
/// Decodes a vector produced by `encodeStateVector`.
pub fn StateVector::decode(
  data : BytesView,
) -> StateVector raise @lib0.DecodeError {
  let dec = @lib0.Decoder(data)
  let sv = StateVector()
  let n = dec.read_var_uint()
  for _ in 0..<n {
    let client = read_client(dec)
    let clock = dec.read_var_uint()
    sv.clients[client] = clock
  }
  sv
}
