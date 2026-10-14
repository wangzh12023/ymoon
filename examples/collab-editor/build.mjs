// Bundles the browser client and inlines it, with Quill's CSS, into
// dist/index.html.
//
//   npm install && node build.mjs
import { build } from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const result = await build({
  entryPoints: [path.join(here, 'client.js')],
  bundle: true,
  minify: !process.env.DEBUG_BUILD,
  format: 'iife',
  target: 'es2020',
  write: false,
  legalComments: 'none'
})
const escape = s => s.replaceAll('</script', '<\\/script').replaceAll('</style', '<\\/style')
const js = escape(result.outputFiles[0].text)
const css = escape(
  fs.readFileSync(path.join(here, 'node_modules/quill/dist/quill.snow.css'), 'utf8') + '\n' +
  fs.readFileSync(path.join(here, 'node_modules/quill-cursors/dist/quill-cursors.min.css'), 'utf8')
)
const page = fs.readFileSync(path.join(here, 'template.html'), 'utf8')
  .replace('/* QUILL_CSS */', () => css)
  .replace('/* CLIENT_BUNDLE */', () => js)
fs.mkdirSync(path.join(here, 'dist'), { recursive: true })
fs.writeFileSync(path.join(here, 'dist/index.html'), page)
console.log(`collab editor: dist/index.html, ${(page.length / 1024).toFixed(0)} KiB`)
