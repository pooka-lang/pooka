//// The scanner sorts the letters before the parser opens the envelopes.
////
//// Walk source bytes into located tokens while accumulating lexical problems.
//// Preserve trivia for tools, and remove delimiters by byte positions so a
//// combining mark cannot leave with its quote.
////
//// ```text
//// let total = 12 -> Let, Name(total), Equal, Int(12)
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/lex_error.{type LexError}
import compiler/lexer/token.{type Lexeme, type Token, Lexeme}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import utilities/location.{type Position, Position, Span}

pub type Lexed {
  Lexed(tokens: List(Lexeme), errors: List(LexError))
}

/// Scan the original source, keeping token spellings and spans even when a
/// recoverable lexical error occurs.
///
/// ```text
/// let n = 42 -> located Let, Name, Equal and Int tokens
/// ```
pub fn lex(source: String) -> Lexed {
  lex_loop(source, source, location.start(), [], [])
}

/// Remove comment trivia for consumers that do not need source decoration.
/// Formatting and documentation retain the original stream instead.
///
/// ```text
/// a value followed by a comment -> the value token remains
/// ```
pub fn significant(tokens: List(Lexeme)) -> List(Lexeme) {
  list.filter(tokens, fn(lexeme) { !token.is_trivia(lexeme.token) })
}

fn lex_loop(
  source: String,
  rest: String,
  position: Position,
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  let fixed = fn(token: Token, rest: String, width: Int) -> Lexed {
    let end = advance(position, columns: width, bytes: width)
    lex_loop(
      source,
      rest,
      end,
      [lexeme(token, position, end), ..lexemes],
      errors,
    )
  }

  case rest {
    "" ->
      Lexed(
        tokens: list.reverse([
          lexeme(token.EndOfFile, position, position),
          ..lexemes
        ]),
        errors: list.reverse(errors)
          |> list.append(unexpected_errors(lexemes))
          |> list.sort(fn(first, second) {
            location.compare(lex_error.span(first), lex_error.span(second))
          }),
      )

    "////" <> rest ->
      comment(source, rest, position, 4, token.ModuleComment, lexemes, errors)
    "///" <> rest ->
      comment(source, rest, position, 3, token.DocComment, lexemes, errors)
    "//" <> rest ->
      comment(source, rest, position, 2, token.Comment, lexemes, errors)
    "/*" <> rest -> block_comment(source, rest, position, lexemes, errors)

    "\r\n" <> rest ->
      lex_loop(source, rest, next_line(position, bytes: 2), lexemes, errors)
    "\n" <> rest | "\r" <> rest ->
      lex_loop(source, rest, next_line(position, bytes: 1), lexemes, errors)
    " " <> rest | "\t" <> rest ->
      lex_loop(
        source,
        rest,
        advance(position, columns: 1, bytes: 1),
        lexemes,
        errors,
      )

    "!=" <> rest -> fixed(token.BangEqual, rest, 2)
    "#(" <> rest -> fixed(token.HashLeftParen, rest, 2)
    "&&" <> rest -> fixed(token.DoubleAmpersand, rest, 2)
    "*=" <> rest -> fixed(token.StarEqual, rest, 2)
    "+=" <> rest -> fixed(token.PlusEqual, rest, 2)
    "-=" <> rest -> fixed(token.MinusEqual, rest, 2)
    "->" <> rest -> fixed(token.RightArrow, rest, 2)
    ".." <> rest -> fixed(token.DotDot, rest, 2)
    "<<" <> rest -> fixed(token.DoubleLess, rest, 2)
    "<=" <> rest -> fixed(token.LessEqual, rest, 2)
    "==" <> rest -> fixed(token.EqualEqual, rest, 2)
    ">=" <> rest -> fixed(token.GreaterEqual, rest, 2)
    ">>" <> rest -> fixed(token.DoubleGreater, rest, 2)
    "|>" <> rest -> fixed(token.Pipe, rest, 2)
    "||" <> rest -> fixed(token.DoubleBar, rest, 2)

    "0b" <> rest ->
      prefixed_number(source, rest, position, lex_error.Binary, lexemes, errors)
    "0o" <> rest ->
      prefixed_number(source, rest, position, lex_error.Octal, lexemes, errors)
    "0x" <> rest ->
      prefixed_number(
        source,
        rest,
        position,
        lex_error.Hexadecimal,
        lexemes,
        errors,
      )

    "\"" <> rest -> string_literal(source, rest, position, lexemes, errors)
    "'" <> rest ->
      misquoted_string(
        source,
        rest,
        position,
        "'",
        "'",
        SingleQuotes,
        lexemes,
        errors,
      )
    "“" <> rest ->
      misquoted_string(
        source,
        rest,
        position,
        "“",
        "”",
        TypographicQuotes,
        lexemes,
        errors,
      )

    "!" <> rest -> fixed(token.Bang, rest, 1)
    "&" <> rest -> fixed(token.Ampersand, rest, 1)
    "|" <> rest -> fixed(token.Bar, rest, 1)
    "%" <> rest -> fixed(token.Percent, rest, 1)
    "(" <> rest -> fixed(token.LeftParen, rest, 1)
    ")" <> rest -> fixed(token.RightParen, rest, 1)
    "*" <> rest -> fixed(token.Star, rest, 1)
    "+" <> rest -> fixed(token.Plus, rest, 1)
    "," <> rest -> fixed(token.Comma, rest, 1)
    "-" <> rest -> fixed(token.Minus, rest, 1)
    "." <> rest -> fixed(token.Dot, rest, 1)
    "/" <> rest -> fixed(token.Slash, rest, 1)
    ":" <> rest -> fixed(token.Colon, rest, 1)
    "<" <> rest -> fixed(token.Less, rest, 1)
    "=" <> rest -> fixed(token.Equal, rest, 1)
    ">" <> rest -> fixed(token.Greater, rest, 1)
    "?" <> rest -> fixed(token.Question, rest, 1)
    "[" <> rest -> fixed(token.LeftSquare, rest, 1)
    "]" <> rest -> fixed(token.RightSquare, rest, 1)
    "{" <> rest -> fixed(token.LeftBrace, rest, 1)
    "}" <> rest -> fixed(token.RightBrace, rest, 1)

    "0" <> _
    | "1" <> _
    | "2" <> _
    | "3" <> _
    | "4" <> _
    | "5" <> _
    | "6" <> _
    | "7" <> _
    | "8" <> _
    | "9" <> _ -> decimal_number(source, rest, position, lexemes, errors)

    "a" <> after
    | "b" <> after
    | "c" <> after
    | "d" <> after
    | "e" <> after
    | "f" <> after
    | "g" <> after
    | "h" <> after
    | "i" <> after
    | "j" <> after
    | "k" <> after
    | "l" <> after
    | "m" <> after
    | "n" <> after
    | "o" <> after
    | "p" <> after
    | "q" <> after
    | "r" <> after
    | "s" <> after
    | "t" <> after
    | "u" <> after
    | "v" <> after
    | "w" <> after
    | "x" <> after
    | "y" <> after
    | "z" <> after
    | "A" <> after
    | "B" <> after
    | "C" <> after
    | "D" <> after
    | "E" <> after
    | "F" <> after
    | "G" <> after
    | "H" <> after
    | "I" <> after
    | "J" <> after
    | "K" <> after
    | "L" <> after
    | "M" <> after
    | "N" <> after
    | "O" <> after
    | "P" <> after
    | "Q" <> after
    | "R" <> after
    | "S" <> after
    | "T" <> after
    | "U" <> after
    | "V" <> after
    | "W" <> after
    | "X" <> after
    | "Y" <> after
    | "Z" <> after
    | "_" <> after -> {
      let #(after, size) = scan_name(after, 1)
      let text = slice_bytes(source, position.byte_offset, size)
      fixed(name_token(text), after, size)
    }

    _ ->
      case string.pop_grapheme(rest) {
        Ok(#(grapheme, rest)) -> {
          let end = advance_text(position, grapheme)
          lex_loop(
            source,
            rest,
            end,
            push_unexpected(lexemes, grapheme, position, end),
            errors,
          )
        }
        Error(Nil) -> lex_loop(source, "", position, lexemes, errors)
      }
  }
}

fn name_token(text: String) -> Token {
  use <- result.lazy_unwrap(token.keyword(text))
  case text, first_letter(text) {
    "_", _ -> token.Underscore
    _, Ok(letter) ->
      case
        string.uppercase(letter) == letter && string.lowercase(letter) != letter
      {
        True -> token.UpperName(text)
        False -> token.Name(text)
      }
    _, Error(Nil) -> token.Name(text)
  }
}

fn first_letter(text: String) -> Result(String, Nil) {
  case string.pop_grapheme(text) {
    Ok(#("_", rest)) -> first_letter(rest)
    Ok(#(letter, _)) -> Ok(letter)
    Error(Nil) -> Error(Nil)
  }
}

fn scan_name(rest: String, size: Int) -> #(String, Int) {
  case rest {
    "a" <> after
    | "b" <> after
    | "c" <> after
    | "d" <> after
    | "e" <> after
    | "f" <> after
    | "g" <> after
    | "h" <> after
    | "i" <> after
    | "j" <> after
    | "k" <> after
    | "l" <> after
    | "m" <> after
    | "n" <> after
    | "o" <> after
    | "p" <> after
    | "q" <> after
    | "r" <> after
    | "s" <> after
    | "t" <> after
    | "u" <> after
    | "v" <> after
    | "w" <> after
    | "x" <> after
    | "y" <> after
    | "z" <> after
    | "A" <> after
    | "B" <> after
    | "C" <> after
    | "D" <> after
    | "E" <> after
    | "F" <> after
    | "G" <> after
    | "H" <> after
    | "I" <> after
    | "J" <> after
    | "K" <> after
    | "L" <> after
    | "M" <> after
    | "N" <> after
    | "O" <> after
    | "P" <> after
    | "Q" <> after
    | "R" <> after
    | "S" <> after
    | "T" <> after
    | "U" <> after
    | "V" <> after
    | "W" <> after
    | "X" <> after
    | "Y" <> after
    | "Z" <> after
    | "0" <> after
    | "1" <> after
    | "2" <> after
    | "3" <> after
    | "4" <> after
    | "5" <> after
    | "6" <> after
    | "7" <> after
    | "8" <> after
    | "9" <> after
    | "_" <> after -> scan_name(after, size + 1)
    _ -> #(rest, size)
  }
}

fn comment(
  source: String,
  rest: String,
  position: Position,
  marker_size: Int,
  make: fn(String) -> Token,
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  let #(rest, size) = scan_line(rest, marker_size)
  let text = slice_bytes(source, position.byte_offset, size)
  let end = advance(position, columns: string.length(text), bytes: size)
  let content = string.drop_start(text, marker_size)
  lex_loop(
    source,
    rest,
    end,
    [lexeme(make(content), position, end), ..lexemes],
    errors,
  )
}

fn block_comment(
  source: String,
  rest: String,
  position: Position,
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  let #(body, rest) = case string.split_once(rest, "*/") {
    Ok(#(body, rest)) -> #("/*" <> body <> "*/", rest)
    Error(Nil) -> #("/*" <> rest, "")
  }
  let end = advance_text(position, body)
  let marker_end = advance(position, columns: 2, bytes: 2)
  let error = lex_error.BlockComment(Span(start: position, end: marker_end))
  let lexeme = lexeme(token.Comment(body), position, end)
  lex_loop(source, rest, end, [lexeme, ..lexemes], [error, ..errors])
}

fn scan_line(rest: String, size: Int) -> #(String, Int) {
  case rest {
    "" | "\n" <> _ | "\r" <> _ -> #(rest, size)
    _ -> scan_line(drop_bytes(rest, 1), size + 1)
  }
}

fn string_literal(
  source: String,
  rest: String,
  position: Position,
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  let #(rest, size, closed) = scan_string(rest, 1)
  let text = slice_bytes(source, position.byte_offset, size)
  let end = advance(position, columns: string.length(text), bytes: size)
  let content_start = position.byte_offset + 1
  let #(content, errors) = case closed {
    StringClosed -> #(slice_bytes(text, 1, size - 2), errors)
    StringUnterminated -> #(slice_bytes(text, 1, size - 1), [
      lex_error.UnterminatedString(Span(start: position, end: end)),
      ..errors
    ])
  }
  let errors =
    escape_errors(source, content, content_start)
    |> list.reverse
    |> list.append(errors)
  lex_loop(
    source,
    rest,
    end,
    [lexeme(token.String(content), position, end), ..lexemes],
    errors,
  )
}

type StringEnd {
  StringClosed
  StringUnterminated
}

fn scan_string(rest: String, size: Int) -> #(String, Int, StringEnd) {
  case rest {
    "" | "\n" <> _ | "\r" <> _ -> #(rest, size, StringUnterminated)
    "\"" <> after -> #(after, size + 1, StringClosed)

    "\\\n" <> _ | "\\\r" <> _ -> #(
      drop_bytes(rest, 1),
      size + 1,
      StringUnterminated,
    )
    "\\" <> after ->
      case string.pop_grapheme(after) {
        Ok(#(grapheme, after)) ->
          scan_string(after, size + 1 + string.byte_size(grapheme))
        Error(Nil) -> #("", size + 1, StringUnterminated)
      }
    _ -> scan_string(drop_bytes(rest, 1), size + 1)
  }
}

fn escape_errors(
  source: String,
  content: String,
  offset: Int,
) -> List(LexError) {
  escape_loop(source, content, offset, [])
}

fn escape_loop(
  source: String,
  rest: String,
  offset: Int,
  errors: List(LexError),
) -> List(LexError) {
  case rest {
    "" -> list.reverse(errors)
    "\\\"" <> after
    | "\\\\" <> after
    | "\\f" <> after
    | "\\n" <> after
    | "\\r" <> after
    | "\\t" <> after -> escape_loop(source, after, offset + 2, errors)
    "\\u{" <> after -> {
      let #(digits, after_digits) = take_hex_digits(after, "")
      let digit_count = string.length(digits)
      case string.pop_grapheme(after_digits) {
        Ok(#("}", after)) -> {
          let size = 3 + digit_count + 1
          let error = case digit_count, int.base_parse(digits, 16) {
            0, _ -> Ok(lex_error.WrongDigitCount)
            count, _ if count > 6 -> Ok(lex_error.WrongDigitCount)
            _, Ok(value) if value > 0x10FFFF -> Ok(lex_error.NotAScalarValue)
            _, Ok(value) if value >= 0xD800 && value <= 0xDFFF ->
              Ok(lex_error.NotAScalarValue)
            _, _ -> Error(Nil)
          }
          let errors = case error {
            Ok(problem) -> [
              unicode_error(source, offset, size, problem),
              ..errors
            ]
            Error(Nil) -> errors
          }
          escape_loop(source, after, offset + size, errors)
        }

        Ok(#(bad, after)) -> {
          let size = 3 + digit_count + string.byte_size(bad)
          let error =
            unicode_error(source, offset, size, lex_error.NotHexadecimal)
          escape_loop(source, after, offset + size, [error, ..errors])
        }

        Error(Nil) -> {
          let size = 3 + digit_count
          let error =
            unicode_error(source, offset, size, lex_error.MissingBraces)
          escape_loop(source, "", offset + size, [error, ..errors])
        }
      }
    }
    "\\u" <> after -> {
      let error = unicode_error(source, offset, 2, lex_error.MissingBraces)
      escape_loop(source, after, offset + 2, [error, ..errors])
    }
    "\\" <> after ->
      case string.pop_grapheme(after) {
        Ok(#(grapheme, after)) -> {
          let size = 1 + string.byte_size(grapheme)
          let error =
            lex_error.InvalidEscape(
              span: location.span(source, offset, offset + size),
              sequence: "\\" <> grapheme,
            )
          escape_loop(source, after, offset + size, [error, ..errors])
        }

        Error(Nil) -> list.reverse(errors)
      }
    _ ->
      case string.pop_grapheme(rest) {
        Ok(#(grapheme, after)) ->
          escape_loop(
            source,
            after,
            offset + string.byte_size(grapheme),
            errors,
          )
        Error(Nil) -> list.reverse(errors)
      }
  }
}

fn unicode_error(
  source: String,
  offset: Int,
  size: Int,
  problem: lex_error.UnicodeEscapeProblem,
) -> LexError {
  lex_error.InvalidUnicodeEscape(
    span: location.span(source, offset, offset + size),
    sequence: location.slice(source, offset, offset + size),
    problem: problem,
  )
}

fn take_hex_digits(rest: String, taken: String) -> #(String, String) {
  case string.pop_grapheme(rest) {
    Ok(#(grapheme, after)) ->
      case is_hex_digit(grapheme) {
        True -> take_hex_digits(after, taken <> grapheme)
        False -> #(taken, rest)
      }
    Error(Nil) -> #(taken, rest)
  }
}

fn is_hex_digit(grapheme: String) -> Bool {
  string.length(grapheme) == 1
  && string.contains("0123456789abcdefABCDEF", grapheme)
}

type Misquote {
  SingleQuotes
  TypographicQuotes
}

fn misquoted_string(
  source: String,
  rest: String,
  position: Position,
  open: String,
  close: String,
  misquote: Misquote,
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  let line = case string.split_once(rest, "\n") {
    Ok(#(line, _)) -> line
    Error(Nil) -> rest
  }
  case string.split_once(line, close) {
    Ok(#(content, _)) -> {
      let text = open <> content <> close
      let end = advance_text(position, text)
      let span = Span(start: position, end: end)
      let error = case misquote {
        SingleQuotes -> lex_error.SingleQuotedString(span:, content:)
        TypographicQuotes -> lex_error.TypographicString(span:, content:)
      }
      let rest = string.drop_start(rest, string.length(content <> close))
      let lexeme = lexeme(token.String(content), position, end)
      lex_loop(source, rest, end, [lexeme, ..lexemes], [error, ..errors])
    }
    Error(Nil) -> {
      let end = advance_text(position, open)
      lex_loop(
        source,
        rest,
        end,
        push_unexpected(lexemes, open, position, end),
        errors,
      )
    }
  }
}

fn decimal_number(
  source: String,
  rest: String,
  position: Position,
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  // After a projection dot, the next dot belongs to another projection.
  // Keep pair.0.1 as Dot, Int, Dot, Int while ordinary 0.1 stays a float.
  let previous = list.find(lexemes, fn(item) { !token.is_trivia(item.token) })
  let #(after, size, kind) = case previous {
    Ok(Lexeme(token: token.Dot, ..)) -> {
      let #(after, size) = scan_digits(rest, 0)
      #(after, size, IntegerNumber)
    }
    _ -> scan_number(rest, 0)
  }

  let #(after, size, problem) = case kind {
    FloatNumber -> #(after, size, Ok(Nil))
    IntegerNumber ->
      case scan_exponent(after, size) {
        #(after_exponent, exponent_size) if exponent_size > size -> #(
          after_exponent,
          exponent_size,
          Error(lex_error.ExponentWithoutPoint),
        )
        _ -> #(after, size, Ok(Nil))
      }
  }
  let main = slice_bytes(source, position.byte_offset, size)
  let #(after, suffix) = take_suffix(source, after, position.byte_offset + size)
  let problem = case problem, suffix {
    Error(problem), _ -> Error(problem)
    Ok(Nil), "" ->
      case valid_separators(main, lex_error.Decimal) {
        True -> Ok(Nil)
        False -> Error(lex_error.MisplacedSeparator)
      }
    Ok(Nil), _ -> Error(lex_error.TrailingCharacters(suffix))
  }
  let token = case kind {
    FloatNumber -> token.Float(main <> suffix)
    IntegerNumber -> token.Int(main <> suffix)
  }
  finish_number(
    source,
    after,
    position,
    main <> suffix,
    token,
    problem,
    lexemes,
    errors,
  )
}

fn prefixed_number(
  source: String,
  rest: String,
  position: Position,
  radix: lex_error.Radix,
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  let #(after, size) = case radix {
    lex_error.Binary -> scan_binary_digits(rest, 2)
    lex_error.Octal -> scan_octal_digits(rest, 2)
    lex_error.Hexadecimal -> scan_hex_digits(rest, 2)
    lex_error.Decimal -> scan_digits(rest, 2)
  }
  let main = slice_bytes(source, position.byte_offset, size)
  let digits = string.drop_start(main, 2)
  let #(after, suffix) = take_suffix(source, after, position.byte_offset + size)
  let problem = case
    string.pop_grapheme(suffix),
    string.replace(digits, "_", "")
  {
    Ok(#(first, _)), _ -> Error(lex_error.InvalidDigit(radix, first))
    Error(Nil), "" -> Error(lex_error.MissingDigits(radix))
    Error(Nil), _ ->
      case valid_separators(digits, radix) {
        True -> Ok(Nil)
        False -> Error(lex_error.MisplacedSeparator)
      }
  }
  let text = main <> suffix
  finish_number(
    source,
    after,
    position,
    text,
    token.Int(text),
    problem,
    lexemes,
    errors,
  )
}

fn finish_number(
  source: String,
  rest: String,
  position: Position,
  text: String,
  number: Token,
  problem: Result(Nil, lex_error.NumberProblem),
  lexemes: List(Lexeme),
  errors: List(LexError),
) -> Lexed {
  let size = string.byte_size(text)
  let end = advance(position, columns: size, bytes: size)
  let errors = case problem {
    Ok(Nil) -> errors
    Error(problem) -> [
      lex_error.InvalidNumber(Span(start: position, end: end), text, problem),
      ..errors
    ]
  }
  lex_loop(
    source,
    rest,
    end,
    [lexeme(number, position, end), ..lexemes],
    errors,
  )
}

fn take_suffix(source: String, rest: String, offset: Int) -> #(String, String) {
  let #(after, size) = scan_name(rest, 0)
  #(after, slice_bytes(source, offset, size))
}

fn valid_separators(digits: String, radix: lex_error.Radix) -> Bool {
  let digit_rules =
    !string.starts_with(digits, "_")
    && !string.ends_with(digits, "_")
    && !string.contains(digits, "__")
  case radix {
    lex_error.Decimal ->
      digit_rules
      && list.all(["_.", "._", "_e", "e_", "_E", "E_", "-_", "+_"], fn(pair) {
        !string.contains(digits, pair)
      })
    lex_error.Binary | lex_error.Octal | lex_error.Hexadecimal -> digit_rules
  }
}

type NumberKind {
  IntegerNumber
  FloatNumber
}

fn scan_digits(rest: String, size: Int) -> #(String, Int) {
  case rest {
    "0" <> after
    | "1" <> after
    | "2" <> after
    | "3" <> after
    | "4" <> after
    | "5" <> after
    | "6" <> after
    | "7" <> after
    | "8" <> after
    | "9" <> after
    | "_" <> after -> scan_digits(after, size + 1)
    _ -> #(rest, size)
  }
}

fn scan_number(rest: String, size: Int) -> #(String, Int, NumberKind) {
  let #(rest, size) = scan_digits(rest, size)
  case rest {
    ".0" <> after
    | ".1" <> after
    | ".2" <> after
    | ".3" <> after
    | ".4" <> after
    | ".5" <> after
    | ".6" <> after
    | ".7" <> after
    | ".8" <> after
    | ".9" <> after -> {
      let #(rest, size) = scan_digits(after, size + 2)
      let #(rest, size) = scan_exponent(rest, size)
      #(rest, size, FloatNumber)
    }
    _ -> #(rest, size, IntegerNumber)
  }
}

fn scan_exponent(rest: String, size: Int) -> #(String, Int) {
  let #(marker, after) = case rest {
    "e+" <> after | "e-" <> after | "E+" <> after | "E-" <> after -> #(2, after)
    "e" <> after | "E" <> after -> #(1, after)
    _ -> #(0, rest)
  }
  case marker, after {
    0, _ -> #(rest, size)
    _, "0" <> _
    | _, "1" <> _
    | _, "2" <> _
    | _, "3" <> _
    | _, "4" <> _
    | _, "5" <> _
    | _, "6" <> _
    | _, "7" <> _
    | _, "8" <> _
    | _, "9" <> _
    -> scan_digits(after, size + marker)
    _, _ -> #(rest, size)
  }
}

fn scan_hex_digits(rest: String, size: Int) -> #(String, Int) {
  case rest {
    "0" <> after
    | "1" <> after
    | "2" <> after
    | "3" <> after
    | "4" <> after
    | "5" <> after
    | "6" <> after
    | "7" <> after
    | "8" <> after
    | "9" <> after
    | "a" <> after
    | "b" <> after
    | "c" <> after
    | "d" <> after
    | "e" <> after
    | "f" <> after
    | "A" <> after
    | "B" <> after
    | "C" <> after
    | "D" <> after
    | "E" <> after
    | "F" <> after
    | "_" <> after -> scan_hex_digits(after, size + 1)
    _ -> #(rest, size)
  }
}

fn scan_binary_digits(rest: String, size: Int) -> #(String, Int) {
  case rest {
    "0" <> after | "1" <> after | "_" <> after ->
      scan_binary_digits(after, size + 1)
    _ -> #(rest, size)
  }
}

fn scan_octal_digits(rest: String, size: Int) -> #(String, Int) {
  case rest {
    "0" <> after
    | "1" <> after
    | "2" <> after
    | "3" <> after
    | "4" <> after
    | "5" <> after
    | "6" <> after
    | "7" <> after
    | "_" <> after -> scan_octal_digits(after, size + 1)
    _ -> #(rest, size)
  }
}

fn push_unexpected(
  lexemes: List(Lexeme),
  text: String,
  start: Position,
  end: Position,
) -> List(Lexeme) {
  case lexemes {
    [Lexeme(token: token.Unexpected(previous), span:), ..rest]
      if span.end == start
    -> [lexeme(token.Unexpected(previous <> text), span.start, end), ..rest]
    _ -> [lexeme(token.Unexpected(text), start, end), ..lexemes]
  }
}

fn unexpected_errors(lexemes: List(Lexeme)) -> List(LexError) {
  list.filter_map(lexemes, fn(lexeme) {
    case lexeme.token {
      token.Unexpected(text) ->
        Ok(lex_error.UnexpectedCharacters(span: lexeme.span, text: text))
      _ -> Error(Nil)
    }
  })
}

fn lexeme(token: Token, start: Position, end: Position) -> Lexeme {
  Lexeme(token: token, span: Span(start: start, end: end))
}

fn advance(
  position: Position,
  columns columns: Int,
  bytes bytes: Int,
) -> Position {
  Position(
    line: position.line,
    column: position.column + columns,
    byte_offset: position.byte_offset + bytes,
  )
}

fn next_line(position: Position, bytes bytes: Int) -> Position {
  Position(
    line: position.line + 1,
    column: 1,
    byte_offset: position.byte_offset + bytes,
  )
}

fn advance_text(position: Position, text: String) -> Position {
  case location.lines(text) {
    [only] ->
      advance(
        position,
        columns: string.length(only),
        bytes: string.byte_size(text),
      )
    lines -> {
      let last = result.unwrap(list.last(lines), "")
      Position(
        line: position.line + list.length(lines) - 1,
        column: string.length(last) + 1,
        byte_offset: position.byte_offset + string.byte_size(text),
      )
    }
  }
}

fn drop_bytes(text: String, bytes: Int) -> String {
  slice_bytes(text, bytes, string.byte_size(text) - bytes)
}

@external(erlang, "binary", "part")
fn slice_bytes(text: String, from: Int, size: Int) -> String
