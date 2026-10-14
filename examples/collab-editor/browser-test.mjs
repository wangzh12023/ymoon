// Real-browser end-to-end test of the demo: Quill editors in Chrome
// collaborate through the ymoon server; the wire bench compares ymoon and yjs
// byte for byte.
//
//   node browser-test.mjs                 (starts its own server)
//   node browser-test.mjs http://host:port  (uses a running server)
//
// CHROME_PATH selects the browser; SHOTS=<dir> saves screenshots.
import puppeteer from 'puppeteer-core'
import fs from 'node:fs'
import { startDemoServer } from './server.mjs'

const chromeCandidates = [
  process.env.CHROME_PATH,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
].filter(Boolean)
const executablePath = chromeCandidates.find(p => fs.existsSync(p))
if (!executablePath) {
  console.error('no Chrome/Edge found; set CHROME_PATH')
  process.exit(1)
}
let own = null
let base = process.argv[2]
if (!base) {
  own = await startDemoServer({ port: 0, quiet: true })
  base = `http://localhost:${own.port}`
}
const shots = process.env.SHOTS || null
const browser = await puppeteer.launch({
  executablePath,
  headless: true,
  protocolTimeout: 60000,
  args: ['--no-first-run', '--no-default-browser-check', '--disable-gpu', '--disable-dev-shm-usage',
    // CI runners on Ubuntu 24.04 block the user-namespace sandbox
    ...(process.env.CI ? ['--no-sandbox'] : [])]
})
const step = msg => { if (process.env.VERBOSE) console.error('step:', msg) }
const errors = []
const results = {}
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

async function open (url, label) {
  const page = await browser.newPage()
  await page.setViewport({ width: 1366, height: 900 })
  page.on('console', m => { if (m.type() === 'error') errors.push(`${label}: ${m.text()}`) })
  page.on('pageerror', e => errors.push(`${label}: ${e.message}`))
  await page.goto(url, { waitUntil: 'domcontentloaded' })
  return page
}
const until = async (page, fn, arg, ms = 8000) => page.waitForFunction(fn, { timeout: ms, polling: 100 }, arg)
const editorText = page => page.evaluate(() => window.__demo.quill.getText())
const delta = page => page.evaluate(() => JSON.stringify(window.__demo.ydoc.getText('quill').toDelta()))

const room = 'e2e-' + Date.now()
// --- collaborative editor --------------------------------------------------
step('open A')
const a = await open(`${base}/?room=${room}&name=Alice`, 'A')
await until(a, () => window.__demo && window.__demo.provider.synced)
await until(a, () => window.__demo.quill.getText().includes('ymoon'))
results.seeded = (await editorText(a)).split('\n')[0]

step('open B')
const b = await open(`${base}/?room=${room}&name=Bob`, 'B')
await until(b, () => window.__demo && window.__demo.provider.synced)
await until(b, () => window.__demo.quill.getText().includes('ymoon'))

step('typing A')
// type in A with the real keyboard at the end of the document
await a.bringToFront()
await a.click('.ql-editor')
await a.keyboard.down('Control'); await a.keyboard.press('End'); await a.keyboard.up('Control')
await a.keyboard.type('Alice 在这里输入。')
await until(b, () => window.__demo.quill.getText().includes('Alice 在这里输入'))
step('typing B')
// type in B at the start, concurrently
await b.bringToFront()
await b.click('.ql-editor')
await b.keyboard.down('Control'); await b.keyboard.press('Home'); await b.keyboard.up('Control')
await b.keyboard.type('Bob> ')
await until(a, () => window.__demo.quill.getText().startsWith('Bob> '))
step('bold')
// bold through the toolbar on A: select "Alice"
await a.evaluate(() => {
  const q = window.__demo.quill
  const i = q.getText().indexOf('Alice')
  q.setSelection(i, 5, 'user')
})
await a.bringToFront()
await a.click('.ql-bold')
await until(b, () => JSON.stringify(window.__demo.ydoc.getText('quill').toDelta()).includes('"insert":"Alice","attributes":{"bold":true}'))
results.boldReachedB = true

step('server snapshot')
// the MoonBit server's own copy equals both editors
await wait(300)
const snap = await (await fetch(`${base}/api/rooms/${room}`)).json()
const canon = v => Array.isArray(v) ? v.map(canon) : (v && typeof v === 'object') ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canon(v[k])])) : v
results.serverEqualsA = JSON.stringify(canon(snap.deltas.quill)) === JSON.stringify(canon(JSON.parse(await delta(a))))
results.serverEqualsB = JSON.stringify(canon(snap.deltas.quill)) === JSON.stringify(canon(JSON.parse(await delta(b))))
results.serverConnections = snap.connections
await until(a, () => document.getElementById('srv-verdict').dataset.state === 'on')
results.panelVerdictA = await a.$eval('#srv-verdict', el => el.textContent)
results.presenceA = await a.$eval('#presence-count', el => el.textContent)

step('cursors')
// remote cursor of Bob is rendered in A
results.remoteCursorsInA = await a.$$eval('.ql-cursor', els => els.length)

step('offline')
// offline editing on B, concurrent edit on A, reconnect
await b.bringToFront()
await b.click('#conn-toggle')
await until(b, () => document.getElementById('conn-state').dataset.state === 'off')
await b.evaluate(() => { const q = window.__demo.quill; q.insertText(q.getLength() - 1, '【B 离线时写的】', 'user') })
await a.evaluate(() => { const q = window.__demo.quill; q.insertText(0, '【A 同时写的】', 'user') })
await wait(500)
results.offlineDiverged = (await editorText(a)) !== (await editorText(b))
await b.bringToFront()
await b.click('#conn-toggle')
await until(b, () => window.__demo.provider.synced && window.__demo.quill.getText().includes('【A 同时写的】'), null, 10000)
await until(a, () => window.__demo.quill.getText().includes('【B 离线时写的】'), null, 10000)
results.convergedAfterReconnect = (await editorText(a)) === (await editorText(b))

step('late joiner')
// late joiner gets everything from the server
const c = await open(`${base}/?room=${room}&name=Carol`, 'C')
await until(c, () => window.__demo && window.__demo.provider.synced)
await until(c, () => window.__demo.quill.getText().includes('【B 离线时写的】'))
results.lateJoinerMatches = (await editorText(c)) === (await editorText(a))
results.finalText = (await editorText(a)).trim().slice(0, 160)

step('screenshots')
await a.bringToFront()
if (shots) await a.screenshot({ path: `${shots}/collab-light.png`, fullPage: true })
await a.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }])
if (shots) await a.screenshot({ path: `${shots}/collab-dark.png`, fullPage: true })
await a.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }])
await a.setViewport({ width: 400, height: 900 })
if (shots) await a.screenshot({ path: `${shots}/collab-phone.png`, fullPage: true })

step('wire bench')
// --- wire bench -----------------------------------------------------------
const w = await open(`${base}/wire-bench`, 'W')
await until(w, () => document.getElementById('verdict-main').textContent.includes('converged'))
await w.bringToFront()
await w.click('#moon-text')
await w.keyboard.type(' typed by MoonBit')
await w.click('#yjs-text')
await w.keyboard.type(' and by yjs')
await wait(300)
results.wireVerdict = await w.$eval('#verdict-main', el => el.textContent)
results.wireDetail = await w.$eval('#verdict-detail', el => el.textContent)
results.wireBothSame = await w.evaluate(() => document.getElementById('moon-text').value === document.getElementById('yjs-text').value)
results.wireDecoderRows = await w.$$eval('#fields li', els => els.length)
if (shots) await w.screenshot({ path: `${shots}/wire-light.png`, fullPage: true })

results.consoleErrors = errors
console.log(JSON.stringify(results, null, 1))
await browser.close()
if (own) await own.close()
const m = (results.wireDetail || '').match(/(\d+)\/(\d+)/)
const sameUpdates = m ? Number(m[1]) : -1
const comparedUpdates = m ? Number(m[2]) : 0
const ok = results.boldReachedB && results.serverEqualsA && results.serverEqualsB &&
  results.convergedAfterReconnect && results.lateJoinerMatches && results.offlineDiverged &&
  results.wireBothSame && comparedUpdates > 0 && sameUpdates === comparedUpdates && errors.length === 0
console.log(ok ? 'BROWSER E2E OK' : 'BROWSER E2E FAILED')
process.exit(ok ? 0 : 1)
