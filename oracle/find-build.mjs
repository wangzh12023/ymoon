// Locates ymoon's JavaScript build output. A plain module build writes
// _build/js/release/build/js/js.js; inside the moon.work workspace the
// path is prefixed with the module name.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

export function ymoonJsPath (profile = 'release') {
  const candidates = [
    path.join(root, `_build/js/${profile}/build/wangzh12023/ymoon/js/js.js`),
    path.join(root, `_build/js/${profile}/build/js/js.js`)
  ]
  const found = candidates.filter(p => fs.existsSync(p))
  if (found.length === 0) {
    throw new Error(`ymoon JS build not found; run \`moon build --target js --${profile}\` first`)
  }
  // prefer the most recent build
  return found.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0]
}
