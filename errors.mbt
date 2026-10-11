///|
/// Human readable error message.
pub impl Show for TypeError with fn output(self, logger) {
  match self {
    LengthExceeded(index~, length~) =>
      logger.write_string("index \{index} exceeds length \{length}")
  }
}
