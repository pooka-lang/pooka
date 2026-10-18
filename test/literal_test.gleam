//// Different spellings can deliver the same value.
////
//// Decode numeric and string literals independently of parsing and inference.
//// Bases, signs, separators and escapes must agree with their semantic values.
//// These fixtures keep textual representation separate from the equality and
//// layout proofs that consume it.

import compiler/literal

pub fn integer_bases_signs_and_separators_test() {
  assert literal.parse_int("0xff") == Ok(255)
  assert literal.parse_int("-0xFF") == Ok(-255)
  assert literal.parse_int("0b1010_0101") == Ok(165)
  assert literal.parse_int("0o17") == Ok(15)
  assert literal.parse_int("1_000") == Ok(1000)
  assert literal.parse_int("123456789012345678901234567890")
    == Ok(123_456_789_012_345_678_901_234_567_890)
  assert literal.parse_int("0x") == Error(Nil)
  assert literal.parse_int("0b2") == Error(Nil)
}

// Literal spelling is not semantic identity. Different decimal and exponent
// spellings should decode to the same numeric value when they denote it.
pub fn scientific_floats_and_equivalent_spellings_test() {
  assert literal.parse_float("1e0") == Ok(1.0)
  assert literal.parse_float("1.0E2") == Ok(100.0)
  assert literal.parse_float("-1_0e-1") == Ok(-1.0)
  assert literal.parse_float("oops") == Error(Nil)
}

pub fn string_escapes_decode_to_semantic_values_test() {
  assert literal.decode_string("a\\n\\r\\t\\f\\\"\\\\")
    == Ok("a\n\r\t\u{c}\"\\")
  assert literal.decode_string("\\u{61}\\u{1f600}é") == Ok("a😀é")
  assert literal.decode_string("\\u{D800}") == Error(Nil)
  assert literal.decode_string("\\u{110000}") == Error(Nil)
  assert literal.decode_string("\\u{xyz}") == Error(Nil)
  assert literal.decode_string("\\u{61") == Error(Nil)
  assert literal.decode_string("\\q") == Error(Nil)
  assert literal.decode_string("\\") == Error(Nil)
}
