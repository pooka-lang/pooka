//// A literal arrives wearing its source spelling.
////
//// Decode numeric separators, bases and string escapes into their runtime values.
//// The lexer keeps the spelling and span; this layer interprets its contents.
////
//// ```text
//// 0xff -> 255; \u{301} -> a combining code point
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Interpret a lexer-validated integer spelling, including supported bases and
/// separators.
///
/// ```text
/// 0xff -> 255; 1_000 -> 1000
/// ```
pub fn parse_int(source: String) -> Result(Int, Nil) {
  let clean = string.replace(source, "_", "")
  let #(sign, magnitude) = case clean {
    "-" <> rest -> #(-1, rest)
    _ -> #(1, clean)
  }
  let value = case magnitude {
    "0x" <> digits | "0X" <> digits -> int.base_parse(digits, 16)
    "0o" <> digits | "0O" <> digits -> int.base_parse(digits, 8)
    "0b" <> digits | "0B" <> digits -> int.base_parse(digits, 2)
    _ -> int.parse(magnitude)
  }
  result.map(value, fn(value) { sign * value })
}

pub fn parse_float(source: String) -> Result(Float, Nil) {
  let clean = source |> string.replace("_", "") |> string.lowercase
  let clean = case string.contains(clean, ".") {
    True -> clean
    False ->
      case string.split_once(clean, "e") {
        Ok(#(mantissa, exponent)) -> mantissa <> ".0e" <> exponent
        Error(Nil) -> clean <> ".0"
      }
  }
  float.parse(clean)
}

/// Interpret escape sequences after the lexer has preserved the literal contents.
/// Return decoding failure rather than silently dropping invalid input.
///
/// ```text
/// the source escape 
///  -> a newline character
/// ```
pub fn decode_string(content: String) -> Result(String, Nil) {
  decode(content, [])
}

fn decode(content: String, reversed: List(String)) -> Result(String, Nil) {
  case content {
    "" -> Ok(reversed |> list.reverse |> string.concat)
    "\\n" <> rest -> decode(rest, ["\n", ..reversed])
    "\\r" <> rest -> decode(rest, ["\r", ..reversed])
    "\\t" <> rest -> decode(rest, ["\t", ..reversed])
    "\\f" <> rest -> decode(rest, ["\u{c}", ..reversed])
    "\\\"" <> rest -> decode(rest, ["\"", ..reversed])
    "\\\\" <> rest -> decode(rest, ["\\", ..reversed])
    "\\u{" <> rest -> {
      use #(digits, rest) <- result.try(string.split_once(rest, "}"))
      use value <- result.try(int.base_parse(digits, 16))
      use codepoint <- result.try(string.utf_codepoint(value))
      decode(rest, [string.from_utf_codepoints([codepoint]), ..reversed])
    }
    "\\" <> _ -> Error(Nil)
    _ -> {
      use #(first, rest) <- result.try(string.pop_grapheme(content))
      decode(rest, [first, ..reversed])
    }
  }
}
