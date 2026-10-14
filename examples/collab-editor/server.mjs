// One-port demo server:
//   GET  /                 collaborative editor (Quill + yjs + y-websocket)
//   GET  /wire-bench       byte-level comparison bench (ymoon vs yjs)
//   GET  /api/rooms/<name> JSON snapshot of the MoonBit server's document
//   WS   /ws/<name>        y-websocket rooms, implemented by ymoon
//
//   moon build --target js --release        (repository root)
//   cd examples/collab-editor && npm install && node build.mjs
//   node server.mjs 6633
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { startServer } from '../ywebsocket-server/server.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const pages = {
  '/': path.join(here, 'dist/index.html'),
  '/wire-bench': path.join(here, '../../docs/index.html')
}

/** Starts the demo server; resolves once it listens. */
export function startDemoServer ({ port = 6633, quiet = false } = {}) {
const log = quiet ? () => {} : (...args) => console.log(new Date().toLocaleTimeString('zh-CN', { hour12: false }), ...args)

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost')
  const send = (code, type, body) => {
    res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store' })
    res.end(body)
  }
  if (req.method === 'GET' && pages[url.pathname]) {
    const file = pages[url.pathname]
    if (!fs.existsSync(file)) {
      send(500, 'text/plain; charset=utf-8', `missing ${file}: run \`node build.mjs\` (and the playground build for /wire-bench)`)
      return
    }
    send(200, 'text/html; charset=utf-8', fs.readFileSync(file))
    return
  }
  if (url.pathname === '/favicon.ico') {
    res.writeHead(204)
    res.end()
    return
  }
  if (req.method === 'GET' && url.pathname === '/api/rooms') {
    send(200, 'application/json', JSON.stringify(host.roomNames()))
    return
  }
  if (req.method === 'GET' && url.pathname.startsWith('/api/rooms/')) {
    const name = decodeURIComponent(url.pathname.slice('/api/rooms/'.length))
    send(200, 'application/json', JSON.stringify(host.roomSnapshot(name)))
    return
  }
  send(404, 'text/plain; charset=utf-8', 'not found')
})

const host = startServer({ server, pathPrefix: '/ws', log })
return new Promise(resolve => {
  server.listen(port, () => {
    const actual = server.address().port
    log(`ymoon demo server on http://localhost:${actual}/`)
    log(`  collaborative editor   http://localhost:${actual}/`)
    log(`  wire bench             http://localhost:${actual}/wire-bench`)
    log(`  y-websocket endpoint   ws://localhost:${actual}/ws/<room>`)
    resolve({ port: actual, host, close: () => new Promise(r => { host.close(); server.close(r) }) })
  })
})
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  startDemoServer({ port: Number(process.argv[2] || process.env.PORT || 6633) })
}
