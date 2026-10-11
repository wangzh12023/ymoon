// Builds the playground page from the MoonBit JS output.
//
//   moon build --target js --release          (from the repository root)
//   node examples/playground/build.mjs
//
// Writes dist/wire-bench.html (page fragment) and docs/index.html (full
// document for GitHub Pages).
import { build } from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../..')
const { ymoonJsPath } = await import('../../oracle/find-build.mjs')
const entry = ymoonJsPath()
const result = await build({
  entryPoints: [entry],
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: '__ymoon',
  write: false,
  target: 'es2020'
})
let bundle = result.outputFiles[0].text
if (bundle.includes('</script')) bundle = bundle.replaceAll('</script', '<\/script')
const template = fs.readFileSync(path.join(here, 'template.html'), 'utf8')
const page = template.replace('/* YMOON_BUNDLE */', () => bundle)
fs.mkdirSync(path.join(root, 'dist'), { recursive: true })
fs.writeFileSync(path.join(root, 'dist/wire-bench.html'), page)
const full = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n</head>\n<body>\n' + page + '\n</body>\n</html>\n'
fs.mkdirSync(path.join(root, 'docs'), { recursive: true })
fs.writeFileSync(path.join(root, 'docs/index.html'), full)
console.log(`wire bench: ${(page.length / 1024).toFixed(0)} KiB (ymoon bundle ${(bundle.length / 1024).toFixed(0)} KiB)`)
