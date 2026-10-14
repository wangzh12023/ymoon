// Differential fuzzing oracle.
//
// Generates randomized multi-peer editing sessions, executes them with the
// reference yjs implementation and records every intermediate update plus the
// final document state. ymoon replays the same scripts and must produce the
// byte-identical updates and the same final content.
//
// Usage: node oracle/gen-traces.mjs <count> <seed> [output.jsonl]
// Without an output file the traces go to stdout. Prefer the file argument on
// Windows: PowerShell pipes re-encode text and would corrupt non-ASCII content.
// Missing directories in the output path are created.
import * as Y from 'yjs'
import fs from 'node:fs'
import path from 'node:path'

const hex = u8 => Buffer.from(u8).toString('hex')

// deterministic PRNG (mulberry32)
const rng = seed => () => {
  seed |= 0; seed = seed + 0x6D2B79F5 | 0
  let t = Math.imul(seed ^ seed >>> 15, 1 | seed)
  t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t
  return ((t ^ t >>> 14) >>> 0) / 4294967296
}

const count = Number(process.argv[2] || 200)
const baseSeed = Number(process.argv[3] || 1)
const outFile = process.argv[4] || null
if (outFile) fs.mkdirSync(path.dirname(outFile), { recursive: true })
const sink = outFile ? fs.openSync(outFile, 'w') : null
const emit = line => { if (sink !== null) fs.writeSync(sink, line); else process.stdout.write(line) }

const ALPHABET = ['a', 'b', 'c', 'd', 'X', 'Y', ' ', '\n', 'é', '中', '😀']
const ATTRS = [
  { bold: true }, { bold: null }, { italic: true }, { color: '#f00' }, { color: '#0f0' },
  { link: { href: 'https://moonbitlang.com' } }, { bold: true, italic: true }, {}
]
const VALUES = [0, 1, -1, 42, 3.5, 0.1, 2147483648, true, false, null, 'str', '中文',
  [1, 'two'], { k: 'v', n: 2 }, { nested: { list: [1, 2, 3] } }]

function randomString (r, maxLen) {
  const n = 1 + Math.floor(r() * maxLen)
  let s = ''
  for (let i = 0; i < n; i++) s += ALPHABET[Math.floor(r() * ALPHABET.length)]
  return s
}

// Clamp an index so it never splits a surrogate pair of the current text.
function safeIndex (str, i) {
  if (i > 0 && i < str.length) {
    const c = str.charCodeAt(i - 1)
    if (c >= 0xD800 && c <= 0xDBFF) return i - 1
  }
  return i
}

function genOp (r, doc, mode) {
  const text = doc.getText('text')
  const arr = doc.getArray('array')
  const map = doc.getMap('map')
  const roll = r()
  if (mode === 'text' || (mode === 'mixed' && roll < 0.55)) {
    const str = text.toString()
    const len = str.length
    const k = r()
    if (k < 0.5 || len === 0) {
      const index = safeIndex(str, Math.floor(r() * (len + 1)))
      const content = randomString(r, 6)
      if (r() < 0.25) {
        return { t: 'text.insert', index, content, attrs: ATTRS[Math.floor(r() * ATTRS.length)] }
      }
      return { t: 'text.insert', index, content }
    } else if (k < 0.8) {
      const index = safeIndex(str, Math.floor(r() * len))
      let end = safeIndex(str, Math.min(len, index + 1 + Math.floor(r() * 5)))
      if (end <= index) end = Math.min(len, index + 2)
      return { t: 'text.delete', index, length: end - index }
    } else {
      const index = safeIndex(str, Math.floor(r() * len))
      let end = safeIndex(str, Math.min(len, index + 1 + Math.floor(r() * 6)))
      if (end <= index) end = Math.min(len, index + 2)
      return { t: 'text.format', index, length: end - index, attrs: ATTRS[Math.floor(r() * (ATTRS.length - 1))] }
    }
  } else if (mode === 'array' || (mode === 'mixed' && roll < 0.8)) {
    const len = arr.length
    const k = r()
    if (k < 0.55 || len === 0) {
      const n = 1 + Math.floor(r() * 3)
      const values = []
      for (let i = 0; i < n; i++) values.push(VALUES[Math.floor(r() * VALUES.length)])
      if (r() < 0.3) return { t: 'array.push', values }
      return { t: 'array.insert', index: Math.floor(r() * (len + 1)), values }
    } else {
      const index = Math.floor(r() * len)
      const length = Math.min(len - index, 1 + Math.floor(r() * 3))
      return { t: 'array.delete', index, length }
    }
  } else {
    const keys = ['a', 'b', 'c', 'd', '1', '10', '中']
    const key = keys[Math.floor(r() * keys.length)]
    if (r() < 0.75) {
      return { t: 'map.set', key, value: VALUES[Math.floor(r() * VALUES.length)] }
    }
    return { t: 'map.delete', key }
  }
}

function applyOp (doc, op) {
  switch (op.t) {
    case 'text.insert': doc.getText('text').insert(op.index, op.content, op.attrs); break
    case 'text.delete': doc.getText('text').delete(op.index, op.length); break
    case 'text.format': doc.getText('text').format(op.index, op.length, op.attrs); break
    case 'array.insert': doc.getArray('array').insert(op.index, op.values); break
    case 'array.push': doc.getArray('array').push(op.values); break
    case 'array.delete': doc.getArray('array').delete(op.index, op.length); break
    case 'map.set': doc.getMap('map').set(op.key, op.value); break
    case 'map.delete': doc.getMap('map').delete(op.key); break
  }
}

function snapshot (doc) {
  return {
    text: doc.getText('text').toString(),
    delta: doc.getText('text').toDelta(),
    array: doc.getArray('array').toJSON(),
    map: doc.getMap('map').toJSON()
  }
}

const MODES = ['text', 'text', 'array', 'mixed', 'mixed']
for (let c = 0; c < count; c++) {
  const seed = baseSeed * 100003 + c
  const r = rng(seed)
  const mode = MODES[c % MODES.length]
  const gc = r() < 0.8
  const peers = 2 + Math.floor(r() * 3)
  const docs = []
  for (let p = 0; p < peers; p++) {
    const d = new Y.Doc({ gc })
    d.clientID = 1 + p * 7 + Math.floor(r() * 5) // deterministic, varied ordering
    docs.push(d)
  }
  // Each step: one peer performs an edit locally (recording the update it
  // emits), or two peers synchronise (recording the exchanged diffs).
  const steps = []
  const nsteps = 10 + Math.floor(r() * 50)
  for (let s = 0; s < nsteps; s++) {
    if (r() < 0.7) {
      const p = Math.floor(r() * peers)
      // yjs mutates attribute objects passed to insert(); record and apply
      // independent deep copies so the trace reflects exactly what ran.
      const op = JSON.parse(JSON.stringify(genOp(r, docs[p], mode)))
      let update = null
      const h = u => { update = hex(u) }
      docs[p].on('update', h)
      applyOp(docs[p], JSON.parse(JSON.stringify(op)))
      docs[p].off('update', h)
      steps.push({ k: 'op', peer: p, op, update })
    } else {
      const a = Math.floor(r() * peers)
      let b = Math.floor(r() * peers)
      if (a === b) b = (b + 1) % peers
      const svA = Y.encodeStateVector(docs[a])
      const svB = Y.encodeStateVector(docs[b])
      const toB = Y.encodeStateAsUpdate(docs[a], svB)
      const toA = Y.encodeStateAsUpdate(docs[b], svA)
      Y.applyUpdate(docs[b], toB)
      Y.applyUpdate(docs[a], toA)
      steps.push({ k: 'sync', a, b, svA: hex(svA), svB: hex(svB), toB: hex(toB), toA: hex(toA) })
    }
  }
  // final full sync so that all peers converge
  for (let i = 0; i < peers; i++) {
    for (let j = 0; j < peers; j++) {
      if (i !== j) Y.applyUpdate(docs[j], Y.encodeStateAsUpdate(docs[i], Y.encodeStateVector(docs[j])))
    }
  }
  const finals = docs.map(d => ({ state: hex(Y.encodeStateAsUpdate(d)), sv: hex(Y.encodeStateVector(d)), ...snapshot(d) }))
  emit(JSON.stringify({
    id: c, seed, mode, gc, clients: docs.map(d => d.clientID), steps, finals
  }) + '\n')
}
if (sink !== null) fs.closeSync(sink)
