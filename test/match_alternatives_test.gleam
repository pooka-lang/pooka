//// Several patterns may share a doorway, but only one guard opens it.
//// These small programs watch the bindings and effects on both sides.

import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import diagnostics/diagnostic
import gleam/dict
import gleam/list
import gleam/string
import support
import tools/formatter

fn errors(source: String) -> List(diagnostic.Diagnostic) {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> source),
      dict.new(),
      unify.new(),
      support.path,
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

pub fn alternatives_bind_the_same_names_in_different_positions_test() {
  let result =
    run(
      "alternatives_positions",
      "greet(args: List(String)) -> String { match args { [name] | [\"greet\", name] -> name\n_ -> \"help\" } }\nmain() { assert greet([\"owl\"]) == \"owl\"\nassert greet([\"greet\", \"finch\"]) == \"finch\"\nassert greet([]) == \"help\" }",
    )
  assert result.status == 0
}

pub fn alternatives_preserve_binding_order_and_shadowing_test() {
  let result =
    run(
      "alternatives_shadow",
      "read(pair: #(Int, Int)) { let x = 99\nmatch pair { #(x, 0) | #(0, x) -> x\n_ -> x } }\nmain() { assert read(#(4, 0)) == 4\nassert read(#(0, 7)) == 7\nassert read(#(2, 3)) == 99 }",
    )
  assert result.status == 0
}

pub fn help_alternatives_execute_in_source_order_test() {
  let result =
    run(
      "alternatives_help",
      "help(args: List(String)) -> Bool { match args { [] | [\"--help\"] | [\"-h\"] -> True\n_ -> False } }\nmain() { assert help([])\nassert help([\"--help\"])\nassert help([\"-h\"])\nassert !help([\"other\"]) }",
    )
  assert result.status == 0
}

pub fn a_guard_runs_once_after_the_first_matching_alternative_test() {
  let result =
    run(
      "alternatives_guard_once",
      "subject() { echo \"subject\"\n#(1, 2) }\nguard(x: Int) -> Bool { echo x\nFalse }\nmain() { let answer = match subject() { #(x, _) | #(_, x) if guard(x) -> panic\n_ -> 42 }\necho answer }",
    )
  assert result.status == 0
  assert result.stdout == "\"subject\"\n1\n42\n"
}

pub fn guards_observe_the_selected_binding_and_bodies_run_once_test() {
  let result =
    run(
      "alternatives_guard_binding",
      "guard(x: Int) -> Bool { echo x\nx > 0 }\nread(values: List(Int)) { match values { [x] | [0, x] if guard(x) -> { echo \"body\"\nx }\n_ -> 0 } }\nmain() { assert read([0, 4]) == 4\nassert read([8, 8, 8]) == 0 }",
    )
  assert result.status == 0
  assert result.stdout == "4\n\"body\"\n"
}

pub fn alternatives_reject_missing_names_even_when_outer_scope_has_them_test() {
  let diagnostics =
    errors(
      "read(values: List(Int)) { let x = 99\nmatch values { [x] | [] -> x\n_ -> 0 } }",
    )
  let assert [d] =
    list.filter(diagnostics, fn(d) { d.severity == diagnostic.ErrorSeverity })
  assert d.id == "type.alternative_binding"
}

pub fn alternatives_reject_different_names_and_incompatible_types_test() {
  let missing =
    errors(
      "read(value: #(Int, Int)) { match value { #(x, 0) | #(0, y) -> 0\n_ -> 1 } }",
    )
  assert list.length(
      list.filter(missing, fn(d) { d.id == "type.alternative_binding" }),
    )
    == 2
  let types =
    errors(
      "read(value: #(Int, String)) { match value { #(x, _) | #(_, x) -> x } }",
    )
  assert list.any(types, fn(d) { d.id == "type.alternative_binding" })
}

pub fn alternative_bindings_constrain_unknown_subject_elements_test() {
  let diagnostics =
    errors(
      "read(value) { match value { #(x, _) | #(_, x) -> x + 1 } }\nmain() { read(#(1, \"wrong\")) }",
    )
  assert diagnostic.has_errors(diagnostics)
}

pub fn alternative_bindings_join_class_views_test() {
  assert errors(
      "class Base {}\nclass A is Base {}\nclass B is Base {}\nread(value: #(A, B)) -> Base { match value { #(x, _) | #(_, x) -> x } }",
    )
    |> diagnostic.has_errors
    == False
}

pub fn alternatives_cover_all_boolean_and_enum_cases_test() {
  assert errors(
      "enum Light { Red, Green }\ntruth(value: Bool) { match value { True | False -> 1 } }\nlight(value: Light) { match value { Light.Red | Light.Green -> 2 } }",
    )
    == []
}

pub fn guards_do_not_make_alternatives_exhaustive_test() {
  assert list.any(
    errors("truth(value: Bool) { match value { True | False if value -> 1 } }"),
    fn(d) { d.id == "type.non_exhaustive_match" },
  )
}

pub fn each_alternative_participates_in_reachability_test() {
  let diagnostics =
    errors(
      "read(value: Int) { match value { 1 -> 1\n1 | 2 | 2 -> 2\n_ -> 0 } }",
    )
  assert list.length(
      list.filter(diagnostics, fn(d) { d.id == "type.unreachable_pattern" }),
    )
    == 2
}

pub fn alternatives_cover_nested_containers_and_binary_patterns_test() {
  let result =
    run(
      "alternatives_nested",
      "choose(value: Option(Result(Int, Int))) -> Int { match value { Some(Ok(x)) | Some(Error(x)) -> x\nNone -> 0 } }\nbyte(value: BitArray) { match value { <<1:8>> | <<2:8>> -> True\n_ -> False } }\nmain() { assert choose(Some(Ok(1))) == 1\nassert choose(Some(Error(2))) == 2\nassert byte(<<2:8>>) }",
    )
  assert result.status == 0
}

pub fn alternatives_cover_list_tail_bindings_test() {
  let result =
    run(
      "alternatives_list_tails",
      "rest(values: List(Int)) -> List(Int) { match values { [1, ..tail] | [2, ..tail] -> tail\n_ -> [] } }\nmain() { assert rest([2, 3, 4]) == [3, 4] }",
    )
  assert result.status == 0
}

pub fn alternatives_preserve_result_propagation_test() {
  let result =
    run(
      "alternatives_propagate",
      "read(value: Int) -> Result(Int, String) { match value { 1 | 2 -> { let x = Ok(value)?\nOk(x) }\n_ -> Error(\"other\") } }\nmain() { assert read(2) == Ok(2) }",
    )
  assert result.status == 0
}

pub fn alternatives_thread_constructor_initialization_test() {
  let result =
    run(
      "alternatives_constructor",
      "class Box { let value: Int\nnew(input: Int) { match input { 1 | 2 -> { self.value = 42 }\n_ -> { self.value = 0 } } } }\nmain() { assert Box(2).value == 42\nassert Box(9).value == 0 }",
    )
  assert result.status == 0
}

pub fn alternatives_format_stably_with_expression_bitwise_or_test() {
  let assert Ok(formatted) =
    formatter.format(
      "module main\nread(v:Int){match v{1|2 if v|1==3->v|4\n_->0}}\n",
    )
  assert string.contains(formatted, "1 | 2 if v | 1 == 3 -> v | 4")
  assert formatter.format(formatted) == Ok(formatted)
}

pub fn alternative_patterns_narrow_hierarchies_to_a_shared_view_test() {
  let result =
    run(
      "alternatives_hierarchy",
      "class Base { tag() -> Int { 0 } }\nclass A is Base { tag() -> Int { 1 } }\nclass B is Base { tag() -> Int { 2 } }\nread(value: Base) -> Int { match value { A() | B() -> value.tag()\n_ -> 0 } }\nmain() { assert read(A()) == 1\nassert read(B()) == 2 }",
    )
  assert result.status == 0
}

pub fn binary_alternatives_bind_values_with_independent_sizes_test() {
  let result =
    run(
      "alternatives_binary_bindings",
      "read(value: BitArray) { match value { <<1:8, x:8>> | <<2:8, x:16>> -> x\n_ -> 0 } }\nmain() { assert read(<<1:8, 42:8>>) == 42\nassert read(<<2:8, 300:16>>) == 300 }",
    )
  assert result.status == 0
}

pub fn duplicate_bindings_are_checked_within_each_alternative_test() {
  let result =
    run(
      "alternatives_duplicate",
      "main() { match #(1, 2) { #(x, x) | #(x, _) -> x } }",
    )
  assert result.status == 1
  assert string.contains(result.stderr, "duplicate")
}

pub fn later_alternative_constructor_references_are_resolved_test() {
  let result =
    run(
      "alternatives_unknown_constructor",
      "main() { match Some(1) { Some(x) | Missing(x) -> x\nNone -> 0 } }",
    )
  assert result.status == 1
  assert string.contains(result.stderr, "Missing")
}

pub fn shared_body_diagnostics_are_reported_only_once_test() {
  let diagnostics =
    errors("read(value: Int) { match value { 1 | 2 | 3 -> 1 + True\n_ -> 0 } }")
  assert list.length(
      list.filter(diagnostics, fn(d) { d.severity == diagnostic.ErrorSeverity }),
    )
    == 1
}

pub fn long_alternatives_and_comments_format_stably_test() {
  let source =
    "module main\nread(value: String) { match value {\n\"a long first alternative that takes a fair amount of room\"\n// a different doorway\n| \"a long second alternative that also takes a fair amount of room\" -> 1\n_ -> 0\n} }"
  let assert Ok(formatted) = formatter.format(source)
  assert string.contains(formatted, "// a different doorway")
  assert formatter.format(formatted) == Ok(formatted)
}
