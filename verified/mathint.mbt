///|
/// Proof-side mathematical integers (Why3's unbounded `int`). Used only in
/// specifications so that `a + b` in a contract never overflows.
#proof_external("int.Int", "int")
priv type MathInt
