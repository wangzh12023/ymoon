import * as Y from 'yjs'
const hex = u8 => Buffer.from(u8).toString('hex')
const d = new Y.Doc(); d.clientID = 1
const t = d.getText('t')
const ups = []
d.on('update', u => ups.push(hex(u)))
t.insert(0, 'hello')
t.insert(5, ' world')
t.delete(0, 1)
t.format(0, 4, { bold: true })
console.log(JSON.stringify({ ups, full: hex(Y.encodeStateAsUpdate(d)), str: t.toString(), delta: t.toDelta() }, null, 1))
