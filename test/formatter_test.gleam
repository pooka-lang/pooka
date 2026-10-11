//// Give the brackets somewhere calm to sit.
////
//// Exercise spacing, indentation, continuations and comment preservation, then
//// use the format command against temporary files. Invalid syntax must be left
//// alone, and check mode must report a difference without rewriting the
//// source.

import birdie
import cli/command
import gleam/string
import simplifile
import support
import tools/formatter

/// Require successful formatting before comparing the returned text. Invalid-
/// source cases bypass this helper so rejection remains observable.
fn format(source: String) -> String {
  let assert Ok(formatted) = formatter.format(source)
  formatted
}

pub fn indentation_is_normalised_test() {
  assert format("module main\n\nf() {\n      let x = 1\n        x\n}\n")
    == "module main\n\nf() {\n  let x = 1\n  x\n}\n"
}

pub fn nested_blocks_indent_by_level_test() {
  assert format(
      "module main\n\nf(x) {\nmatch x {\nTrue -> {\n1\n}\nFalse -> 2\n}\n}\n",
    )
    == "module main\n\nf(x) {\n  match x {\n    True -> {\n      1\n    }\n    False -> 2\n  }\n}\n"
}

pub fn several_brackets_on_one_line_indent_once_test() {
  assert format(
      "module main\n\nf(items) {\nitems\n|> list.map(fn(item) {\nitem * 2\n})\n}\n",
    )
    == "module main\n\nf(items) {\n  items\n  |> list.map(fn(item) {\n    item * 2\n  })\n}\n"
}

pub fn multi_line_arguments_indent_test() {
  assert format("module main\n\nf() {\ncreate(\n\"Lucy\",\n42,\n)\n}\n")
    == "module main\n\nf() {\n  create(\n    \"Lucy\",\n    42,\n  )\n}\n"
}

pub fn as_continuations_are_indented_test() {
  assert format(
      "module main\n\nf() {\nlet assert Ok(config) = load()\nas \"must load\"\nconfig\n}\n",
    )
    == "module main\n\nf() {\n  let assert Ok(config) = load()\n    as \"must load\"\n  config\n}\n"
}

pub fn spacing_is_normalised_test() {
  assert format(
      "module main\n\nf( a :Int,b:   Int ) -> Int{\nlet t=#( a,b )\n[ a ,b ]|>g( )\n-a+  b*2\n}\n",
    )
    == "module main\n\nf(a: Int, b: Int) -> Int {\n  let t = #(a, b)\n  [a, b] |> g()\n  -a + b * 2\n}\n"
}

pub fn unary_and_binary_minus_test() {
  assert format("module main\n\nf(a, b) { a-b + -a * (-b) }\n")
    == "module main\n\nf(a, b) {\n  a - b + -a * (-b)\n}\n"
}

pub fn calls_fields_and_propagation_are_tight_test() {
  assert format("module main\n\nf() { parse( source ) ? . name }\n")
    == "module main\n\nf() {\n  parse(source)?.name\n}\n"
}

pub fn imports_and_paths_are_tight_test() {
  assert format("module main\n\nimport http / client.{ User , load as l }\n")
    == "module main\n\nimport http/client.{User, load as l}\n"
}

pub fn bit_array_options_are_tight_test() {
  assert format(
      "module main\n\nf(size, payload) { << size : 16 , payload : bits - unit(8) >> }\n",
    )
    == "module main\n\nf(size, payload) {\n  <<size:16, payload:bits-unit(8)>>\n}\n"
}

pub fn list_tails_and_empty_braces_test() {
  assert format(
      "module main\n\nclass Shape { }\nf(x) { match x { [ first , .. rest ] -> first\n[] -> 0 } }\n",
    )
    == "module main\n\nclass Shape {}\n\nf(x) {\n  match x {\n    [first, ..rest] -> first\n    [] -> 0\n  }\n}\n"
}

pub fn blank_lines_are_collapsed_test() {
  assert format("module main\n\n\n\nf() {\n\n  1\n\n}\n\n\ng() { 2 }\n")
    == "module main\n\nf() {\n  1\n}\n\ng() {\n  2\n}\n"
}

pub fn comments_are_preserved_test() {
  let source =
    "//// Module docs.\n\nmodule main\n\n/// Adds.\nadd(a, b) {\n  // Ordinary.\n  a + b // trailing\n}\n"
  assert format(source) == source
}

pub fn trailing_whitespace_and_final_newline_test() {
  assert format("module main   \nf() { 1 }   ")
    == "module main\n\nf() {\n  1\n}\n"
}

pub fn invalid_source_is_not_formatted_test() {
  let assert Error(formatter.LexErrors(_)) =
    formatter.format("module main\n\nf() { \"open }\n")
  let assert Error(formatter.SyntaxErrors(_)) =
    formatter.format("module main\n\nf( {\n")
}

pub fn formatting_snapshot_test() {
  format(
    "//// A messy file.\nmodule main\n\nimport io\nclass Animal{\nlet name:String\nnew(name){self.name=name}\n  speak( ) -> String{\"...\"}\n}\n\n\nmain(){\nlet a=Animal(\"Rex\")\nmatch a{\nAnimal(n)->io.println(n)\n}\n}\n",
  )
  |> birdie.snap(title: "formatter: a messy file")
}

fn project(directory: String, source: String) -> Nil {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", source)
}

pub fn format_rewrites_files_test() {
  use directory <- support.with_directory("format_rewrite")
  project(directory, "module main\n\nmain( ) {Nil}\n")
  let outcome = support.cli_main(["format"], command.plain(directory))
  assert outcome.status == 0
  assert outcome.stdout == ""
  assert string.contains(outcome.stderr, "Formatted 1 file in 0µs")
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\n\nmain() {\n  Nil\n}\n")

  let again = support.cli_main(["format"], command.plain(directory))
  assert again.stdout == ""
  assert string.contains(again.stderr, "Formatted 0 files in 0µs")
}

// Check mode inspects the difference and leaves the original file untouched.
// A nonzero result is not permission to rewrite it.
pub fn format_check_reports_without_writing_test() {
  use directory <- support.with_directory("format_check")
  project(directory, "module main\n\nmain( ) {Nil}\n")
  let outcome =
    support.cli_main(["format", "--check"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "src/main.pooka")
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\n\nmain( ) {Nil}\n")
  let _ = support.cli_main(["format"], command.plain(directory))
  let clean = support.cli_main(["format", "--check"], command.plain(directory))
  assert clean.status == 0
}

pub fn format_refuses_files_with_errors_test() {
  use directory <- support.with_directory("format_errors")
  project(directory, "module main\n\nmain() { \"open }\n")
  let outcome = support.cli_main(["format"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "unterminated string")
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\n\nmain() { \"open }\n")
}

pub fn format_explicit_files_test() {
  use directory <- support.with_directory("format_explicit")
  project(directory, "module main\n\nmain( ) {Nil}\n")
  support.write(directory <> "/src/other.pooka", "module other\n\nf( ) {1}\n")
  let outcome =
    support.cli_main(["format", "src/other.pooka"], command.plain(directory))
  assert outcome.status == 0
  assert simplifile.read(directory <> "/src/other.pooka")
    == Ok("module other\n\nf() {\n  1\n}\n")
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\n\nmain( ) {Nil}\n")
}
