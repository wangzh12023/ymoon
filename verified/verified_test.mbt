///|
test "find_range on delete-set shaped input" {
  let starts : FixedArray[Int] = [0, 5, 10, 100]
  let lens : FixedArray[Int] = [3, 2, 50, 1]
  assert_true(@verified.check_ranges(starts, lens))
  debug_inspect(@verified.find_range(starts, lens, 0), content="Some(0)")
  debug_inspect(@verified.find_range(starts, lens, 3), content="None")
  debug_inspect(@verified.find_range(starts, lens, 6), content="Some(1)")
  debug_inspect(@verified.find_range(starts, lens, 59), content="Some(2)")
  debug_inspect(@verified.find_range(starts, lens, 60), content="None")
  debug_inspect(@verified.find_range(starts, lens, 100), content="Some(3)")
  debug_inspect(@verified.find_range(starts, lens, 2147483647), content="None")
}

///|
test "find_range near Int max does not overflow" {
  let starts : FixedArray[Int] = [2147483600]
  let lens : FixedArray[Int] = [47]
  debug_inspect(
    @verified.find_range(starts, lens, 2147483646),
    content="Some(0)",
  )
  debug_inspect(@verified.find_range(starts, lens, 2147483647), content="None")
}

///|
test "missing_offset" {
  debug_inspect(@verified.missing_offset(0, 5, 0), content="Some(0)")
  debug_inspect(@verified.missing_offset(0, 5, 3), content="Some(3)")
  debug_inspect(@verified.missing_offset(0, 5, 5), content="None")
  debug_inspect(@verified.missing_offset(10, 5, 3), content="Some(0)")
}

///|
test "merge_ranges" {
  debug_inspect(@verified.merge_ranges(0, 5, 5, 3), content="Some((0, 8))")
  debug_inspect(@verified.merge_ranges(0, 5, 2, 1), content="Some((0, 5))")
  debug_inspect(@verified.merge_ranges(0, 5, 6, 1), content="None")
}

///|
test "check_ranges rejects overlaps and empty ranges" {
  assert_false(@verified.check_ranges([0, 4], [5, 1]))
  assert_false(@verified.check_ranges([0, 9], [0, 1]))
  assert_false(@verified.check_ranges([0], [1, 2]))
  assert_true(@verified.check_ranges([], []))
}

///|
test "property: find_range agrees with a linear scan" {
  @quickcheck.check((xs : Array[UInt16]) => {
    // build sorted disjoint ranges from random gaps/lengths
    let starts : Array[Int] = []
    let lens : Array[Int] = []
    let mut pos = 0
    for i, x in xs {
      let v = x.to_int()
      if i % 2 == 0 {
        pos += v % 7
      } else {
        let len = 1 + v % 5
        starts.push(pos)
        lens.push(len)
        pos += len
      }
    }
    let sa = FixedArray::from_array(starts)
    let la = FixedArray::from_array(lens)
    @verified.check_ranges(sa, la) &&
    (0)
    .until(pos + 3)
    .iter()
    .all(clock => {
      let linear = for i in 0..<starts.length() {
        if starts[i] <= clock && clock < starts[i] + lens[i] {
          break Some(i)
        }
      } nobreak {
        None
      }
      @verified.find_range(sa, la, clock) == linear
    })
  })
}
