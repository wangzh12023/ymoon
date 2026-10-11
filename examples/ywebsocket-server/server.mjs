// A y-websocket compatible server whose collaboration logic is ymoon
// (MoonBit compiled to JavaScript). Node.js only provides the sockets.
//
//   moon build --target js --release
//   node examples/ywebsocket-server/server.mjs [port]
//
// Any y-websocket client (Tiptap, BlockNote, Monaco, CodeMirror bindings, ...)
// can connect to ws://localhost:<port>/<room-name>.
import { WebSocketServer } from 'ws'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../..')
const buildDir = process.env.YMOON_BUILD || path.join(root, '_build/js/release/build/js')
const ymoon = await import(pathToFileURL(path.join(buildDir, 'js.js')).href)

export function startServer ({ port = 1234, log = console.log } = {}) {
  const rooms = new Map() // name -> { handle, sockets: Map<connId, ws> }
  let nextConn = 1

  const roomFor = name => {
    let r = rooms.get(name)
    if (!r) {
      r = { handle: ymoon.room_new(name), sockets: new Map() }
      rooms.set(name, r)
      log(`[ymoon] room "${name}" created`)
    }
    return r
  }

  const flush = r => {
    while (ymoon.room_outgoing_count(r.handle) > 0) {
      const conn = ymoon.room_peek_conn(r.handle)
      const msg = ymoon.room_pop_message(r.handle)
      const ws = r.sockets.get(conn)
      if (process.env.YMOON_TRACE) log(`-> conn ${conn}: ${Buffer.from(msg).toString("hex").slice(0, 60)} open=${ws && ws.readyState === ws.OPEN}`)
      if (ws && ws.readyState === ws.OPEN) ws.send(msg)
    }
  }

  const wss = new WebSocketServer({ port })
  wss.on('connection', (ws, req) => {
    const name = decodeURIComponent((req.url || '/').slice(1).split('?')[0]) || 'default'
    const r = roomFor(name)
    const conn = nextConn++
    r.sockets.set(conn, ws)
    ws.binaryType = 'nodebuffer'
    ymoon.room_connect(r.handle, conn)
    flush(r)
    ws.on('message', data => {
      if (process.env.YMOON_TRACE) log(`<- conn ${conn}: ${Buffer.from(data).toString("hex").slice(0, 60)}`)
      const err = ymoon.room_receive(r.handle, conn, new Uint8Array(data))
      if (err) log(`[ymoon] conn ${conn}: ${err}`)
      flush(r)
    })
    ws.on('close', () => {
      ymoon.room_disconnect(r.handle, conn)
      r.sockets.delete(conn)
      flush(r)
    })
  })
  log(`[ymoon] y-websocket server listening on ws://localhost:${port}`)
  return {
    wss,
    roomText: (name, key) => ymoon.room_text(roomFor(name).handle, key),
    roomJSON: name => JSON.parse(ymoon.room_to_json(roomFor(name).handle)),
    close: () => new Promise(resolve => wss.close(resolve))
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  startServer({ port: Number(process.argv[2] || 1234) })
}
