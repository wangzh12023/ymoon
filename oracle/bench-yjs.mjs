// Baseline: the same automerge-paper trace replayed by yjs@13.6.33.
//   node oracle/bench-yjs.mjs [bench/data/automerge-paper.bin]
import * as Y from 'yjs'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const file = process.argv[2] || path.join(here, '../bench/data/automerge-paper.bin')
const b = fs.readFileSync(file)
const n = b.readUInt32LE(0)
const patches = []
let p = 4
for (let i = 0; i < n; i++) {
  const pos = b.readUInt32LE(p); const del = b.readUInt32LE(p + 4); const len = b.readUInt32LE(p + 8)
  p += 12
  const ins = b.subarray(p, p + 2 * len).toString('utf16le')
  p += 2 * len
  patches.push([pos, del, ins])
}
const now = () => performance.now()
const t0 = now()
const doc = new Y.Doc(); doc.clientID = 1
const text = doc.getText('text')
for (const [pos, del, ins] of patches) {
  if (del > 0) text.delete(pos, del)
  if (ins.length > 0) text.insert(pos, ins)
}
const t1 = now()
const update = Y.encodeStateAsUpdate(doc)
const t2 = now()
const doc2 = new Y.Doc(); doc2.clientID = 2
Y.applyUpdate(doc2, update)
const t3 = now()
console.log(JSON.stringify({
  patches: n,
  apply_ms: Math.round(t1 - t0),
  encode_ms: Math.round(t2 - t1),
  decode_ms: Math.round(t3 - t2),
  update_bytes: update.length,
  final_length: text.toString().length,
  replica_matches: doc2.getText('text').toString() === text.toString()
}))
