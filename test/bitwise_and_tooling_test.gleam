//// Some marks have no job in this language.
////
//// Record unsupported bitwise spellings without disturbing Boolean operators,
//// pipes or bit-array brackets. The remaining checks follow enums and concise
//// classes into formatting and documentation, where newly accepted syntax must
//// remain recognisable.

import builder/docs
import compiler/lexer/lexer
import gleam/list
import gleam/string
import simplifile
import support
import tools/formatter

fn ids(expression: String) -> List(String) {
  support.diagnostic_ids(
    "module main\nf(a: Int, b: Int) {\n  " <> expression <> "\n}\n",
  )
}

// Reject unsupported punctuation at the lexical boundary. Its appearance must
// not be mistaken for a new arithmetic operator by later phases.
pub fn a_caret_is_not_an_operator_test() {
  assert ids("a ^ b") == ["lex.unexpected_characters"]
}

pub fn a_tilde_is_not_an_operator_test() {
  assert ids("~a") == ["lex.unexpected_characters"]
}

pub fn compound_bitwise_assignments_do_not_exist_test() {
  assert ids("a ^= b") != []
}

pub fn shift_operators_do_not_exist_test() {
  assert ids("a << 2") != []
  assert ids("a >> 2") != []
}

pub fn boolean_operators_still_work_test() {
  assert support.diagnostic_ids(
      "module main\nf(a: Bool, b: Bool) { #(a && b, a || b, !a) }\n",
    )
    == []
}

pub fn the_pipe_still_works_test() {
  assert ids("a |> fn(x) { x }") == []
}

pub fn bit_arrays_still_use_double_angle_brackets_test() {
  assert ids("<<a:8, b:16>>") == []
}

pub fn bitwise_characters_lex_as_errors_test() {
  ["^", "~"]
  |> list.each(fn(character) {
    let lexed = lexer.lex("a " <> character <> " b")
    assert list.length(lexed.errors) == 1
  })
}

fn formats_unchanged(source: String) -> Bool {
  formatter.format(source) == Ok(source)
}

pub fn formatted_enums_are_stable_test() {
  assert formats_unchanged(
    "module main\n\n/// Severity.\nenum Severity {\n  /// Bad.\n  Error\n  Warning\n  Notice\n}\n",
  )
  assert formats_unchanged(
    "module main\n\nenum Direction {\n  North,\n  South\n}\n",
  )
}

pub fn enums_are_indented_test() {
  assert formatter.format(
      "module main\n\nenum Severity {\nError\n    Warning\n}\n",
    )
    == Ok("module main\n\nenum Severity {\n  Error\n  Warning\n}\n")
}

pub fn formatted_concise_classes_are_stable_test() {
  assert formats_unchanged("module main\n\nclass Point(x: Float, y: Float)\n")
  assert formats_unchanged(
    "module main\n\nclass User(\n  name: String,\n  age: Int,\n) is Person {\n  greet() -> String {\n    name\n  }\n}\n",
  )
}

pub fn concise_fields_are_spaced_test() {
  assert formatter.format("module main\n\nclass Point(x:Float,y :Float)\n")
    == Ok("module main\n\nclass Point(x: Float, y: Float)\n")
}

pub fn enum_patterns_are_formatted_test() {
  assert formatter.format(
      "module main\n\nf(v) {\n  match v {\n    Colour . Red -> 1\n    lib.Colour.Blue->2\n  }\n}\n",
    )
    == Ok(
      "module main\n\nf(v) {\n  match v {\n    Colour.Red -> 1\n    lib.Colour.Blue -> 2\n  }\n}\n",
    )
}

pub fn enums_and_their_variants_are_documented_test() {
  use directory <- support.with_directory("docs_enums")
  support.write(
    directory <> "/pooka.toml",
    "name = \"docs_enums\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/levels.pooka",
    "module levels\n\n/// How serious it is.\nenum Severity {\n  /// Cannot continue.\n  Error\n  Warning\n}\n\nenum _Hidden { Secret }\n\n/// A located message.\nclass Message(text: String, severity: Severity)\n",
  )
  let assert Ok(report) = docs.generate(directory)
  let assert Ok(page) =
    simplifile.read(report.directory <> "/module-levels.html")
  assert string.contains(page, "symbol-Severity")
  assert string.contains(page, "How serious it is.")
  assert string.contains(page, "symbol-Severity.Error")
  assert string.contains(page, "symbol-Severity.Warning")
  assert string.contains(page, "Cannot continue.")
  assert string.contains(page, "symbol-Message")
  assert string.contains(page, "symbol-Message.text")
  assert !string.contains(page, "_Hidden")
}
