//// A list may grow at the front without copying the rest of its spine.
//// Keep the parser, type checker and BEAM in agreement about that last tail.

import birdie
import cli/command
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

fn run(name: String, source: String) -> command.Outcome {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
  support.cli_main(["run"], command.plain(directory))
}

pub fn spread_has_a_separate_tail_and_full_span_test() {
  let assert ast.ListSpread(
    [ast.IntLiteral("1", _), ast.IntLiteral("2", _)],
    ast.Variable("rest", tail_span),
    span,
  ) = support.expression("[1, 2, ..rest]")
  assert span.end.byte_offset - span.start.byte_offset == 14
  assert tail_span.start.byte_offset - span.start.byte_offset == 9
  let assert ast.ListSpread([], _, _) = support.expression("[..rest,]")
}

pub fn spread_accepts_arbitrary_final_expressions_test() {
  let assert ast.ListSpread([_], ast.Call(..), _) =
    support.expression("[1, ..remaining()]")
  let assert ast.ListSpread([_], ast.ListSpread(..), _) =
    support.expression("[1, ..[2, ..rest]]")
}

pub fn spread_rejects_missing_and_nonfinal_tails_test() {
  list.each(
    ["[1, ..]", "[1, ..rest, 2]", "[1, ..rest, ..other]", "[1 ..rest]"],
    fn(value) {
      assert support.parse_errors("module main\nmain() { " <> value <> " }")
        != []
    },
  )
}

pub fn spread_preserves_polymorphic_empty_tails_test() {
  assert errors(
      "prepend(value: a, rest: List(a)) -> List(a) { [value, ..rest] }\ncopy(rest: List(a)) -> List(a) { [..rest] }\nmain() { assert prepend(1, []) == [1]\nassert copy([True]) == [True] }",
    )
    == []
}

pub fn spread_rejects_non_lists_and_mismatched_elements_test() {
  list.each(
    ["main() { [1, ..2] }", "main() { [1, ..[True]] }", "main() { [..False] }"],
    fn(source) {
      assert list.any(errors(source), fn(d) { d.id == "type.unification" })
    },
  )
}

pub fn spread_sees_names_and_recursive_function_dependencies_test() {
  let result =
    run(
      "spread_recursion",
      "count(n: Int) -> List(Int) { match n { 0 -> []\n_ -> [n, ..count(n - 1)] } }\nmain() { assert count(3) == [3, 2, 1] }",
    )
  assert result.status == 0
}

pub fn spread_runs_with_empty_multiple_nested_and_only_tails_test() {
  let result =
    run(
      "spread_shapes",
      "main() { assert [1, 2, ..[3, 4]] == [1, 2, 3, 4]\nassert [1, ..[]] == [1]\nassert [..[2]] == [2]\nassert [..[]] == []\nassert [1, ..[2, ..[3]]] == [1, 2, 3] }",
    )
  assert result.status == 0
}

pub fn spread_evaluates_heads_then_tail_exactly_once_test() {
  let result =
    run(
      "spread_order",
      "head(n: Int) { echo n\nn }\ntail() { echo 3\n[3] }\nmain() { echo [head(1), head(2), ..tail()] }",
    )
  assert result.status == 0
  assert result.stdout == "1\n2\n3\n[1, 2, 3]\n"
}

pub fn spread_propagation_keeps_its_callable_boundary_test() {
  let result =
    run(
      "spread_propagation",
      "tail(ok: Bool) -> Result(List(Int), String) { match ok { True -> Ok([2])\nFalse -> Error(\"stop\") } }\nmake(ok: Bool) -> Result(List(Int), String) { Ok([1, ..tail(ok)?]) }\nmain() { assert make(True) == Ok([1, 2])\nassert make(False) == Error(\"stop\") }",
    )
  assert result.status == 0
}

pub fn spread_joins_nominal_element_views_test() {
  assert errors(
      "class Base {}\nclass A is Base {}\nclass B is Base {}\ncombine(rest: List(Base)) -> List(Base) { [A(), ..rest] }\nmain() { combine([B()]) }",
    )
    == []
}

pub fn spread_formatting_is_stable_test() {
  let assert Ok(formatted) =
    formatter.format("module main\nmain(){let rest=[2,3]\necho [1,..rest]}\n")
  assert string.contains(formatted, "[1, ..rest]")
  assert formatter.format(formatted) == Ok(formatted)
}

pub fn invalid_spread_tail_snapshot_test() {
  let source = "main() { [1, ..False] }"
  render.render_all(
    errors(source),
    dict.from_list([#("src/main.pooka", "module main\n" <> source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "types: list spread requires a compatible tail")
}
