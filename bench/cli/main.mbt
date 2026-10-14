// Replays a real-world editing trace (default: automerge-paper, 259,778
// single-character edits typing an academic paper) and reports timings as
// JSON. The same trace is replayed by yjs in oracle/bench-yjs.mjs.
//
//   moon run bench/cli --target native --release -- bench/data/automerge-paper.bin

///|
fn read_u32(b : Bytes, pos : Int32) -> Int32 {
  b[pos].to_int() |
  (b[pos + 1].to_int() << 8) |
  (b[pos + 2].to_int() << 16) |
  (b[pos + 3].to_int() << 24)
}

///|
priv struct Patch {
  pos : Int32
  del : Int32
  ins : String
}

///|
fn load(path : String) -> Array[Patch] raise {
  let b = @fs.read_file_to_bytes(path)
  let n = read_u32(b, 0)
  let out : Array[Patch] = Array(capacity=n)
  let mut p = 4
  for _ in 0..<n {
    let pos = read_u32(b, p)
    let del = read_u32(b, p + 4)
    let len = read_u32(b, p + 8)
    p += 12
    let sb = StringBuilder(size_hint=len)
    for i in 0..<len {
      let cu = b[p + 2 * i].to_int() | (b[p + 2 * i + 1].to_int() << 8)
      sb.write_char(cu.unsafe_to_char())
    }
    p += 2 * len
    out.push({ pos, del, ins: sb.to_string(), })
  }
  out
}

///|
fn main {
  let args = @env.args()
  let path = args
    .iter()
    .filter(a => a.has_suffix(".bin"))
    .last()
    .unwrap_or("bench/data/automerge-paper.bin")
  let patches = load(path) catch {
    e => {
      println("cannot read \{path}: \{e}")
      return
    }
  }
  let t0 = @env.now()
  let doc = @ymoon.Doc(client_id=1)
  let text = doc.get_text("text")
  for p in patches {
    if p.del > 0 {
      text.delete(p.pos, p.del) catch {
        _ => abort("bad delete")
      }
    }
    if p.ins.length() > 0 {
      text.insert(p.pos, p.ins) catch {
        _ => abort("bad insert")
      }
    }
  }
  let t1 = @env.now()
  let update = doc.encode_state_as_update()
  let t2 = @env.now()
  let doc2 = @ymoon.Doc(client_id=2)
  doc2.apply_update(update) catch {
    _ => abort("bad update")
  }
  let t3 = @env.now()
  let final_text = text.to_string()
  println(
    "{\"patches\":\{patches.length()},\"apply_ms\":\{t1 - t0},\"encode_ms\":\{t2 - t1},\"decode_ms\":\{t3 - t2},\"update_bytes\":\{update.length()},\"final_length\":\{final_text.length()},\"replica_matches\":\{doc2.get_text("text").to_string() == final_text}}",
  )
}
