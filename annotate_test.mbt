///|
test "annotate_update covers every byte of a yjs update" {
  // update written by yjs@13.6.33 (see smoke_test.mbt)
  let doc = @ymoon.Doc(client_id=1)
  let ups : Array[Bytes] = []
  doc.on_update((u, _) => ups.push(u))
  let t = doc.get_text("t")
  t.insert(0, "hello")
  t.delete(0, 1)
  for u in ups {
    let segs = @ymoon.annotate_update(u)
    // contiguous, complete coverage
    let mut pos = 0
    for s in segs {
      assert_eq(s.start, pos)
      assert_true(s.end > s.start)
      pos = s.end
    }
    assert_eq(pos, u.length())
  }
  let lines = @ymoon.annotate_update(ups[0]).map(s => {
    "\{s.start}-\{s.end} \{s.kind.name()}: \{s.label}"
  })
  inspect(
    lines.join("\n"),
    content=(
      #|0-1 header: structs from 1 client(s)
      #|1-2 header: 1 struct(s) follow
      #|2-3 client: client 1
      #|3-4 clock: first clock 0
      #|4-5 info: String at 1:0
      #|5-8 parent: parent: root type "t"
      #|8-14 content: String("hello")
      #|14-15 delete-set: delete set: 0 client(s)
    ),
  )
}
