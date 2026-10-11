// Replays a property-test edit script (seed list) with yjs, mirroring
// gen_script / run_edit in crdt_laws_test.mbt, and prints each peer's state.
import * as Y from 'yjs'
const seeds = JSON.parse(process.argv[2])
const alphabet = ['a', 'b', 'xy', '中', 'é', '😀', ' ', '\n']
const toInt = u => (u | 0) // reinterpret uint32 as int32
const script = seeds.map(u => {
  const s = toInt(u >>> 1)
  const peer = s % 3; const k = Math.trunc(s / 3) % 10; const a = Math.trunc(s / 30)
  if (k <= 2) return { t: 'ins', peer, pos: a % 1000, text: alphabet[a % alphabet.length] }
  if (k <= 4) return { t: 'del', peer, pos: a % 1000, len: 1 + a % 3 }
  if (k === 5) return { t: 'fmt', peer, pos: a % 1000, len: 1 + a % 4, bold: a % 2 === 0 }
  if (k === 6) return { t: 'map', peer, key: a % 4, value: a % 100 }
  if (k === 7) return { t: 'push', peer, value: a % 100 }
  return { t: 'sync', from: peer, to: (peer + 1 + a % 2) % 3 }
})
const safePos = (s, pos) => {
  let p = s.length === 0 ? 0 : pos % (s.length + 1)
  if (p > 0 && p < s.length) { const c = s.charCodeAt(p - 1); if (c >= 0xd800 && c <= 0xdbff) return p - 1 }
  return p
}
const docs = [1, 2, 3].map(id => { const d = new Y.Doc(); d.clientID = id; return d })
for (const e of script) {
  if (e.t === 'ins') { const t = docs[e.peer].getText('t'); t.insert(safePos(t.toString(), e.pos), e.text) }
  if (e.t === 'del') {
    const t = docs[e.peer].getText('t'); const s = t.toString()
    if (s.length > 0) { const p = safePos(s, e.pos % s.length); let end = safePos(s, Math.min(s.length, p + e.len)); if (end <= p) end = Math.min(s.length, p + 2); t.delete(p, end - p) }
  }
  if (e.t === 'fmt') {
    const t = docs[e.peer].getText('t'); const s = t.toString()
    if (s.length > 0) { const p = safePos(s, e.pos % s.length); const l = Math.min(e.len, s.length - p); t.format(p, l, { bold: e.bold ? true : null }) }
  }
  if (e.t === 'map') docs[e.peer].getMap('m').set('k' + e.key, e.value)
  if (e.t === 'push') docs[e.peer].getArray('a').push([e.value])
  if (e.t === 'sync') Y.applyUpdate(docs[e.to], Y.encodeStateAsUpdate(docs[e.from], Y.encodeStateVector(docs[e.to])))
}
for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) if (i !== j) Y.applyUpdate(docs[j], Y.encodeStateAsUpdate(docs[i], Y.encodeStateVector(docs[j])))
for (const d of docs) console.log(JSON.stringify(d.getText('t').toDelta()))
