///|
/// Human readable error message.
pub impl Show for DecodeError with fn output(self, logger) {
  match self {
    UnexpectedEnd(pos~) =>
      logger.write_string("unexpected end of input at byte \{pos}")
    IntegerOutOfRange(pos~) =>
      logger.write_string("integer out of range at byte \{pos}")
    InvalidUtf8(pos~) =>
      logger.write_string("invalid UTF-8 string at byte \{pos}")
    UnknownTag(pos~, tag~) =>
      logger.write_string("unknown tag \{tag} at byte \{pos}")
    Malformed(pos~, reason~) =>
      logger.write_string("malformed input at byte \{pos}: \{reason}")
  }
}

///|
/// Human readable error message.
pub impl Show for JsonError with fn output(self, logger) {
  match self {
    InvalidJson(pos~) => logger.write_string("invalid JSON at offset \{pos}")
  }
}
