// End-to-end interop test against the native MoonBit server (server/).
// Usage: node oracle/e2e-native-server.mjs <port>   (server already running)
import * as Y from 'yjs'
import { WebsocketProvider } from 'y-websocket'
import WebSocket from 'ws'
const port = Number(process.argv[2] || 1234)
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const until = async (cond, ms = 5000) => {
  const start = Date.now()
  while (!cond()) {
    if (Date.now() - start > ms) throw new Error('timeout waiting for condition')
    await wait(20)
  }
}

const mk = name => {
  const doc = new Y.Doc()
  const provider = new WebsocketProvider(`ws://localhost:${port}`, 'room-1', doc, { WebSocketPolyfill: WebSocket })
  return { name, doc, provider }
}

const a = mk('alice'); const b = mk('bob'); const c = mk('carol')
await until(() => a.provider.synced && b.provider.synced && c.provider.synced)

// concurrent edits from three peers
a.doc.getText('content').insert(0, 'Hello from Alice. ')
b.doc.getText('content').insert(0, 'Bob was here. ')
c.doc.getMap('meta').set('title', 'ymoon interop')
a.doc.getText('content').format(0, 5, { bold: true })
b.doc.getArray('todo').push(['write tests', 'ship it'])

// Y.Doc.toJSON() only lists root types a peer has accessed, so compare the
// shared types explicitly.
const view = doc => JSON.stringify({
  content: doc.getText('content').toDelta(),
  meta: doc.getMap('meta').toJSON(),
  todo: doc.getArray('todo').toJSON()
})
const same = () => view(a.doc) === view(b.doc) && view(b.doc) === view(c.doc)
await until(same)

// awareness (cursors / presence) flows through the MoonBit server too
a.provider.awareness.setLocalStateField('user', { name: 'alice', color: '#e91e63' })
await until(() => [...b.provider.awareness.getStates().values()].some(s => s.user && s.user.name === 'alice'))

// a late joiner receives the full state from the MoonBit server
const d = mk('dave')
await until(() => d.provider.synced)
await until(() => d.doc.getText('content').toString() === a.doc.getText('content').toString())

// the late joiner received everything from the server, so the server state
// matches the clients
const ok = d.doc.getText('content').toString() === a.doc.getText('content').toString()

console.log(JSON.stringify({
  clients: 4,
  text: a.doc.getText('content').toString(),
  delta: a.doc.getText('content').toDelta(),
  meta: a.doc.getMap('meta').toJSON(),
  todo: a.doc.getArray('todo').toJSON(),
  serverMatchesClients: ok,
  awarenessPeersSeenByBob: b.provider.awareness.getStates().size
}, null, 1))

for (const p of [a, b, c, d]) p.provider.destroy()
if (!ok) { console.error('server state diverged'); process.exit(1) }
console.log('E2E OK: y-websocket clients <-> native MoonBit ymoon-server')
process.exit(0)
