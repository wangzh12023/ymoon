// Browser side of the collaborative editing demo: Quill + official yjs +
// y-websocket. The server these editors talk to is ymoon (MoonBit).
import * as Y from 'yjs'
import { WebsocketProvider } from 'y-websocket'
import Quill from 'quill'
import QuillCursors from 'quill-cursors'
import { QuillBinding } from 'y-quill'

Quill.register('modules/cursors', QuillCursors)

const params = new URLSearchParams(location.search)
const room = (params.get('room') || 'ymoon-demo').slice(0, 64)
const $ = id => document.getElementById(id)

// Moon-themed names; every window picks one at random.
const NAMES = ['望舒', '月兔', '嫦娥', '吴刚', '常羲', '素娥', '婵娟', '玉蟾']
const COLORS = ['#1f6f5c', '#9a5b00', '#6b4fd8', '#b3261e', '#0b6e99', '#8e3a9d', '#2e7d32', '#c2185b']
const pick = xs => xs[Math.floor(Math.random() * xs.length)]
const me = { name: params.get('name') || pick(NAMES), color: pick(COLORS) }

const ydoc = new Y.Doc()
const wsUrl = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`
const provider = new WebsocketProvider(wsUrl, room, ydoc)
const ytext = ydoc.getText('quill')

const quill = new Quill('#editor', {
  theme: 'snow',
  placeholder: '在这里输入。打开第二个窗口，两边同时编辑试试。',
  modules: {
    cursors: true,
    toolbar: [
      [{ header: [1, 2, false] }],
      ['bold', 'italic', 'underline', 'strike'],
      [{ list: 'ordered' }, { list: 'bullet' }],
      ['link', 'blockquote', 'code-block'],
      ['clean']
    ],
    history: { userOnly: true }
  }
})
const binding = new QuillBinding(ytext, quill, provider.awareness)
window.__demo = { ydoc, provider, quill, binding, Y }
provider.awareness.setLocalStateField('user', me)

// --- identity ---------------------------------------------------------------
$('me-name').value = me.name
$('me-dot').style.background = me.color
$('me-client').textContent = String(ydoc.clientID)
$('room-name').textContent = room
$('me-name').addEventListener('change', () => {
  me.name = $('me-name').value.trim() || me.name
  provider.awareness.setLocalStateField('user', me)
})

// --- connection -------------------------------------------------------------
const connBtn = $('conn-toggle')
function renderConnection (status) {
  const online = status === 'connected'
  $('conn-state').textContent = online ? '已连接' : status === 'connecting' ? '连接中…' : '已断开（离线编辑中）'
  $('conn-state').dataset.state = online ? 'on' : status === 'connecting' ? 'wait' : 'off'
  connBtn.textContent = provider.shouldConnect ? '断开连接' : '重新连接'
}
provider.on('status', ({ status }) => {
  renderConnection(status)
  // Re-announce presence after a reconnect. The server dropped this window's
  // awareness entry on disconnect but kept its clock (y-protocols semantics),
  // so an unchanged state would otherwise wait for the 15 s heartbeat.
  if (status === 'connected' && provider.awareness.getLocalState() !== null) {
    provider.awareness.setLocalState({ ...provider.awareness.getLocalState() })
  }
})
connBtn.addEventListener('click', () => {
  if (provider.shouldConnect) provider.disconnect()
  else provider.connect()
  renderConnection(provider.wsconnected ? 'connected' : provider.shouldConnect ? 'connecting' : 'disconnected')
})
$('open-peer').addEventListener('click', () => {
  window.open(location.href, '_blank', 'width=980,height=820')
})
renderConnection('connecting')

// --- presence ---------------------------------------------------------------
function renderPresence () {
  const list = $('presence')
  list.innerHTML = ''
  const states = [...provider.awareness.getStates().entries()]
  for (const [clientId, state] of states) {
    if (!state.user) continue
    const li = document.createElement('li')
    const dot = document.createElement('span')
    dot.className = 'dot'
    dot.style.background = state.user.color
    const name = document.createElement('span')
    name.textContent = state.user.name + (clientId === ydoc.clientID ? '（你）' : '')
    const id = document.createElement('span')
    id.className = 'mono soft'
    id.textContent = String(clientId)
    li.append(dot, name, id)
    list.append(li)
  }
  $('presence-count').textContent = `${states.filter(([, s]) => s.user).length} 人在线`
}
provider.awareness.on('change', renderPresence)
renderPresence()

// --- the MoonBit server's own copy --------------------------------------------
const canonical = v => {
  if (Array.isArray(v)) return v.map(canonical)
  if (v && typeof v === 'object') {
    return Object.fromEntries(Object.keys(v).sort().map(k => [k, canonical(v[k])]))
  }
  return v
}
const sameJson = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b))

function localStateVector () {
  const sv = Y.decodeStateVector(Y.encodeStateVector(ydoc))
  return [...sv.entries()].sort((a, b) => a[0] - b[0])
}

// Renders a Quill delta as HTML: inline marks on text runs, block formats on
// the newline that ends each line.
function renderDelta (delta) {
  const out = document.createDocumentFragment()
  let line = []
  let listCounter = 0
  const flush = attrs => {
    const a = attrs || {}
    let el
    if (a.header === 1) el = document.createElement('h3')
    else if (a.header === 2) el = document.createElement('h4')
    else if (a['code-block']) el = document.createElement('pre')
    else if (a.blockquote) el = document.createElement('blockquote')
    else el = document.createElement('p')
    if (a.list === 'ordered') { listCounter++; el.dataset.marker = listCounter + '.' } else if (a.list) { el.dataset.marker = '•'; listCounter = 0 } else listCounter = 0
    if (a.list) el.classList.add('li')
    for (const seg of line) el.append(seg)
    if (!line.length) el.append(document.createElement('br'))
    out.append(el)
    line = []
  }
  for (const op of delta) {
    if (typeof op.insert !== 'string') continue
    const parts = op.insert.split('\n')
    parts.forEach((part, i) => {
      if (part) {
        let node = document.createTextNode(part)
        const a = op.attributes || {}
        for (const [mark, tag] of [['bold', 'strong'], ['italic', 'em'], ['underline', 'u'], ['strike', 's']]) {
          if (a[mark]) { const w = document.createElement(tag); w.append(node); node = w }
        }
        if (a.link) { const w = document.createElement('a'); w.href = a.link; w.rel = 'noreferrer'; w.target = '_blank'; w.append(node); node = w }
        line.push(node)
      }
      if (i < parts.length - 1) flush(op.attributes)
    })
  }
  if (line.length) flush(null)
  return out
}

let lastServer = null
async function pollServer () {
  try {
    const res = await fetch(`/api/rooms/${encodeURIComponent(room)}`, { cache: 'no-store' })
    if (!res.ok) throw new Error(res.status + ' ' + res.statusText)
    const snap = await res.json()
    lastServer = snap
    const serverDelta = (snap.deltas && snap.deltas.quill) || []
    const view = $('server-doc')
    view.innerHTML = ''
    if (serverDelta.length) view.append(renderDelta(serverDelta))
    else view.innerHTML = '<p class="soft">服务端文档还是空的。</p>'
    $('srv-conns').textContent = snap.connections
    $('srv-bytes').textContent = snap.updateBytes.toLocaleString('zh-CN') + ' 字节'
    $('srv-sv').textContent = snap.stateVector.length
      ? snap.stateVector.slice().sort((a, b) => a[0] - b[0]).map(([c, k]) => `${c}:${k}`).join('  ')
      : '{}'
    const sameDoc = sameJson(serverDelta, ytext.toDelta())
    const sameSv = sameJson(snap.stateVector.slice().sort((a, b) => a[0] - b[0]), localStateVector())
    const verdict = $('srv-verdict')
    if (!provider.wsconnected) {
      verdict.textContent = '本窗口已断开：服务端看不到你离线期间的修改，重新连接后会自动补齐'
      verdict.dataset.state = 'off'
    } else if (sameDoc && sameSv) {
      verdict.textContent = '服务端副本与本窗口完全一致（内容与状态向量）'
      verdict.dataset.state = 'on'
    } else {
      verdict.textContent = '同步中…'
      verdict.dataset.state = 'wait'
    }
    $('srv-error').hidden = true
  } catch (e) {
    $('srv-error').hidden = false
    $('srv-error').textContent = '读取服务端快照失败：' + e.message
  }
}
setInterval(() => { if (!document.hidden) pollServer() }, 800)
pollServer()

// a little seed text for a fresh room, written by the first window only;
// it goes through Quill so the formatting is exactly what Quill produces
provider.once('sync', synced => {
  if (synced && ytext.length === 0 && !params.has('empty')) {
    quill.setContents([
      { insert: 'ymoon 协同编辑演示' },
      { insert: '\n', attributes: { header: 1 } },
      { insert: '浏览器里是官方 yjs 和 Quill，服务端是用 ' },
      { insert: 'MoonBit', attributes: { bold: true } },
      { insert: ' 写的 ymoon。\n' },
      { insert: '试试加粗、列表、标题' },
      { insert: '\n', attributes: { list: 'bullet' } },
      { insert: '再打开一个窗口，两边同时编辑' },
      { insert: '\n', attributes: { list: 'bullet' } }
    ], 'user')
  }
})
