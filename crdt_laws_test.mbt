// Property-based tests of the CRDT laws, run on all backends.
//
// For random edit scripts executed by several peers we check:
//   * convergence: after exchanging all updates every peer has the same state
//   * commutativity: applying updates in any order yields the same document
//   * idempotence: applying an update twice changes nothing
//   * merge_updates == applying the parts one by one

///|
/// One random editing step.
priv enum Edit {
  Insert(peer~ : Int, pos~ : Int, text~ : String)
  Delete(peer~ : Int, pos~ : Int, len~ : Int)
  Format(peer~ : Int, pos~ : Int, len~ : Int, bold~ : Bool)
  MapSet(peer~ : Int, key~ : Int, value~ : Int)
  ArrayPush(peer~ : Int, value~ : Int)
  Sync(from~ : Int, to~ : Int)
} derive(Debug)

///|
fn gen_script(seeds : Array[UInt]) -> Array[Edit] {
  // No astral characters here: a concurrent insert that lands inside a
  // remote surrogate pair makes yjs itself diverge (the split pair becomes
  // U+FFFD on some peers only, yjs issue #248). ymoon reproduces that
  // behaviour exactly (see regression_test.mbt and the differential traces,
  // which do include emoji); convergence holds for surrogate-free text.
  let alphabet = ["a", "b", "xy", "中", "é", "ß", " ", "\n"]
  seeds.map(s => {
    // keep the seed non-negative (abs of Int min value overflows)
    let s = (s >> 1).reinterpret_as_int()
    let peer = s % 3
    let k = s / 3 % 10
    let a = s / 30
    match k {
      0 | 1 | 2 =>
        Insert(peer~, pos=a % 1000, text=alphabet[a % alphabet.length()])
      3 | 4 => Delete(peer~, pos=a % 1000, len=1 + a % 3)
      5 => Format(peer~, pos=a % 1000, len=1 + a % 4, bold=a % 2 == 0)
      6 => MapSet(peer~, key=a % 4, value=a % 100)
      7 => ArrayPush(peer~, value=a % 100)
      _ => Sync(from=peer, to=(peer + 1 + a % 2) % 3)
    }
  })
}

///|
/// Index that does not split a surrogate pair.
fn safe_pos(s : String, pos : Int) -> Int {
  let p = if s.length() == 0 { 0 } else { pos % (s.length() + 1) }
  if p > 0 && p < s.length() {
    let c = s[p - 1].to_int()
    if c >= 0xD800 && c <= 0xDBFF {
      return p - 1
    }
  }
  p
}

///|
fn run_edit(docs : Array[@ymoon.Doc], e : Edit) -> Unit raise {
  match e {
    Insert(peer~, pos~, text~) => {
      let t = docs[peer].get_text("t")
      t.insert(safe_pos(t.to_string(), pos), text)
    }
    Delete(peer~, pos~, len~) => {
      let t = docs[peer].get_text("t")
      let s = t.to_string()
      if s.length() > 0 {
        let p = safe_pos(s, pos % s.length())
        let mut end = safe_pos(s, @cmp.minimum(s.length(), p + len))
        if end <= p {
          end = @cmp.minimum(s.length(), p + 2)
        }
        t.delete(p, end - p)
      }
    }
    Format(peer~, pos~, len~, bold~) => {
      let t = docs[peer].get_text("t")
      let s = t.to_string()
      if s.length() > 0 {
        let p = safe_pos(s, pos % s.length())
        let l = @cmp.minimum(len, s.length() - p)
        let v : @lib0.Any = if bold { Bool(true) } else { Null }
        t.format(p, l, { "bold": v })
      }
    }
    MapSet(peer~, key~, value~) =>
      docs[peer].get_map("m").set("k\{key}", @ymoon.Value::int(value))
    ArrayPush(peer~, value~) =>
      docs[peer].get_array("a").push([@ymoon.Value::int(value)])
    Sync(from~, to~) => {
      let u = docs[from].encode_state_as_update(target=docs[to].state_vector())
      docs[to].apply_update(u)
    }
  }
}

///|
fn snapshot(d : @ymoon.Doc) -> String {
  let delta = @ymoon.delta_to_json(d.get_text("t").to_delta()).stringify()
  // map key order reflects local insertion order (as in Yjs), so compare the
  // entries sorted by key
  let entries = d
    .get_map("m")
    .entries()
    .map(e => "\{e.0}=\{e.1.to_json().stringify()}")
  entries.sort_by((a, b) => a.lexical_compare(b))
  let a = d.get_array("a").to_json().stringify()
  "\{delta}|\{entries.join(",")}|\{a}"
}

///|
fn full_sync(docs : Array[@ymoon.Doc]) -> Unit raise {
  for i in 0..<docs.length() {
    for j in 0..<docs.length() {
      if i != j {
        docs[j].apply_update(
          docs[i].encode_state_as_update(target=docs[j].state_vector()),
        )
      }
    }
  }
}

///|
test "property: peers converge after exchanging updates" {
  @quickcheck.check(
    (seeds : Array[UInt]) => {
      let docs = [
        @ymoon.Doc(client_id=1),
        @ymoon.Doc(client_id=2),
        @ymoon.Doc(client_id=3),
      ]
      try {
        for e in gen_script(seeds) {
          run_edit(docs, e)
        }
        full_sync(docs)
        let s0 = snapshot(docs[0])
        snapshot(docs[1]) == s0 && snapshot(docs[2]) == s0
      } catch {
        _ => false
      }
    },
    count=200,
  )
}

///|
test "property: update application commutes and is idempotent" {
  @quickcheck.check(
    (seeds : Array[UInt]) => {
      let docs = [
        @ymoon.Doc(client_id=1),
        @ymoon.Doc(client_id=2),
        @ymoon.Doc(client_id=3),
      ]
      try {
        // record every peer's own updates
        let updates : Array[Bytes] = []
        for d in docs {
          d.on_update((u, origin) => if origin == "" { updates.push(u) })
        }
        for e in gen_script(seeds) {
          match e {
            Sync(..) => () // keep peers independent
            _ => run_edit(docs, e)
          }
        }
        // forward order, reverse order, and everything twice
        let fwd = @ymoon.Doc(client_id=9)
        for u in updates {
          fwd.apply_update(u)
        }
        let rev = @ymoon.Doc(client_id=9)
        for i = updates.length() - 1; i >= 0; i = i - 1 {
          rev.apply_update(updates[i])
        }
        let twice = @ymoon.Doc(client_id=9)
        for u in updates {
          twice.apply_update(u)
          twice.apply_update(u)
        }
        let merged = @ymoon.Doc(client_id=9)
        if updates.length() > 0 {
          merged.apply_update(@ymoon.merge_updates(updates))
        }
        let s = snapshot(fwd)
        snapshot(rev) == s &&
        snapshot(twice) == s &&
        snapshot(merged) == s &&
        !rev.has_pending()
      } catch {
        _ => false
      }
    },
    count=150,
  )
}

///|
test "property: diff_update gives exactly what a peer is missing" {
  @quickcheck.check(
    (seeds : Array[UInt]) => {
      let docs = [
        @ymoon.Doc(client_id=1),
        @ymoon.Doc(client_id=2),
        @ymoon.Doc(client_id=3),
      ]
      try {
        for e in gen_script(seeds) {
          run_edit(docs, e)
        }
        let full = docs[0].encode_state_as_update()
        let sv1 = docs[1].encode_state_vector()
        let diff = @ymoon.diff_update(full, sv1)
        let a = @ymoon.Doc(client_id=8)
        a.apply_update(docs[1].encode_state_as_update())
        a.apply_update(diff)
        let b = @ymoon.Doc(client_id=8)
        b.apply_update(docs[1].encode_state_as_update())
        b.apply_update(full)
        snapshot(a) == snapshot(b)
      } catch {
        _ => false
      }
    },
    count=150,
  )
}
