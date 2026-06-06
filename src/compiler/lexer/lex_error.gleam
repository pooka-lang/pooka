//// Leave a clear note where the scanner lost its footing.
////
//// Represent lexical failures with source spans and stable diagnostic
//// identifiers. Rendering is deferred so the same problem can reach a terminal or
//// a JSON consumer.
////
//// ```text
//// an unclosed string -> span + lex diagnostic
//// ```

// SPDX-License-Identifier: Apache-2.0

import diagnostics/diagnostic.{type Diagnostic}
import gleam/int
import gleam/string
import utilities/location.{type Span}

pub type Radix {
  Binary
  Octal
  Decimal
  Hexadecimal
}

pub type NumberProblem {

  MissingDigits(radix: Radix)

  InvalidDigit(radix: Radix, digit: String)

  MisplacedSeparator

  ExponentWithoutPoint

  TrailingCharacters(text: String)
}

pub type UnicodeEscapeProblem {

  MissingBraces

  WrongDigitCount

  NotHexadecimal

  NotAScalarValue
}

pub type LexError {

  UnterminatedString(span: Span)

  InvalidEscape(span: Span, sequence: String)

  InvalidUnicodeEscape(
    span: Span,
    sequence: String,
    problem: UnicodeEscapeProblem,
  )

  InvalidNumber(span: Span, text: String, problem: NumberProblem)

  UnexpectedCharacters(span: Span, text: String)

  BlockComment(span: Span)

  SingleQuotedString(span: Span, content: String)

  TypographicString(span: Span, content: String)
}

pub fn span(error: LexError) -> Span {
  case error {
    UnterminatedString(span:) -> span
    InvalidEscape(span:, ..) -> span
    InvalidUnicodeEscape(span:, ..) -> span
    InvalidNumber(span:, ..) -> span
    UnexpectedCharacters(span:, ..) -> span
    BlockComment(span:) -> span
    SingleQuotedString(span:, ..) -> span
    TypographicString(span:, ..) -> span
  }
}

pub fn id(error: LexError) -> String {
  case error {
    UnterminatedString(..) -> "lex.unterminated_string"
    InvalidEscape(..) -> "lex.invalid_escape"
    InvalidUnicodeEscape(..) -> "lex.invalid_unicode_escape"
    InvalidNumber(..) -> "lex.invalid_number"
    UnexpectedCharacters(..) -> "lex.unexpected_characters"
    BlockComment(..) -> "lex.block_comment"
    SingleQuotedString(..) -> "lex.single_quoted_string"
    TypographicString(..) -> "lex.typographic_string"
  }
}

pub fn to_diagnostic(error: LexError, path: String) -> Diagnostic {
  let at = location.new(path, span(error))
  case error {
    UnterminatedString(..) ->
      diagnostic.error(id(error), "unterminated string")
      |> diagnostic.primary(at, "string starts here but never ends")
      |> diagnostic.conclusion("Expected a closing `\"`.")
      |> diagnostic.note(
        "Strings end on the line where they start. Write `\\n` for a line break.",
      )

    InvalidEscape(sequence:, ..) ->
      diagnostic.error(id(error), "unknown escape sequence")
      |> diagnostic.primary(at, "this escape sequence is not recognised")
      |> diagnostic.conclusion(
        "`" <> sequence <> "` is not an escape sequence that Pooka understands.",
      )
      |> diagnostic.note(
        "The escape sequences are `\\\"`, `\\\\`, `\\f`, `\\n`, `\\r`, `\\t` and `\\u{...}`.",
      )
      |> diagnostic.help("Write `\\\\` to include a backslash in the string.")

    InvalidUnicodeEscape(sequence:, problem:, ..) ->
      diagnostic.error(id(error), "invalid unicode escape")
      |> diagnostic.primary(at, unicode_label(problem))
      |> diagnostic.conclusion(
        "`" <> sequence <> "` is not a valid unicode escape.",
      )
      |> diagnostic.help(
        "Write a code point as one to six hexadecimal digits in braces, such as `\\u{1F98C}`.",
      )

    InvalidNumber(text:, problem:, ..) ->
      number_diagnostic(error, at, text, problem)

    UnexpectedCharacters(text:, ..) -> unexpected_diagnostic(error, at, text)

    BlockComment(..) ->
      diagnostic.error(id(error), "block comments are not supported")
      |> diagnostic.primary(at, "a block comment starts here")
      |> diagnostic.conclusion("Pooka only has line comments.")
      |> diagnostic.help("Start each line of the comment with `//` instead.")

    SingleQuotedString(content:, ..) ->
      diagnostic.error(id(error), "single-quoted string")
      |> diagnostic.primary(at, "strings use double quotes")
      |> diagnostic.conclusion("Write `\"" <> content <> "\"` instead.")
      |> diagnostic.note("Pooka has no separate character type.")
      |> diagnostic.fix(
        at,
        "\"" <> content <> "\"",
        "Use double quotes",
        diagnostic.Suggested,
      )

    TypographicString(content:, ..) ->
      diagnostic.error(id(error), "typographic quotes")
      |> diagnostic.primary(at, "these are typographic quotes")
      |> diagnostic.conclusion(
        "Strings are written with plain double quotes: `\"" <> content <> "\"`.",
      )
      |> diagnostic.fix(
        at,
        "\"" <> content <> "\"",
        "Use plain double quotes",
        diagnostic.Automatic,
      )
  }
}

fn unicode_label(problem: UnicodeEscapeProblem) -> String {
  case problem {
    MissingBraces -> "the code point must be written in braces"
    WrongDigitCount -> "a code point has one to six hexadecimal digits"
    NotHexadecimal -> "only hexadecimal digits may appear here"
    NotAScalarValue -> "this is not a Unicode scalar value"
  }
}

fn number_diagnostic(
  error: LexError,
  at: location.Location,
  text: String,
  problem: NumberProblem,
) -> Diagnostic {
  let base =
    diagnostic.error(id(error), "invalid number")
    |> diagnostic.conclusion("`" <> text <> "` is not a valid number.")
  case problem {
    MissingDigits(radix) ->
      base
      |> diagnostic.primary(at, "this prefix needs digits after it")
      |> diagnostic.help(
        "Write at least one "
        <> radix_name(radix)
        <> " digit, such as `"
        <> example(radix)
        <> "`.",
      )

    InvalidDigit(radix, digit) ->
      base
      |> diagnostic.primary(
        at,
        "`" <> digit <> "` is not " <> article(radix_name(radix)) <> " digit",
      )
      |> diagnostic.note(
        string.capitalise(radix_name(radix))
        <> " numbers may only contain the digits "
        <> digits(radix)
        <> ".",
      )

    MisplacedSeparator ->
      base
      |> diagnostic.primary(at, "`_` must be between two digits")
      |> diagnostic.help(
        "Use single underscores between digits, as in `1_000_000`.",
      )

    ExponentWithoutPoint ->
      base
      |> diagnostic.primary(at, "an exponent needs a decimal point")
      |> diagnostic.help(
        "Write the number as a float with a decimal point, such as `"
        <> with_point(text)
        <> "`.",
      )

    TrailingCharacters(suffix) ->
      base
      |> diagnostic.primary(at, "`" <> suffix <> "` cannot follow a number")
      |> diagnostic.note("Pooka numbers do not have suffixes or units.")
  }
}

fn with_point(text: String) -> String {
  case string.split_once(text, "e"), string.split_once(text, "E") {
    Ok(#(mantissa, exponent)), _ -> mantissa <> ".0e" <> exponent
    Error(Nil), Ok(#(mantissa, exponent)) -> mantissa <> ".0E" <> exponent
    Error(Nil), Error(Nil) -> text <> ".0"
  }
}

fn article(word: String) -> String {
  case word {
    "a" <> _ | "e" <> _ | "i" <> _ | "o" <> _ | "u" <> _ -> "an " <> word
    _ -> "a " <> word
  }
}

fn radix_name(radix: Radix) -> String {
  case radix {
    Binary -> "binary"
    Octal -> "octal"
    Decimal -> "decimal"
    Hexadecimal -> "hexadecimal"
  }
}

fn digits(radix: Radix) -> String {
  case radix {
    Binary -> "`0` and `1`"
    Octal -> "`0` to `7`"
    Decimal -> "`0` to `9`"
    Hexadecimal -> "`0` to `9` and `A` to `F`"
  }
}

fn example(radix: Radix) -> String {
  case radix {
    Binary -> "0b1010"
    Octal -> "0o755"
    Decimal -> "42"
    Hexadecimal -> "0xFF"
  }
}

fn unexpected_diagnostic(
  error: LexError,
  at: location.Location,
  text: String,
) -> Diagnostic {
  let quoted = "`" <> text <> "`"
  case text {
    ";" | ";;" ->
      diagnostic.error(id(error), "unexpected semicolon")
      |> diagnostic.primary(at, "Pooka does not use semicolons")
      |> diagnostic.conclusion("Remove the " <> quoted <> ".")
      |> diagnostic.fix(at, "", "Remove the semicolon", diagnostic.Automatic)

    "#" ->
      diagnostic.error(id(error), "unexpected `#`")
      |> diagnostic.primary(at, "`#` must be followed by `(`")
      |> diagnostic.conclusion("Tuples are written `#(first, second)`.")

    _ -> {
      let base =
        diagnostic.error(id(error), case string.length(text) {
          1 -> "unexpected character"
          _ -> "unexpected characters"
        })
      case control_character(text) {
        Ok(code) ->
          base
          |> diagnostic.primary(at, "this is an invisible control character")
          |> diagnostic.conclusion(
            "The character U+" <> code <> " cannot appear in Pooka source.",
          )
        Error(Nil) ->
          case string.byte_size(text) > string.length(text) {
            True ->
              base
              |> diagnostic.primary(
                at,
                "not valid outside strings and comments",
              )
              |> diagnostic.conclusion(quoted <> " cannot be used here.")
              |> diagnostic.note(
                "Names may only contain ASCII letters, digits and underscores.",
              )
            False ->
              base
              |> diagnostic.primary(at, "this cannot start any Pooka syntax")
              |> diagnostic.conclusion(quoted <> " is not valid here.")
          }
      }
    }
  }
}

fn control_character(text: String) -> Result(String, Nil) {
  case string.to_utf_codepoints(text) {
    [codepoint] -> {
      let code = string.utf_codepoint_to_int(codepoint)
      case code < 32 || code == 127 {
        True -> Ok(string.pad_start(int.to_base16(code), to: 4, with: "0"))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}
