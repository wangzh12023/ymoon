// ymoon-server: a y-websocket compatible collaboration server, 100% MoonBit.
//
//   moon run main --target native -- 1234
//
// Point any y-websocket client (Tiptap, BlockNote, Monaco or CodeMirror
// bindings, ...) at ws://localhost:1234/<room-name>.

///|
async fn main {
  let args = @env.args()
  let port = match args.get(1) {
    Some(p) => @string.parse_int(p) catch { _ => 1234 }
    None => 1234
  }
  let hub = @protocols.Hub()
  let next_conn = Ref(0)
  let server = @http.Server(@socket.Addr::parse("0.0.0.0:\{port}"))
  println("ymoon-server listening on ws://localhost:\{port}/<room>")
  server.run_forever((request, _body, conn) => {
    let room_name = match request.path.strip_prefix("/") {
      Some(rest) => rest.split("?").next().unwrap_or("").to_owned()
      None => request.path
    }
    let room = hub.room(if room_name == "" { "default" } else { room_name })
    let ws = @websocket.from_http_server(request, conn)
    defer ws.close()
    next_conn.val += 1
    let id = next_conn.val
    // the room pushes outgoing messages synchronously; a queue decouples
    // them from the async socket writes
    let outbox : @aqueue.Queue[Bytes] = @aqueue.Queue(kind=Unbounded)
    room.connect(id, msg => ignore(outbox.try_put(msg) catch { _ => false }))
    defer room.disconnect(id)
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        for ;; {
          let msg = outbox.get()
          ws.send_binary(msg)
        }
      })
      for ;; {
        let msg = ws.recv()
        let data = msg.read_all().binary()
        room.receive(id, data) catch {
          e => println("conn \{id}: \{e}")
        }
      }
    })
  })
}
