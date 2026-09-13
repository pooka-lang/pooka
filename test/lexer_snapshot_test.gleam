//// Keep a small tray of complete token streams.
////
//// Snapshot representative lexical output, including trivia, spans and invalid
//// input. These readable streams complement the focused token assertions in
//// lexer_test; a changed token boundary or position should be visible rather
//// than hidden by a helper.

import birdie
import compiler/lexer/lexer
import support

// Keep trivia and source positions in these snapshots. The significant-token
// helper used by ordinary assertions deliberately leaves those details out.
fn lexemes(source: String) -> String {
  lexer.lex(source).tokens
  |> lexer.significant
  |> support.pretty
}

pub fn function_declaration_tokens_test() {
  lexemes("add(a: Int, b: Int): Int {\n  a + b\n}\n")
  |> birdie.snap(title: "lexer: a function declaration with spans")
}

pub fn literal_tokens_test() {
  lexemes("[1_000, 0xFF, 2.5e3, \"Καλημέρα\", True, Nil, #(1, 2), <<1>>]")
  |> birdie.snap(title: "lexer: literals with spans")
}

pub fn comment_tokens_test() {
  lexer.lex("//// Module docs.\n/// Item docs.\n// Ordinary.\nx // trailing\n")
  |> support.pretty
  |> birdie.snap(title: "lexer: the three kinds of comment")
}

pub fn operator_tokens_test() {
  lexemes("input |> parse()? && !done || a <= b != c\ncount += 1")
  |> birdie.snap(title: "lexer: operators")
}

pub fn crlf_tokens_test() {
  lexemes("let a = 1\r\nlet b = 2\r\n")
  |> birdie.snap(title: "lexer: CRLF line endings advance one line each")
}

pub fn invalid_input_tokens_test() {
  lexemes("let x = 0b12 + @ \"open")
  |> birdie.snap(title: "lexer: tokens produced for invalid input")
}

pub fn lex_errors_as_data_test() {
  lexer.lex("@ 0b12 1__0 \"\\q\" 1e10 ; /* x */").errors
  |> support.pretty
  |> birdie.snap(title: "lexer: errors as data")
}

pub fn unterminated_string_diagnostic_test() {
  support.rendered("module main\n\nmain() {\n  let name = \"Lucy\n}\n")
  |> birdie.snap(title: "lex diagnostic: unterminated string")
}

pub fn invalid_escape_diagnostic_test() {
  support.rendered("module main\n\nmain() {\n  \"C:\\Users\"\n}\n")
  |> birdie.snap(title: "lex diagnostic: invalid escape")
}

pub fn invalid_unicode_escape_diagnostic_test() {
  support.rendered("module main\n\nmain() {\n  \"\\u{110000}\"\n}\n")
  |> birdie.snap(title: "lex diagnostic: invalid unicode escape")
}

pub fn invalid_numbers_diagnostic_test() {
  support.rendered(
    "module main\n\nmain() {\n  0b102\n  0o9\n  0x\n  1__000\n  1e10\n  12px\n}\n",
  )
  |> birdie.snap(title: "lex diagnostic: invalid numbers")
}

pub fn semicolon_diagnostic_test() {
  support.rendered("module main\n\nmain() {\n  let x = 1;\n}\n")
  |> birdie.snap(title: "lex diagnostic: semicolon")
}

pub fn unexpected_characters_diagnostic_test() {
  support.rendered(
    "module main\n\nmain() {\n  let a = 'x'\n  let b = “quoted”\n  let c = a ^ b\n  let d = ~a\n  let e = #x\n  let f = café @@\n}\n",
  )
  |> birdie.snap(title: "lex diagnostic: unexpected characters")
}

pub fn block_comment_diagnostic_test() {
  support.rendered(
    "module main\n\n/* A block\n   comment. */\nmain() {\n  Nil\n}\n",
  )
  |> birdie.snap(title: "lex diagnostic: block comment")
}

pub fn lex_error_on_tabbed_line_test() {
  support.rendered("module main\n\nmain() {\n\tlet x = 0b2\n}\n")
  |> birdie.snap(title: "lex diagnostic: error on a tab-indented line")
}

pub fn lex_error_after_multibyte_text_test() {
  support.rendered("module main\n\nmain() {\n  let s = \"Καλημέρα\" @\n}\n")
  |> birdie.snap(title: "lex diagnostic: error after multi-byte text")
}
