// netwerk — text I/O helpers over the minimal Core io library.
//
// The Carbon toolchain's Core library currently exposes only character-level
// stdin/stdout (ReadChar/PrintChar/PrintStr/Print). Everything else — integer
// parsing with pushback, unpadded and padded integer printing — is built here.

library "io_utils";

import Core library "io";

// One-character pushback buffer. -2 = empty, -1 = EOF.
var pushback: i32 = -2;

fn Ord(ch: char) -> i32 {
  return (ch as u8) as i32;
}

fn ReadCh() -> i32 {
  if (pushback != -2) {
    var c: i32 = pushback;
    pushback = -2;
    return c;
  }
  var v: i32 = Core.ReadChar();
  if (v == Core.EOF()) {
    return -1;
  }
  return v;
}

fn UnreadCh(c: i32) {
  pushback = c;
}

// Skips spaces, tabs, carriage returns, newlines, and commas — the fixture
// interchange format treats commas and line breaks interchangeably.
fn SkipSeparators() {
  while (true) {
    var c: i32 = ReadCh();
    if (c == Ord(' ') or c == Ord('\t') or c == Ord('\r') or
        c == Ord('\n') or c == Ord(',')) {
      continue;
    }
    UnreadCh(c);
    return;
  }
}

// Reads an optionally negative decimal integer after skipping separators.
// Returns false at EOF or if no digits are present.
fn ReadInt(ref out: i32) -> bool {
  SkipSeparators();
  var negative: bool = false;
  var c: i32 = ReadCh();
  if (c == Ord('-')) {
    negative = true;
    c = ReadCh();
  }
  if (c < Ord('0') or c > Ord('9')) {
    UnreadCh(c);
    return false;
  }
  var value: i32 = 0;
  while (c >= Ord('0') and c <= Ord('9')) {
    value = value * 10 + (c - Ord('0'));
    c = ReadCh();
  }
  UnreadCh(c);
  if (negative) {
    value = -value;
  }
  out = value;
  return true;
}

// Consumes one expected keyword character-by-character; returns false on
// mismatch (the mismatched character is pushed back).
fn ExpectWord(word: str) -> bool {
  SkipSeparators();
  var i: i32 = 0;
  let n: i32 = (word.Size() as i32);
  while (i < n) {
    var c: i32 = ReadCh();
    if (c != ((word[i as i64] as u8) as i32)) {
      UnreadCh(c);
      return false;
    }
    ++i;
  }
  return true;
}

fn PrintDigit(d: i32) {
  Core.PrintChar((((d + Ord('0')) as u8)) as char);
}

// Prints an i64 with no trailing newline.
fn PrintI64(v_in: i64) {
  var v: i64 = v_in;
  if (v < 0) {
    Core.PrintChar('-');
    v = -v;
  }
  var pow10: i64 = 1;
  while (v / 10 >= pow10) {
    pow10 = pow10 * 10;
  }
  while (pow10 != 0) {
    PrintDigit(((v / pow10) % 10) as i32);
    pow10 = pow10 / 10;
  }
}

fn PrintInt(v: i32) {
  PrintI64(v as i64);
}

// Prints an integer right-aligned in `width` columns.
fn PrintIntPad(v: i32, width: i32) {
  var digits: i32 = 1;
  var m: i32 = if v < 0 then -v else v;
  while (m >= 10) {
    m = m / 10;
    ++digits;
  }
  if (v < 0) {
    ++digits;
  }
  var pad: i32 = width - digits;
  while (pad > 0) {
    Core.PrintChar(' ');
    --pad;
  }
  PrintInt(v);
}

fn PrintI64Pad(v: i64, width: i32) {
  var digits: i32 = 1;
  var m: i64 = if v < 0 then -v else v;
  while (m >= 10) {
    m = m / 10;
    ++digits;
  }
  if (v < 0) {
    ++digits;
  }
  var pad: i32 = width - digits;
  while (pad > 0) {
    Core.PrintChar(' ');
    --pad;
  }
  PrintI64(v);
}

// Prints cents as a decimal currency amount, e.g. 123456 -> "1234.56".
fn PrintMoney(cents: i64) {
  var v: i64 = cents;
  if (v < 0) {
    Core.PrintChar('-');
    v = -v;
  }
  PrintI64(v / 100);
  Core.PrintChar('.');
  PrintDigit(((v / 10) % 10) as i32);
  PrintDigit((v % 10) as i32);
}

fn NL() {
  Core.PrintStr("\n");
}
