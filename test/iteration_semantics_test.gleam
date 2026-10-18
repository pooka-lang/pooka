//// Visit the source once, even when the loop body has much to say.
////
//// Check built-in and declared iterator contracts, inferred element types and
//// loop results. Evaluation order, empty inputs, break and continue must agree
//// at runtime. An iterator's mutable progress belongs to its implementation
//// rather than the loop's lexical bindings.

import birdie
import cli/command
import compiler/codegen/beam
import compiler/codegen/erlang
import compiler/typesystem/infer
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/typed_ast
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string
import support

fn check(source: String) -> infer.Inferred {
  let assert Ok(report) =
    infer.infer(
      support.expression(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

fn ids(source: String) -> List(String) {
  list.map(check(source).diagnostics, fn(value) { value.id })
}

fn run(name: String, body: String) -> command.Outcome {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  if_imported_iterator(directory, body)
  support.write(directory <> "/src/main.pooka", "module main\n" <> body)
  support.cli_main(["run"], command.plain(directory))
}

fn output(name: String, body: String) -> String {
  let report = run(name, body)
  assert support.diagnostics(report.stderr) == ""
  assert report.status == 0
  report.stdout
}

pub fn effect_loops_infer_nil_and_value_breaks_determine_the_result_test() {
  let effects =
    check("fn(items: List(Int)) { loop item in items { item + 1 } }")
  assert effects.diagnostics == []
  assert monotype.to_string(effects.type_) == "fn(List(Int)) -> Nil"
  let values =
    check("fn(items: List(Int)) { loop item in items { break item } }")
  assert values.diagnostics == []
  assert monotype.to_string(values.type_) == "fn(List(Int)) -> Int"
}

// An iteration binding cannot silently drop elements whose pattern fails.
// Require a supported iteration source and a pattern that accepts its element
// type.
pub fn iteration_requires_a_supported_source_and_irrefutable_pattern_test() {
  assert ids("loop item in 42 { item }") == ["type.not_iterable"]
  assert ids("loop True in [True, False] { Nil }")
    == ["type.non_exhaustive_match"]
  assert ids("loop #(a, b) in [#(1, True)] { #(a, b) }") == []
}

// The iterable expression runs once before traversal. Re-running it for each
// element could repeat effects or produce a different sequence.
pub fn list_iteration_evaluates_the_source_once_and_preserves_order_test() {
  assert output(
      "iteration_order",
      "source() { echo(\"once\")\n[1, 2, 3] }\nmain() { loop item in source() { echo(match item { 1 -> \"a\"\n2 -> \"b\"\n_ -> \"c\" })\nNil } }",
    )
    == "\"once\"\n\"a\"\n\"b\"\n\"c\"\n"
}

pub fn break_continue_and_nested_loops_use_the_nearest_boundary_test() {
  assert output(
      "iteration_nested",
      "actor Total { var value = 0\nadd(n: Int) { value += n }\nget() { value } }\nmain() { echo { let total = Total.new()\nloop item in [1, 2, 3] { match item { 2 -> continue\n_ -> Nil }\nloop inner in [10, 20] { total.add(item + inner)\nbreak } }\ntotal.get() } }",
    )
    == "24\n"
  assert output(
      "iteration_break",
      "main() { echo { loop item in [1, 2, 3] { match item { 2 -> break item\n_ -> continue } } } }",
    )
    == "2\n"
}

pub fn exhausted_value_loops_fail_instead_of_returning_nil_test() {
  let report =
    run(
      "iteration_exhausted",
      "find(values: List(Int)) { loop item in values { break item } }\nmain() { echo { find([]) } }",
    )
  assert report.status == 1
  assert string.contains(
    report.stderr,
    "the loop ended without breaking with a value",
  )
  assert output("iteration_empty_effect", "main() { loop _item in [] { Nil } }")
    == ""
}

const range =
  "import iterator.{Iterator}\nactor Range with Iterator(Int) { var current: Int\nlet limit: Int\nnew(start, limit) { self.current = start\nself.limit = limit }\nnext() -> Option(Int) { match current < limit { True -> { let value = current\ncurrent += 1\nSome(value) }\nFalse -> None } } }\n"

pub fn explicit_iterator_protocols_execute_through_actor_interfaces_test() {
  assert output(
      "iteration_protocol",
      range
        <> "actor Total { var value = 0\nadd(n: Int) { value += n }\nget() { value } }\nmain() { echo { let total = Total.new()\nloop item in Range.new(1, 4) { total.add(item) }\ntotal.get() } }",
    )
    == "6\n"
}

pub fn interface_valued_iterators_keep_their_element_type_test() {
  assert output(
      "iteration_interface",
      range
        <> "find(values: Iterator(Int)) { loop item in values { match item > 1 { True -> break item\nFalse -> continue } } }\nmain() { echo { find(Range.new(0, 4)) } }",
    )
    == "2\n"
}

pub fn structural_next_methods_do_not_implicitly_implement_iteration_test() {
  let report =
    run(
      "iteration_nominal",
      "actor Fake { next() -> Option(Int) { None } }\nmain() { echo { loop _item in Fake.new() { Nil } } }",
    )
  assert report.status == 1
  assert string.contains(report.stderr, "value is not iterable")
}

pub fn constructor_iteration_retains_its_immutable_field_state_test() {
  assert output(
      "iteration_constructor",
      "class Value { let first: Int\nlet second: Int\nnew() { self.first = 40\nlet selected = loop item in [1, 2] { match item == 2 { True -> break item\nFalse -> continue } }\nself.second = selected } }\nmain() { echo { let value = Value()\nvalue.first + value.second } }",
    )
    == "42\n"
}

pub fn loop_break_values_join_sibling_classes_without_source_order_bias_test() {
  assert output(
      "iteration_class_join",
      "class Choice {}\nclass Left is Choice { value() { 1 } }\nclass Right is Choice { value() { 2 } }\nchoose(values: List(Bool)) { loop item in values { match item { True -> break Left()\nFalse -> break Right() } } }\nmain() { echo { match choose([False]) { Left -> 1\nRight -> 2 } } }",
    )
    == "2\n"
}

pub fn iteration_propagates_results_to_the_enclosing_callable_test() {
  assert output(
      "iteration_result",
      "work(values: List(Result(Int, String))) -> Result(Int, String) { loop value in values { let _number = value? }\nOk(42) }\nmain() { echo { #(work([Ok(1)]), work([Error(\"stop\")])) } }",
    )
    == "#(Ok(42), Error(\"stop\"))\n"
}

pub fn iteration_variables_are_branch_local_and_break_types_remain_checked_test() {
  assert ids("fn(items: List(Int)) { loop item in items { Nil }\nitem }")
    == ["type.unknown_name"]
  assert ids(
      "loop flag in [True, False] { match flag { True -> break 1\nFalse -> break \"bad\" } }",
    )
    == ["type.unification"]
}

pub fn iterator_contract_errors_are_reported_as_source_diagnostics_test() {
  let report =
    run(
      "iterator_missing_next",
      "import iterator.{Iterator}\nactor Broken with Iterator(Int) {}\nmain() { Nil }",
    )
  assert report.status == 1
  assert string.contains(report.stderr, "incomplete interface implementation")
  assert string.contains(report.stderr, "next() -> Option(a)")
}

pub fn source_iterator_aliases_preserve_nominal_protocol_identity_test() {
  assert output(
      "iterator_alias",
      "import iterator.{Iterator as Cursor}\nactor Empty with Cursor(Int) { next() -> Option(Int) { None } }\nmain() { loop _value in Empty.new() { Nil } }",
    )
    == ""
}

pub fn immutable_iterators_can_delegate_state_to_an_actor_test() {
  assert output(
      "iterator_class_proxy",
      range
        <> "class Cursor with Iterator(Int) { let source: Range\nnew(source) { self.source = source }\nnext() -> Option(Int) { source.next() } }\nmain() { echo { loop item in Cursor(Range.new(1, 4)) { match item == 3 { True -> break item\nFalse -> continue } } } }",
    )
    == "3\n"
}

pub fn local_iterator_modules_take_precedence_over_the_core_contract_test() {
  use directory <- support.with_directory("iterator_local_contract")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/iterator.pooka",
    "module iterator\ninterface Iterator(a) { next() -> Option(a) }\nmarker() { 42 }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport iterator.{Iterator}\nactor Once with Iterator(Int) { var done = False\nnext() -> Option(Int) { match done { False -> { done = True\nSome(iterator.marker()) }\nTrue -> None } } }\nmain() { echo { loop item in Once.new() { break item } } }",
  )
  let report = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(report.stderr) == ""
  assert report.status == 0
  assert report.stdout == "42\n"
}

/// Follow the generated recursive iterator through its next-element request,
/// body and loop exits. A named anonymous function uses this schematic form;
/// Name is its generated atom and Clauses contains the lowered function clauses.
///
/// ```erlang
/// {named_fun, Anno, Name, Clauses}
/// ```
///
/// Erlang named anonymous functions:
/// https://www.erlang.org/doc/apps/erts/absform.html#expressions
pub fn iteration_abstract_forms_snapshot_test() {
  let syntax =
    support.parse(
      "module main\nmain() { loop value in [1, 2] { match value { 1 -> continue\n_ -> break value } } }",
    )
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  assert inferred.diagnostics == []
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  let assert Ok(generated) = erlang.generate(typed, "app", "main", dict.new())
  let assert Ok(_) = beam.compile(generated.forms)
  birdie.snap(
    beam.pretty(generated.forms),
    title: "codegen typed iteration abstract forms",
  )
}

fn if_imported_iterator(directory: String, body: String) {
  case string.contains(body, "import iterator") {
    True ->
      support.write(
        directory <> "/src/iterator.pooka",
        "module iterator\ninterface Iterator(a) { next() -> Option(a) }\n",
      )
    False -> Nil
  }
}
