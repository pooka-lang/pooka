//// Read one mark carefully before naming the next.
////
//// Check keywords, identifiers, literals, operators, comments and malformed
//// input. Spans and recovery matter alongside token kinds: a multibyte
//// character must retain its bytes, and a lexical error must not swallow the
//// useful tokens after it.
////
//// ```text
//// letter -> a name, not the keyword let followed by ter
//// ```

import compiler/lexer/lex_error
import compiler/lexer/lexer
import compiler/lexer/token
import gleam/int
import gleam/list
import support
import utilities/location.{Position, Span}

pub fn every_keyword_is_recognised_test() {
  assert support.tokens(
      "actor as be assert break class continue external fn if import interface is let loop match module new panic self super test todo var with",
    )
    == [
      token.Actor, token.As, token.Be, token.Assert, token.Break, token.Class,
      token.Continue, token.External, token.Fn, token.If, token.Import,
      token.Interface, token.Is, token.Let, token.Loop, token.Match,
      token.Module, token.New, token.Panic, token.SelfKeyword, token.Super,
      token.Test, token.Todo, token.Var, token.With,
    ]
}

pub fn keyword_literals_test() {
  assert support.tokens("True False Nil")
    == [token.TrueLiteral, token.FalseLiteral, token.NilLiteral]
}

pub fn keywords_list_matches_the_reference_test() {
  assert list.length(token.keywords) == 28
  list.each(token.keywords, fn(word) {
    let assert Ok(_) = token.keyword(word)
  })
}

// Read the complete identifier before deciding it is a keyword. The beginning
// of classy does not create a class declaration.
pub fn keyword_prefixes_are_names_test() {
  assert support.tokens("letter classy iffy newer")
    == [
      token.Name("letter"),
      token.Name("classy"),
      token.Name("iffy"),
      token.Name("newer"),
    ]
}

pub fn lower_case_names_test() {
  assert support.tokens("user user_name find_user2")
    == [token.Name("user"), token.Name("user_name"), token.Name("find_user2")]
}

pub fn upper_case_names_test() {
  assert support.tokens("User HttpClient ParseError")
    == [
      token.UpperName("User"),
      token.UpperName("HttpClient"),
      token.UpperName("ParseError"),
    ]
}

// The leading underscore expresses visibility without changing the
// distinction between a value name and an upper-case type name.
pub fn private_names_keep_their_case_test() {
  assert support.tokens("_helper _User _field __double")
    == [
      token.Name("_helper"),
      token.UpperName("_User"),
      token.Name("_field"),
      token.Name("__double"),
    ]
}

pub fn bare_underscore_is_the_wildcard_test() {
  assert support.tokens("_ _x") == [token.Underscore, token.Name("_x")]
}

pub fn in_is_not_a_keyword_test() {
  assert support.tokens("in") == [token.Name("in")]
}

pub fn integers_test() {
  assert support.tokens("0 42 1_000_000 0b1010 0o755 0xFF 0xFF_FF")
    == [
      token.Int("0"),
      token.Int("42"),
      token.Int("1_000_000"),
      token.Int("0b1010"),
      token.Int("0o755"),
      token.Int("0xFF"),
      token.Int("0xFF_FF"),
    ]
}

pub fn floats_test() {
  assert support.tokens("0.0 3.14 1_000.25 1.0e10 6.022e23 1.5e-4 2.5E+3")
    == [
      token.Float("0.0"),
      token.Float("3.14"),
      token.Float("1_000.25"),
      token.Float("1.0e10"),
      token.Float("6.022e23"),
      token.Float("1.5e-4"),
      token.Float("2.5E+3"),
    ]
}

pub fn minus_is_not_part_of_a_number_test() {
  assert support.tokens("-42") == [token.Minus, token.Int("42")]
}

pub fn a_dot_after_an_integer_is_not_a_float_test() {
  assert support.tokens("1..") == [token.Int("1"), token.DotDot]
  assert support.tokens("x.0") == [token.Name("x"), token.Dot, token.Int("0")]
}

pub fn valid_numbers_have_no_errors_test() {
  assert lexer.lex("0 42 1_000 0b1010 0o17 0xDEAD_BEEF 3.14 1.5e-4").errors
    == []
}

pub fn invalid_binary_digit_test() {
  let assert [lex_error.InvalidNumber(text: "0b12", problem:, ..)] =
    lexer.lex("0b12").errors
  assert problem == lex_error.InvalidDigit(lex_error.Binary, "2")
}

pub fn invalid_octal_digit_test() {
  let assert [lex_error.InvalidNumber(problem:, ..)] = lexer.lex("0o78").errors
  assert problem == lex_error.InvalidDigit(lex_error.Octal, "8")
}

pub fn invalid_hexadecimal_digit_test() {
  let assert [lex_error.InvalidNumber(problem:, ..)] = lexer.lex("0xFG").errors
  assert problem == lex_error.InvalidDigit(lex_error.Hexadecimal, "G")
}

pub fn prefix_without_digits_test() {
  let assert [lex_error.InvalidNumber(problem:, ..)] = lexer.lex("0x").errors
  assert problem == lex_error.MissingDigits(lex_error.Hexadecimal)
}

pub fn misplaced_separators_test() {
  ["1__000", "1_", "1_.5", "0x_FF", "0b_1", "1_000_"]
  |> list.each(fn(source) {
    let assert [lex_error.InvalidNumber(problem:, ..)] =
      lexer.lex(source).errors
    assert problem == lex_error.MisplacedSeparator
  })
}

pub fn exponent_without_decimal_point_test() {
  let assert [lex_error.InvalidNumber(text: "1e10", problem:, ..)] =
    lexer.lex("1e10").errors
  assert problem == lex_error.ExponentWithoutPoint
}

pub fn letters_after_a_number_test() {
  let assert [lex_error.InvalidNumber(text: "12px", problem:, ..)] =
    lexer.lex("12px").errors
  assert problem == lex_error.TrailingCharacters("px")
}

pub fn a_bad_number_is_still_one_token_test() {
  assert support.tokens("0b12 + 1")
    == [token.Int("0b12"), token.Plus, token.Int("1")]
}

pub fn strings_keep_escapes_unprocessed_test() {
  assert support.tokens("\"Hello\" \"a\\nb\" \"Καλημέρα\"")
    == [token.String("Hello"), token.String("a\\nb"), token.String("Καλημέρα")]
}

pub fn every_valid_escape_test() {
  assert lexer.lex("\"\\\" \\\\ \\f \\n \\r \\t \\u{1F98C} \\u{0}\"").errors
    == []
}

pub fn invalid_escape_test() {
  let source = "\"a \\q b\""
  let assert [lex_error.InvalidEscape(span:, sequence: "\\q")] =
    lexer.lex(source).errors
  assert support.text_at(source, span) == "\\q"
}

pub fn invalid_unicode_escapes_test() {
  let problem = fn(source) {
    let assert [lex_error.InvalidUnicodeEscape(problem:, ..)] =
      lexer.lex(source).errors
    problem
  }
  assert problem("\"\\u{}\"") == lex_error.WrongDigitCount
  assert problem("\"\\u{1234567}\"") == lex_error.WrongDigitCount
  assert problem("\"\\u{110000}\"") == lex_error.NotAScalarValue
  assert problem("\"\\u{D800}\"") == lex_error.NotAScalarValue
  assert problem("\"\\u{12G4}\"") == lex_error.NotHexadecimal
  assert problem("\"\\u41\"") == lex_error.MissingBraces
}

pub fn unterminated_string_test() {
  let source = "let name = \"Lucy\nlet next = 1"
  let lexed = lexer.lex(source)
  let assert [lex_error.UnterminatedString(span:)] = lexed.errors
  assert support.text_at(source, span) == "\"Lucy"

  assert support.tokens(source)
    == [
      token.Let,
      token.Name("name"),
      token.Equal,
      token.String("Lucy"),
      token.Let,
      token.Name("next"),
      token.Equal,
      token.Int("1"),
    ]
}

pub fn a_string_cannot_continue_after_a_backslash_newline_test() {
  let assert [lex_error.UnterminatedString(span:), ..] =
    lexer.lex("\"abc\\\ndef\"").errors
  assert span.start.line == 1
}

pub fn operators_test() {
  assert support.tokens("+ - * / % == != < <= > >= && || ! |> = += -= *= -> ?")
    == [
      token.Plus, token.Minus, token.Star, token.Slash, token.Percent,
      token.EqualEqual, token.BangEqual, token.Less, token.LessEqual,
      token.Greater, token.GreaterEqual, token.DoubleAmpersand, token.DoubleBar,
      token.Bang, token.Pipe, token.Equal, token.PlusEqual, token.MinusEqual,
      token.StarEqual, token.RightArrow, token.Question,
    ]
}

pub fn punctuation_test() {
  assert support.tokens("( ) { } [ ] , : .. . #( << >>")
    == [
      token.LeftParen, token.RightParen, token.LeftBrace, token.RightBrace,
      token.LeftSquare, token.RightSquare, token.Comma, token.Colon,
      token.DotDot, token.Dot, token.HashLeftParen, token.DoubleLess,
      token.DoubleGreater,
    ]
}

pub fn longest_operator_wins_test() {
  assert support.tokens("a<=b")
    == [token.Name("a"), token.LessEqual, token.Name("b")]
  assert support.tokens("x|>f")
    == [token.Name("x"), token.Pipe, token.Name("f")]
}

pub fn propagation_chains_test() {
  assert support.tokens("parse(source)?.name")
    == [
      token.Name("parse"),
      token.LeftParen,
      token.Name("source"),
      token.RightParen,
      token.Question,
      token.Dot,
      token.Name("name"),
    ]
}

pub fn three_kinds_of_comment_test() {
  let lexed = lexer.lex("//// Module\n/// Declaration\n// Ordinary\nx")
  assert list.map(lexed.tokens, fn(lexeme) { lexeme.token })
    == [
      token.ModuleComment(" Module"),
      token.DocComment(" Declaration"),
      token.Comment(" Ordinary"),
      token.Name("x"),
      token.EndOfFile,
    ]
}

pub fn comments_after_code_test() {
  assert support.tokens("let retries = 3 // Maximum attempts.")
    == [token.Let, token.Name("retries"), token.Equal, token.Int("3")]
}

pub fn significant_drops_ordinary_comments_only_test() {
  let tokens = lexer.lex("// a\n/// b\nx").tokens |> lexer.significant
  assert list.map(tokens, fn(lexeme) { lexeme.token })
    == [token.DocComment(" b"), token.Name("x"), token.EndOfFile]
}

pub fn block_comments_are_reported_test() {
  let source = "/* one\ntwo */ x"
  let lexed = lexer.lex(source)
  let assert [lex_error.BlockComment(span:)] = lexed.errors
  assert support.text_at(source, span) == "/*"

  assert support.tokens(source) == [token.Name("x")]
}

pub fn unexpected_characters_are_merged_test() {
  let assert [lex_error.UnexpectedCharacters(text: "@@@", ..)] =
    lexer.lex("a @@@ b").errors
}

pub fn separate_unexpected_characters_are_separate_errors_test() {
  let errors = lexer.lex("a @ b $ c").errors
  assert list.length(errors) == 2
}

pub fn semicolons_are_unexpected_test() {
  let assert [lex_error.UnexpectedCharacters(text: ";", ..)] =
    lexer.lex("let x = 1;").errors
}

pub fn non_ascii_outside_strings_is_unexpected_test() {
  let assert [lex_error.UnexpectedCharacters(text: "é", ..)] =
    lexer.lex("café").errors
}

pub fn spans_are_exact_test() {
  let assert [first, second, ..] = lexer.lex("let x").tokens
  assert first.span == Span(Position(1, 1, 0), Position(1, 4, 3))
  assert second.span == Span(Position(1, 5, 4), Position(1, 6, 5))
}

pub fn lines_advance_on_every_kind_of_line_break_test() {
  let lines =
    lexer.lex("a\nb\r\nc\rd").tokens
    |> list.map(fn(lexeme) { lexeme.span.start.line })
  assert lines == [1, 2, 3, 4, 4]
}

pub fn columns_count_graphemes_test() {
  let assert [_, name, ..] = lexer.lex("\"é\" x").tokens

  assert name.span.start == Position(line: 1, column: 5, byte_offset: 5)
}

pub fn the_last_token_is_always_end_of_file_test() {
  let assert Ok(last) = list.last(lexer.lex("").tokens)
  assert last.token == token.EndOfFile
  let assert Ok(last) = list.last(lexer.lex("x @").tokens)
  assert last.token == token.EndOfFile
}

pub fn errors_come_in_source_order_test() {
  let spans =
    lexer.lex("@ \"\\q\" 0b2 ;").errors
    |> list.map(fn(error) { lex_error.span(error).start.byte_offset })
  assert spans == list.sort(spans, int.compare)
}

pub fn single_quoted_strings_are_one_error_test() {
  let source = "let a = 'x'"
  let lexed = lexer.lex(source)
  let assert [lex_error.SingleQuotedString(span:, content: "x")] = lexed.errors
  assert support.text_at(source, span) == "'x'"

  assert support.tokens(source)
    == [token.Let, token.Name("a"), token.Equal, token.String("x")]
}

pub fn typographic_strings_are_one_error_test() {
  let assert [lex_error.TypographicString(content: "quoted", ..)] =
    lexer.lex("“quoted”").errors
}

pub fn an_unclosed_single_quote_is_unexpected_test() {
  let assert [lex_error.UnexpectedCharacters(text: "'", ..)] =
    lexer.lex("a ' b").errors
}
