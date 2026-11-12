//// Read a numbered pocket without changing the coat around it.
////
//// Projections must survive parsing, typing, formatting and BEAM execution.
//// The index is zero-based in Pooka, and points at its own diagnostic span.

import birdie
import builder/check
import cli/command
import compiler/lexer/token
import compiler/parser/ast
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/string
import support
import tools/formatter
import utilities/colour

fn run(name: String, source: String) -> command.Outcome {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
  support.cli_main(["run"], command.plain(directory))
}

fn errors(source: String) -> List(diagnostic.Diagnostic) {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> source),
      dict.new(),
      unify.new(),
      "src/main.pooka",
    )
  report.diagnostics
}

pub fn tuple_index_has_its_own_ast_and_span_test() {
  let assert ast.TupleAccess(
    subject: ast.Variable("pair", subject_span),
    index: 1,
    index_span:,
    ..,
  ) = support.expression("pair.1")
  assert index_span.start.byte_offset == subject_span.end.byte_offset + 1
  assert index_span.end.byte_offset == index_span.start.byte_offset + 1
}

pub fn chained_indices_are_not_lexed_as_floats_test() {
  assert support.tokens("pair.0.1")
    == [
      token.Name("pair"),
      token.Dot,
      token.Int("0"),
      token.Dot,
      token.Int("1"),
    ]
  assert support.tokens("0.1 + 2.0")
    == [token.Float("0.1"), token.Plus, token.Float("2.0")]
  let assert ast.TupleAccess(
    subject: ast.TupleAccess(index: 0, ..),
    index: 1,
    ..,
  ) = support.expression("pair.0.1")
}

pub fn typed_projections_and_class_members_coexist_test() {
  assert errors(
      "class Box(value: Int)\nread(pair: #(Box, String)) -> Int { pair.0.value }\ntext(pair: #(Box, String)) -> String { pair.1 }",
    )
    == []
  let report =
    run(
      "tuple_projection_members",
      "class Box(value: Int)\nmain() { assert #(Box(42), \"owl\").0.value == 42\nassert #(1, \"owl\").1 == \"owl\" }",
    )
  assert report.status == 0
  assert support.diagnostics(report.stderr) == ""
}

pub fn nested_projections_and_function_values_execute_test() {
  let report =
    run(
      "tuple_projection_nested",
      "main() { let value = #(#(1, 42), fn(n: Int) { n + 1 })\nassert value.0.1 == 42\nassert value.1(41) == 42\nassert value.0.0 + value.0.1 == 43 }",
    )
  assert report.status == 0
  assert support.diagnostics(report.stderr) == ""
}

pub fn projection_evaluates_its_receiver_once_test() {
  let report =
    run(
      "tuple_projection_once",
      "pair() { echo \"once\"\n#(42, 0) }\nmain() { echo pair().0 }",
    )
  assert report.status == 0
  assert report.stdout == "\"once\"\n42\n"
}

pub fn projection_keeps_result_propagation_in_its_callable_test() {
  let report =
    run(
      "tuple_projection_propagate",
      "read() -> Result(#(Int, String), String) { Ok(#(42, \"owl\")) }\nanswer() -> Result(Int, String) { Ok(read()?.0) }\nmain() { assert answer() == Ok(42) }",
    )
  assert report.status == 0
  assert support.diagnostics(report.stderr) == ""
}

pub fn projection_accepts_expected_tuple_callback_parameters_test() {
  let report =
    run(
      "tuple_projection_callback",
      "apply(pair: #(Int, String), read: fn(#(Int, String)) -> String) -> String { read(pair) }\nmain() { assert apply(#(42, \"owl\"), fn(pair) { pair.1 }) == \"owl\" }",
    )
  assert report.status == 0
}

pub fn invalid_tuple_indices_are_rejected_before_runtime_test() {
  let assert [value] = errors("main() { echo #(1, 2).2 }")
  assert value.id == "type.tuple_index_out_of_bounds"
  let assert [empty] = errors("main() { echo #().0 }")
  assert empty.id == "type.tuple_index_out_of_bounds"
  let assert [receiver] = errors("main() { echo 42.0.0 }")
  assert receiver.id == "type.invalid_tuple_subject"
  let assert [unknown] = errors("first(pair) { pair.0 }")
  assert unknown.id == "type.invalid_tuple_subject"
}

pub fn a_projection_retains_the_element_type_test() {
  let values = errors("wrong(pair: #(Int, String)) -> Int { pair.1 }")
  assert list.any(values, fn(value) { value.id == "type.unification" })
}

pub fn malformed_numeric_indices_do_not_crash_the_parser_test() {
  use directory <- support.with_directory("tuple_projection_malformed")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { #(1, 2).0x }\n",
  )
  let assert Ok(report) = check.check_project(directory)
  assert diagnostic.has_errors(check.diagnostics(report))
}

pub fn tuple_projection_formatting_is_stable_test() {
  let assert Ok(formatted) =
    formatter.format(
      "module main\nmain(){let pair=#(#(1,2),3)\necho pair . 0 . 1}\n",
    )
  assert string.contains(formatted, "pair.0.1")
  assert formatter.format(formatted) == Ok(formatted)
}

pub fn out_of_bounds_projection_snapshot_test() {
  let source = "module main\nmain() { echo #(1, 2).2 }"
  let values = errors("main() { echo #(1, 2).2 }")
  render.render_all(
    values,
    dict.from_list([#("src/main.pooka", source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "types: tuple projection index out of bounds")
}
