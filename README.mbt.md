# ymoon

**Yjs, the CRDT behind collaborative editors like Tiptap, BlockNote and Monaco, ported to MoonBit and compatible with Yjs at the byte level.**

`ymoon` reads and writes the binary update format of [Yjs](https://github.com/yjs/yjs) (v1) exactly the way `yjs@13.6.33` does. A MoonBit program can join a Yjs collaboration as a full peer: as a sync server, an offline-first client, a CLI that repairs or inspects stored documents, or an AI agent that edits a shared document next to human users. It runs on every MoonBit backend: wasm, wasm-gc, JavaScript and native.

[![ci](https://github.com/wangzh12023/ymoon/actions/workflows/ci.yml/badge.svg)](https://github.com/wangzh12023/ymoon/actions/workflows/ci.yml)

中文演示与验证指南：[docs/demo.zh.md](docs/demo.zh.md) · Live wire bench: <https://wangzh12023.github.io/ymoon/>

| | |
|---|---|
| Wire compatibility | 6,000 randomized multi-peer sessions recorded with `yjs@13.6.33`, replayed by ymoon: every emitted update, state vector, sync diff and final document state is **byte-identical** (about 490,000 byte-level comparisons) |
| Real clients | 4 official `y-websocket` clients (npm) edit text, formatting, maps and arrays through a native MoonBit server (`moonbitlang/async`) and through the same logic compiled to JS |
| Formal verification | the clock-range core (delete-set lookup, sync offsets, range merging) is proved with `moon prove` in the bounded machine-integer model: 46 proof goals, no overflow |
| Property tests | convergence, commutativity, idempotence, `merge_updates` and `diff_update` laws on all four backends |
| Real workload | the automerge-paper editing trace (259,778 keystrokes) produces the same 223,414-byte document as yjs |

## Why

Yjs is downloaded more than 10 million times a week and is the de-facto wire format for collaborative editing on the web. Its implementations exist in JavaScript and Rust (`yrs`). Before ymoon, a MoonBit program that wanted to take part in a Yjs document had no way to read or produce the bytes. The CRDT libraries that already exist in MoonBit (eg-walker, a Loro port) use their own formats and cannot talk to the Yjs ecosystem.

## Install

```sh
moon add wangzh12023/ymoon
```

Add the packages you need to your `moon.pkg`:

```moonbit nocheck
///|
import {
  "wangzh12023/ymoon",
  "wangzh12023/ymoon/lib0", // lib0 binary encoding and JS-compatible JSON
  "wangzh12023/ymoon/protocols", // sync, awareness, y-websocket rooms
}
```

## Quick start

Two documents edit concurrently, exchange updates, and converge:

```mbt check
///|
test "two peers converge" {
  let alice = @ymoon.Doc(client_id=1)
  let bob = @ymoon.Doc(client_id=2)
  alice.get_text("doc").insert(0, "Hello")
  bob.get_text("doc").insert(0, "World")
  // exchange full states (in practice: only what the other side is missing)
  bob.apply_update(alice.encode_state_as_update())
  alice.apply_update(bob.encode_state_as_update())
  assert_eq(alice.get_text("doc").to_string(), bob.get_text("doc").to_string())
  inspect(alice.get_text("doc").to_string(), content="HelloWorld")
}
```

Every transaction emits an incremental update that any Yjs peer understands:

```mbt check
///|
test "updates are the bytes yjs would send" {
  let doc = @ymoon.Doc(client_id=1)
  let sent : Array[Bytes] = []
  doc.on_update((update, _origin) => sent.push(update))
  doc.get_text("t").insert(0, "hello")
  // byte-for-byte what yjs@13.6.33 emits for the same edit
  inspect(
    sent[0],
    content=(
      #|b"\x01\x01\x01\x00\x04\x01\x01t\x05hello\x00"
    ),
  )
}
```

## Rich text, maps, arrays, nesting

```mbt check
///|
test "rich text with formatting" {
  let doc = @ymoon.Doc(client_id=1)
  let text = doc.get_text("note")
  text.insert(0, "bold and plain")
  text.format(0, 4, { "bold": Bool(true) })
  json_inspect(@ymoon.delta_to_json(text.to_delta()), content=[
    { "insert": "bold", "attributes": { "bold": true } },
    { "insert": " and plain" },
  ])
}

///|
test "maps, arrays and nested types" {
  let doc = @ymoon.Doc(client_id=1)
  let board = doc.get_map("board")
  board.set("title", @ymoon.Value::str("Launch"))
  let cards = @ymoon.ArrayRef::from_branch(board.set_shared("cards", YArray))
  cards.push([@ymoon.Value::str("write docs"), @ymoon.Value::str("ship")])
  json_inspect(board.to_json(), content={
    "title": "Launch",
    "cards": ["write docs", "ship"],
  })
}
```

Supported shared types: `Y.Text` (insert, delete, format, embeds, deltas), `Y.Map`, `Y.Array`, `Y.XmlFragment`, `Y.XmlElement`, `Y.XmlText` and nested combinations of them.

## Syncing with state vectors

Peers that reconnect exchange state vectors and send each other only the missing structs. `diff_update` and `merge_updates` work on raw bytes without loading a document, which is what sync servers and storage layers need:

```mbt check
///|
test "send only what the other peer is missing" {
  let a = @ymoon.Doc(client_id=1)
  a.get_text("t").insert(0, "hello")
  let b = @ymoon.Doc(client_id=2)
  b.apply_update(a.encode_state_as_update())
  a.get_text("t").insert(5, " world")
  // b tells a what it has; a answers with the difference only
  let missing = a.encode_state_as_update(target=b.state_vector())
  b.apply_update(missing)
  inspect(b.get_text("t").to_string(), content="hello world")
  // the same works on stored bytes, with no document in memory
  let stored = @ymoon.merge_updates([
    a.encode_state_as_update(),
    b.encode_state_as_update(),
  ])
  let delta = @ymoon.diff_update(stored, b.encode_state_vector())
  let (structs, _) = @ymoon.decode_update(delta)
  inspect(structs.length(), content="0")
}
```

Updates that arrive out of order are kept pending and integrated once their dependencies arrive, as in Yjs.

## y-websocket rooms and awareness

`@protocols` implements the sync protocol (`SyncStep1`, `SyncStep2`, `Update`), the awareness protocol (cursors and presence) and the y-websocket message framing. `Room` is the server side of a y-websocket room. It does not depend on any socket library, so it can sit behind `moonbitlang/async`, Node.js or anything else that moves bytes.

```mbt check
///|
test "a y-websocket room" {
  let room = @protocols.Room("design-doc")
  let outbox : Array[Bytes] = []
  room.connect(1, msg => outbox.push(msg))
  // a client sends its edits as a y-websocket sync message
  let client = @ymoon.Doc(client_id=42)
  client.get_text("content").insert(0, "from the browser")
  room.receive(
    1,
    @protocols.Message::Sync(Update(client.encode_state_as_update())).encode(),
  )
  inspect(room.doc.get_text("content").to_string(), content="from the browser")
}
```

Two servers are included:

- **`server/`**: a native MoonBit server on `moonbitlang/async` (HTTP + WebSocket), no JavaScript involved. CI builds it on Linux and runs four official `y-websocket` clients against it (`oracle/e2e-native-server.mjs`).

  ```sh
  moon -C server run main --target native -- 1234
  ```

- **`examples/ywebsocket-server`**: the same `Room` compiled to JavaScript behind Node.js sockets, for hosts without a native toolchain.

Point any y-websocket based editor at `ws://localhost:1234/<room>`.

**Try it with a real editor.** `examples/collab-editor` serves Quill editors (with the official `yjs`, `y-websocket` and `y-quill` packages) whose collaboration server is ymoon, plus a panel that shows the MoonBit server's own copy of the document next to the browser's:

```sh
moon build --target js --release
cd examples/playground && npm install && node build.mjs && cd ../..
cd examples/collab-editor && npm install && node build.mjs
node server.mjs 6633          # open http://localhost:6633/ in two windows
```

To run only the Node.js y-websocket server:

```sh
moon build --target js --release
cd examples/ywebsocket-server && npm install && cd ../..
node examples/ywebsocket-server/server.mjs 1234
```

`oracle/e2e-ywebsocket.mjs` runs this server with four official `y-websocket` clients from npm. The clients edit concurrently, share awareness, and a late joiner catches up. All of them, and the server, end with the same document.

## Command line

`cmd/ymoon` inspects and transforms stored Yjs documents:

```sh
moon run cmd/ymoon -- inspect doc.ybin           # structs, delete set, statistics
moon run cmd/ymoon -- dump a.ybin b.ybin         # document content as JSON
moon run cmd/ymoon -- merge a.ybin b.ybin -o all.ybin
moon run cmd/ymoon -- diff old.ybin new.ybin -o delta.ybin
moon run cmd/ymoon -- compact all.ybin -o small.ybin
moon run cmd/ymoon -- sv all.ybin                # state vector
```

## Wire bench

`examples/playground` builds a page with two live editors: one runs ymoon compiled to JavaScript, the other runs the official `yjs` package. Each keystroke is sent across as a binary update. Each update is also replayed in the other engine, and the page shows whether both engines produce the same bytes. A decoder labels every byte of the selected update. You can take a peer offline and reconnect it to watch state-vector sync.

```sh
moon build --target js --release
node examples/playground/build.mjs   # writes docs/index.html
```

## How correctness is established

1. **Differential testing against the reference.** `oracle/gen-traces.mjs` drives `yjs@13.6.33` through randomized sessions of 2 to 4 peers. The sessions cover text with formatting, emoji and CJK, arrays, maps, garbage collection on and off, and partial syncs. It records every update. `conformance/` replays each session with ymoon and compares every emitted update, state vector, sync diff, final content and final encoded state byte by byte. CI generates fresh traces with a new seed on every run.
2. **Reference vectors.** lib0 varints, strings, `writeAny`, JavaScript number formatting, `JSON.stringify` escaping and y-protocols messages are checked against bytes produced by the JavaScript libraries (`oracle/gen-*.mjs`).
3. **Formal verification.** `verified/` holds the clock-range algebra used by delete sets and sync. It is proved with `moon prove` (Why3 + Z3) in the bounded machine-integer model, so the proofs also exclude integer overflow. The prover found a real overflow in the naive `start + len` comparison, which led to the overflow-safe form now used. `DeleteSet::contains` runs the verified lookup in production.
4. **Real editors in a real browser.** `examples/collab-editor/browser-test.mjs` drives Chrome: Quill editors type, format, go offline and reconnect through the ymoon server, a late joiner catches up, and the server's own copy must equal every editor. The same run checks that the wire bench reports every update byte-identical across ymoon and yjs. CI runs it on every push.
5. **CRDT laws as properties.** QuickCheck properties check convergence after any exchange order, commutativity and idempotence of update application, `merge_updates` equivalence, and that `diff_update` carries exactly what a peer is missing. A property found a real bug: after integrating a struct with an offset, the cached client clock was wrong and later structs stayed pending forever. The fix has a regression test.

Run everything:

```sh
cd oracle && npm install && node gen-traces.mjs 2000 7 > out/traces.jsonl && cd ..
moon test --target all
MOON_PROVE_PRELUDE_OVERRIDE=~/.moon/lib/prelude_proof_machine_int moon prove verified
```

## Performance

The [automerge-paper trace](https://github.com/josephg/editing-traces) replays 259,778 real keystrokes that typed an academic paper:

| engine | replay | encode | decode | update size |
|---|---|---|---|---|
| yjs@13.6.33 on Node 25 | 0.96 s | 5 ms | 13 ms | 223,414 B |
| ymoon, MoonBit → JS on Node 25 | 1.26 s | 13 ms | 35 ms | 223,414 B |
| ymoon, MoonBit → native (Windows, MinGW gcc) | 1.97 s | 2 ms | 10 ms | 223,414 B |

All three produce the identical 223,414-byte document. ymoon keeps the Yjs algorithms as they are, including the search-marker index cache, so that its output matches byte for byte. Making the native backend faster than V8 on this workload is future work.

## Scope

**Supported:** the yjs v1 update format; Y.Text, Y.Map, Y.Array and Y.Xml* types with nesting; rich-text formatting, embeds and deltas; garbage collection; pending updates; `merge_updates`, `diff_update`, `encode_state_vector_from_update`; the sync and awareness protocols; y-websocket rooms; sub-document references (as data).

**Not implemented:** the v2 update encoding (`encodeStateAsUpdateV2`), `UndoManager`, snapshots and `RelativePosition`, observer event objects with deltas (`observe` reports the changed types and keys instead), and loading sub-documents.

## Layout

| package | contents |
|---|---|
| `wangzh12023/ymoon` | documents, shared types, update encoding and decoding, update utilities |
| `ymoon/lib0` | lib0-compatible binary encoder and decoder, `Any` values, JavaScript-exact JSON |
| `ymoon/protocols` | sync and awareness protocols, y-websocket framing, `Room` and `Hub` |
| `ymoon/verified` | formally verified clock-range core (`moon prove`) |
| `ymoon/cli`, `cmd/ymoon` | command line tool |
| `ymoon/js` | JavaScript API used by the wire bench and the Node.js server |
| `conformance`, `oracle` | differential test harness and the JavaScript reference generators |

## License

Apache-2.0. ymoon is a port of [yjs](https://github.com/yjs/yjs), [lib0](https://github.com/dmonad/lib0) and [y-protocols](https://github.com/yjs/y-protocols) by Kevin Jahns and contributors, all MIT licensed. See `NOTICE`.
