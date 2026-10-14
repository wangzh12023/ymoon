// A y-websocket compatible server whose collaboration logic is ymoon
// (MoonBit compiled to JavaScript). Node.js only provides the sockets.
//
//   moon build --target js --release
//   node examples/ywebsocket-server/server.mjs [port]
//
// Any y-websocket client (Tiptap, BlockNote, Quill, Monaco, CodeMirror
// bindings, ...) can connect to ws://localhost:<port>/<room-name>.
import { WebSocketServer } from 'ws'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { ymoonJsPath } from '../../oracle/find-build.mjs'

const ymoon = await import(pathToFileURL(process.env.YMOON_JS || ymoonJsPath()).href)

/**
 * Starts the server.
 *  - `port`: listen on a port of its own, or
 *  - `server`: attach to an existing http.Server (WebSocket upgrades only);
 *    `pathPrefix` (e.g. '/ws') is stripped before taking the room name.
 */
export function startServer ({ port = 1234, server = null, pathPrefix = '', log = console.log } = {}) {
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
      if (process.env.YMOON_TRACE) log(`-> conn ${conn}: ${Buffer.from(msg).toString('hex').slice(0, 60)}`)
      if (ws && ws.readyState === ws.OPEN) ws.send(msg)
    }
  }

  const roomName = url => {
    let p = (url || '/').split('?')[0]
    if (pathPrefix && p.startsWith(pathPrefix)) p = p.slice(pathPrefix.length)
    return decodeURIComponent(p.replace(/^\/+/, '')) || 'default'
  }

  const wss = server ? new WebSocketServer({ noServer: true }) : new WebSocketServer({ port })
  if (server) {
    server.on('upgrade', (req, socket, head) => {
      if (pathPrefix && !(req.url || '').startsWith(pathPrefix)) {
        socket.destroy()
        return
      }
      wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req))
    })
  }
  wss.on('connection', (ws, req) => {
    const name = roomName(req.url)
    const r = roomFor(name)
    const conn = nextConn++
    r.sockets.set(conn, ws)
    ws.binaryType = 'nodebuffer'
    ymoon.room_connect(r.handle, conn)
    flush(r)
    ws.on('message', data => {
      if (process.env.YMOON_TRACE) log(`<- conn ${conn}: ${Buffer.from(data).toString('hex').slice(0, 60)}`)
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
  if (!server) log(`[ymoon] y-websocket server listening on ws://localhost:${port}`)
  return {
    wss,
    roomNames: () => [...rooms.keys()],
    roomText: (name, key) => ymoon.room_text(roomFor(name).handle, key),
    roomJSON: name => JSON.parse(ymoon.room_to_json(roomFor(name).handle)),
    roomSnapshot: name => JSON.parse(ymoon.room_snapshot(roomFor(name).handle)),
    close: () => new Promise(resolve => wss.close(resolve))
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  startServer({ port: Number(process.argv[2] || 1234) })
}
