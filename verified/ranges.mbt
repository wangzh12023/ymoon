///|
/// Finds the range containing `clock` among sorted, disjoint clock ranges
/// `[starts[i], starts[i] + lens[i])`.
///
/// This is the lookup Yjs performs on delete sets (`findIndexDS`) and on the
/// per-client struct arrays (`findIndexSS`). The contract is proved with
/// `moon prove` under the bounded machine-integer model: the result covers
/// `clock`, `None` means no range does, and no arithmetic can overflow.
pub fn find_range(
  starts : FixedArray[Int],
  lens : FixedArray[Int],
  clock : Int,
) -> Int? where {
  proof_require: valid_ranges(starts, lens),
  proof_ensure: result => find_range_ok(starts, lens, clock, result),
} {
  for lo = 0, hi = starts.length(); lo < hi; {
    let mid = lo + (hi - lo) / 2
    let s = starts[mid]
    if s <= clock {
      // `clock - s < len` instead of `clock < s + len`: cannot overflow
      if clock - s < lens[mid] {
        proof_assert covers(starts, lens, mid, clock)
        proof_assert find_range_ok(starts, lens, clock, Some(mid))
        break Some(mid)
      }
      proof_assert mle(end_of(starts, lens, mid), m(clock))
      proof_assert ∀ i : Int,
        0 <= i && i <= mid → !covers(starts, lens, i, clock)
      continue mid + 1, hi
    } else {
      proof_assert clock < starts[mid]
      proof_assert ∀ i : Int,
        mid < i && i < starts.length() → starts[mid] < starts[i]
      proof_assert ∀ i : Int,
        mid <= i && i < starts.length() → clock < starts[i]
      proof_assert ∀ i : Int,
        mid <= i && i < starts.length() → !covers(starts, lens, i, clock)
      continue lo, mid
    }
  } nobreak {
    None
  } where {
    proof_invariant: 0 <= lo,
    proof_invariant: lo <= hi,
    proof_invariant: hi <= starts.length(),
    proof_invariant: ∀ i : Int,
      0 <= i && i < lo → !covers(starts, lens, i, clock),
    proof_invariant: ∀ i : Int,
      hi <= i && i < starts.length() → !covers(starts, lens, i, clock),
    proof_yield: res => find_range_ok(starts, lens, clock, res),
    proof_reasoning: (
      #| The window [lo, hi) contains every range that could still cover
      #| `clock`. If the middle range starts at or before `clock` but ends
      #| at or before it, every range up to `mid` ends no later (ranges are
      #| sorted and disjoint), so none of them covers `clock`. If it starts
      #| after `clock`, every later range starts even later. When the window
      #| is empty, the two exclusion invariants cover the whole array.
    ),
  }
}
