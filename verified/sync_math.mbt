///|
/// Decides which part of a struct a peer is missing during sync.
///
/// A struct covers clocks `[clock, clock + len)`. A peer that already knows
/// clocks `[0, known)` of the same client needs the struct iff
/// `clock + len > known`, starting at offset `max(known - clock, 0)`.
/// This is the core decision of `writeStructs` / `diffUpdate` in Yjs.
///
/// Proved: the offset lies inside the struct and skips exactly the clocks the
/// peer already has; no arithmetic overflows.
pub fn missing_offset(
  clock : Int,
  len : Int,
  known : Int,
) -> Int? where {
  proof_require: 0 <= clock && 0 < len && 0 <= known,
  proof_ensure: result => missing_offset_ok(clock, len, known, result),
} {
  // `known - clock < len` instead of `clock + len > known`: no overflow
  if known - clock < len {
    let off = if known > clock { known - clock } else { 0 }
    proof_assert 0 <= off && off < len
    Some(off)
  } else {
    None
  }
}

///|
/// Merges two adjacent or overlapping clock ranges `[a, a + alen)` and
/// `[b, b + blen)` with `a <= b` into one, as `sortAndMergeDeleteSet` does.
/// Returns None when the ranges are disjoint and not adjacent.
///
/// Proved: the merged range starts at `a`, contains both inputs and contains
/// nothing outside their union.
pub fn merge_ranges(
  a : Int,
  alen : Int,
  b : Int,
  blen : Int,
) -> (Int, Int)? where {
  proof_require: 0 <= a && 0 < alen && 0 <= b && 0 < blen && a <= b,
  proof_require: mle(madd(m(a), m(alen)), m(2147483647)),
  proof_require: mle(madd(m(b), m(blen)), m(2147483647)),
  proof_ensure: result => merge_ranges_ok(a, alen, b, blen, result),
} {
  // `b - a <= alen` instead of `a + alen >= b`
  if b - a <= alen {
    let len = if alen >= b - a + blen { alen } else { b - a + blen }
    Some((a, len))
  } else {
    None
  }
}

///|
/// Checks in a single linear pass that clock ranges are non-empty and that
/// each range ends before the next one starts (the shape of a normalised Yjs
/// delete set after `sortAndMergeDeleteSet`).
///
/// Proved: `true` means every range is non-empty and adjacent ranges are
/// ordered and disjoint; combined with `adjacent_ordered` being transitive
/// (exercised by the property tests) this is the precondition of `find_range`.
pub fn check_ranges(
  starts : FixedArray[Int],
  lens : FixedArray[Int],
) -> Bool where {
  proof_ensure: result => {
    result →
    starts.length() == lens.length() &&
    positive_lengths(starts, lens, starts.length()) &&
    adjacent_ordered(starts, lens, starts.length())
  },
} {
  if starts.length() != lens.length() {
    false
  } else {
    for i = 0; i < starts.length(); {
      if starts[i] < 0 || lens[i] <= 0 {
        break false
      } else if i > 0 && starts[i] - starts[i - 1] < lens[i - 1] {
        break false
      } else {
        continue i + 1
      }
    } nobreak {
      true
    } where {
      proof_invariant: 0 <= i && i <= starts.length(),
      proof_invariant: starts.length() == lens.length(),
      proof_invariant: positive_lengths(starts, lens, i),
      proof_invariant: adjacent_ordered(starts, lens, i),
      proof_yield: res => {
        res →
        starts.length() == lens.length() &&
        positive_lengths(starts, lens, starts.length()) &&
        adjacent_ordered(starts, lens, starts.length())
      },
    }
  }
}
