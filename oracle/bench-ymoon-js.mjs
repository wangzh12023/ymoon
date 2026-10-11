// The automerge-paper trace replayed by ymoon compiled to JavaScript.
//   moon build --target js --release && node oracle/bench-ymoon-js.mjs
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
const here = path.dirname(fileURLToPath(import.meta.url))
const ymoon = await import(pathToFileURL(path.join(here, '../_build/js/release/build/js/js.js')).href)
const file = process.argv[2] || path.join(here, '../bench/data/automerge-paper.bin')
const b = fs.readFileSync(file)
const n = b.readUInt32LE(0)
const patches = []
let p = 4
for (let i = 0; i < n; i++) {
  const pos = b.readUInt32LE(p); const del = b.readUInt32LE(p + 4); const len = b.readUInt32LE(p + 8)
  p += 12
  patches.push([pos, del, b.subarray(p, p + 2 * len).toString('utf16le')])
  p += 2 * len
}
const t0 = performance.now()
const doc = ymoon.doc_new(1)
for (const [pos, del, ins] of patches) {
  if (del > 0) ymoon.text_delete(doc, 'text', pos, del)
  if (ins.length > 0) ymoon.text_insert(doc, 'text', pos, ins)
}
const t1 = performance.now()
const update = ymoon.doc_encode_state_as_update(doc, new Uint8Array())
const t2 = performance.now()
const doc2 = ymoon.doc_new(2)
ymoon.doc_apply_update(doc2, update)
const t3 = performance.now()
console.log(JSON.stringify({
  patches: n,
  apply_ms: Math.round(t1 - t0),
  encode_ms: Math.round(t2 - t1),
  decode_ms: Math.round(t3 - t2),
  update_bytes: update.length,
  replica_matches: ymoon.text_to_string(doc2, 'text') === ymoon.text_to_string(doc, 'text')
}))
