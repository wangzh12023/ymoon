# ymoon-server

A [y-websocket](https://github.com/yjs/y-websocket) compatible collaboration
server written entirely in MoonBit: [ymoon](../) provides the Yjs document and
the sync/awareness protocols, `moonbitlang/async` provides HTTP and WebSocket.

```sh
# from the repository root: a workspace resolves ymoon from this checkout
moon work init . server
moon -C server run main --target native -- 1234
```

Clients connect to `ws://localhost:1234/<room-name>`; every room keeps one
shared document in memory and fans out document and awareness updates.

`moonbitlang/async` currently supports Linux and macOS (and Windows with
MSVC). The CI job `native-server` builds this server and runs
`oracle/e2e-native-server.mjs`, in which official `y-websocket` clients edit
through it.
