// Replays reference traces recorded with the JavaScript yjs implementation
// (see oracle/gen-traces.mjs) and compares every produced update byte for byte.

///|
/// Outcome of replaying one trace.
pub(all) struct TraceResult {
  id : Int
  mode : String
  /// Number of compared updates / sync messages.
  checks : Int
  /// Human-readable description of the first mismatch, if any.
  failure : String?
}

///|
/// Hex encoding used by the trace files.
pub fn hex(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let sb = StringBuilder(size_hint=b.length() * 2)
  for byte in b {
    let v = byte.to_int()
    sb.write_char(digits.get_char(v >> 4).unwrap())
    sb.write_char(digits.get_char(v & 15).unwrap())
  }
  sb.to_string()
}

///|
/// Decodes the hex encoding used by the trace files.
pub fn unhex(s : StringView) -> Bytes {
  fn digit(c : Int) -> Int {
    if c >= '0'.to_int() && c <= '9'.to_int() {
      c - '0'.to_int()
    } else {
      c - 'a'.to_int() + 10
    }
  }

  Bytes::makei(s.length() / 2, i => {
    (digit(s.at(2 * i).to_int()) * 16 + digit(s.at(2 * i + 1).to_int())).to_byte()
  })
}

///|
fn jstr(j : Json, key : String) -> String {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
fn jint(j : Json, key : String) -> Int {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(Number(d, ..)) => d.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
fn jget(j : Json, key : String) -> Json? {
  match j {
    Object(m) => m.get(key)
    _ => None
  }
}

///|
fn attrs_of(j : Json?) -> @ymoon.Attrs? {
  match j {
    Some(Object(m)) => {
      let out : @ymoon.Attrs = Map([])
      for k, v in m {
        out[k] = @ymoon.json_to_any(v)
      }
      Some(out)
    }
    _ => None
  }
}

///|
/// Applies one recorded operation to `doc`.
fn apply_op(doc : @ymoon.Doc, op : Json) -> Unit raise {
  let t = jstr(op, "t")
  match t {
    "text.insert" => {
      let text = doc.get_text("text")
      match attrs_of(jget(op, "attrs")) {
        Some(a) =>
          text.insert(jint(op, "index"), jstr(op, "content"), attributes=a)
        None => text.insert(jint(op, "index"), jstr(op, "content"))
      }
    }
    "text.delete" =>
      doc.get_text("text").delete(jint(op, "index"), jint(op, "length"))
    "text.format" =>
      doc
      .get_text("text")
      .format(
        jint(op, "index"),
        jint(op, "length"),
        attrs_of(jget(op, "attrs")).unwrap_or(Map([])),
      )
    "array.insert" | "array.push" => {
      let values : Array[@ymoon.Value] = match jget(op, "values") {
        Some(Array(xs)) => xs.map(x => @ymoon.Value::Any(@ymoon.json_to_any(x)))
        _ => []
      }
      let arr = doc.get_array("array")
      if t == "array.push" {
        arr.push(values)
      } else {
        arr.insert(jint(op, "index"), values)
      }
    }
    "array.delete" =>
      doc
      .get_array("array")
      .delete(jint(op, "index"), length=jint(op, "length"))
    "map.set" => {
      let v = match jget(op, "value") {
        Some(j) => @ymoon.json_to_any(j)
        None => Undefined
      }
      doc.get_map("map").set(jstr(op, "key"), Any(v))
    }
    "map.delete" => doc.get_map("map").delete(jstr(op, "key"))
    _ => fail("unknown op \{t}")
  }
}

///|
/// Replays a single trace (one JSON line).
pub fn replay_trace(line : StringView) -> TraceResult raise {
  let trace = @json.parse(line)
  let id = jint(trace, "id")
  let mode = jstr(trace, "mode")
  let gc = match jget(trace, "gc") {
    Some(False) => false
    _ => true
  }
  let clients = match jget(trace, "clients") {
    Some(Array(xs)) => xs
    _ => []
  }
  let docs = clients.map(c => {
    match c {
      Number(d, ..) => @ymoon.Doc(client_id=d.to_uint(), gc~)
      _ => @ymoon.Doc(gc~)
    }
  })
  let mut checks = 0
  fn mismatch(
    what : String,
    expected : String,
    actual : String,
  ) -> TraceResult {
    {
      id,
      mode,
      checks,
      failure: Some("\{what}\n  expected: \{expected}\n  actual:   \{actual}"),
    }
  }

  let steps = match jget(trace, "steps") {
    Some(Array(xs)) => xs
    _ => []
  }
  for si, step in steps {
    match jstr(step, "k") {
      "op" => {
        let p = jint(step, "peer")
        let doc = docs[p]
        let produced : Ref[Bytes?] = Ref(None)
        doc.on_update((u, _) => produced.val = Some(u))
        let op = jget(step, "op").unwrap()
        // the JS harness touches the root types right before each edit
        ignore(doc.get_text("text"))
        ignore(doc.get_array("array"))
        ignore(doc.get_map("map"))
        apply_op(doc, op)
        doc.clear_update_handlers()
        let expected = match jget(step, "update") {
          Some(String(s)) => Some(s)
          _ => None
        }
        let actual = produced.val.map(hex)
        checks += 1
        if expected != actual {
          return mismatch(
            "step \{si}: update of \{op.stringify()} on peer \{p}",
            expected.unwrap_or("<none>"),
            actual.unwrap_or("<none>"),
          )
        }
      }
      "sync" => {
        let a = jint(step, "a")
        let b = jint(step, "b")
        let sv_a = hex(docs[a].encode_state_vector())
        let sv_b = hex(docs[b].encode_state_vector())
        checks += 2
        if sv_a != jstr(step, "svA") {
          return mismatch(
            "step \{si}: state vector of \{a}",
            jstr(step, "svA"),
            sv_a,
          )
        }
        if sv_b != jstr(step, "svB") {
          return mismatch(
            "step \{si}: state vector of \{b}",
            jstr(step, "svB"),
            sv_b,
          )
        }
        let to_b = hex(
          docs[a].encode_state_as_update(
            target=@ymoon.StateVector::decode(unhex(sv_b)),
          ),
        )
        let to_a = hex(
          docs[b].encode_state_as_update(
            target=@ymoon.StateVector::decode(unhex(sv_a)),
          ),
        )
        checks += 2
        if to_b != jstr(step, "toB") {
          return mismatch(
            "step \{si}: diff \{a} -> \{b}",
            jstr(step, "toB"),
            to_b,
          )
        }
        if to_a != jstr(step, "toA") {
          return mismatch(
            "step \{si}: diff \{b} -> \{a}",
            jstr(step, "toA"),
            to_a,
          )
        }
        docs[b].apply_update(unhex(to_b))
        docs[a].apply_update(unhex(to_a))
      }
      _ => fail("unknown step kind")
    }
  }
  // final full sync
  let n = docs.length()
  for i in 0..<n {
    for j in 0..<n {
      if i != j {
        let u = docs[i].encode_state_as_update(target=docs[j].state_vector())
        docs[j].apply_update(u)
      }
    }
  }
  let finals = match jget(trace, "finals") {
    Some(Array(xs)) => xs
    _ => []
  }
  for i, fin in finals {
    let d = docs[i]
    checks += 4
    let text = d.get_text("text").to_string()
    if text != jstr(fin, "text") {
      return mismatch("final text of peer \{i}", jstr(fin, "text"), text)
    }
    let delta = @ymoon.delta_to_json(d.get_text("text").to_delta()).stringify()
    let exp_delta = jget(fin, "delta").unwrap().stringify()
    if delta != exp_delta {
      return mismatch("final delta of peer \{i}", exp_delta, delta)
    }
    let arr = d.get_array("array").to_json().stringify()
    let exp_arr = jget(fin, "array").unwrap().stringify()
    if arr != exp_arr {
      return mismatch("final array of peer \{i}", exp_arr, arr)
    }
    let mp = normalize_object(d.get_map("map").to_json())
    let exp_mp = normalize_object(jget(fin, "map").unwrap())
    if mp != exp_mp {
      return mismatch("final map of peer \{i}", exp_mp, mp)
    }
    let state = hex(d.encode_state_as_update())
    checks += 1
    if state != jstr(fin, "state") {
      return mismatch(
        "final encoded state of peer \{i}",
        jstr(fin, "state"),
        state,
      )
    }
  }
  { id, mode, checks, failure: None, }
}

///|
/// Stringifies a JSON object with sorted keys (JSON objects are unordered).
fn normalize_object(j : Json) -> String {
  match j {
    Object(m) => {
      let keys = m.keys().collect()
      keys.sort_by((a, b) => a.lexical_compare(b))
      let parts = keys.map(k => {
        "\{Json::string(k).stringify()}:\{normalize_object(m[k])}"
      })
      "{" + parts.join(",") + "}"
    }
    Array(xs) => "[" + xs.map(normalize_object).join(",") + "]"
    _ => j.stringify()
  }
}
