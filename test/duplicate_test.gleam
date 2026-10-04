//// Two labels cannot quietly claim the same drawer.
////
//// Check namespace collisions across declarations, parameters and member
//// scopes. Discards are not bindings, and distinct namespaces retain their own
//// rules. The diagnostics must identify duplicate ownership without reporting
//// the same conflict repeatedly.

import birdie
import compiler/analysis/duplicate
import compiler/compiler
import gleam/list
import support

fn ids(body: String) -> List(String) {
  duplicate.check(support.parse("module main\n" <> body), support.path)
  |> list.map(fn(value) { value.id })
}

pub fn functions_cannot_overload_test() {
  assert ids("convert(x: Int) { x }\nconvert(x: String) { x }")
    == ["analysis.duplicate_declaration"]
  assert ids("f() {}\nf(a) {}\nf(a, b) {}")
    == ["analysis.duplicate_declaration", "analysis.duplicate_declaration"]
}

pub fn types_share_the_module_namespace_test() {
  assert ids("class User {}\ninterface User {}\nactor User {}")
    == ["analysis.duplicate_declaration", "analysis.duplicate_declaration"]
}

pub fn external_namespaces_share_the_module_namespace_test() {
  assert ids(
      "external F from erlang \"f\" {\n  f(x: Int) -> Int\n}\nclass F {}",
    )
    == ["analysis.duplicate_declaration"]
}

pub fn external_functions_are_unique_within_a_namespace_test() {
  assert ids(
      "external F from erlang \"f\" {\n  f(x: Int) -> Int\n  f(x: Int, y: Int) -> Int\n}",
    )
    == ["analysis.duplicate_external_function"]

  assert ids(
      "external F from erlang \"f\" { f(x: Int) -> Int }\nexternal G from erlang \"g\" { f(x: Int) -> Int }",
    )
    == []
}

pub fn duplicate_named_parameters_test() {
  assert ids("f(x, x) { x }") == ["analysis.duplicate_parameter"]
  assert ids("external F from erlang \"f\" { f(x: Int, x: String) -> Int }")
    == ["analysis.duplicate_parameter"]
  assert ids("f(_x, _x) {}") == ["analysis.duplicate_parameter"]
}

// A discard reserves no name in the local environment. Repeating it should
// not create the collision that repeated ordinary parameter names would.
pub fn discarded_parameters_are_not_bindings_test() {
  assert ids("f(_, _) {}") == []
  assert ids("f(x) { fn(x) { x } }\ng(x) { x }") == []
}

pub fn methods_behaviours_and_constructors_test() {
  assert ids("class User { new(x, x) {} get(x, x) {} }")
    == ["analysis.duplicate_parameter", "analysis.duplicate_parameter"]
  assert ids("actor Counter { be add(x, x) {} }")
    == ["analysis.duplicate_parameter"]
  assert ids("class User { new() {} new(x) {} }")
    == ["analysis.duplicate_member"]
  assert ids("actor Counter { be add() {} add() {} }")
    == ["analysis.duplicate_member"]
}

pub fn duplicate_members_test() {
  assert ids("class User { let x: Int let x: String get() {} get(x) {} }")
    == ["analysis.duplicate_member", "analysis.duplicate_member"]
  assert ids("actor Counter { var count = 0 var count = 1 }")
    == ["analysis.duplicate_member"]
  assert ids("class A { get() {} }\nclass B { get() {} }") == []
}

pub fn interface_requirements_and_generic_parameters_test() {
  assert ids("interface Mapper(a, a) { map(x: a, x: a) -> a map(x: a) -> a }")
    == [
      "analysis.duplicate_type_parameter",
      "analysis.duplicate_parameter",
      "analysis.duplicate_member",
    ]
  assert ids("class Pair(a, a) {}\nactor Worker(a, a) {}")
    == [
      "analysis.duplicate_type_parameter",
      "analysis.duplicate_type_parameter",
    ]
}

pub fn nested_patterns_share_bindings_test() {
  assert ids("f(pair) { match pair { #(x, Some([x, ..xs])) -> x } }")
    == ["analysis.duplicate_pattern_binding"]
  assert ids("f(xs) { let [xs, ..xs] = xs }")
    == ["analysis.duplicate_pattern_binding"]
  assert ids("f(bytes) { let <<x:8, x:8>> = bytes }")
    == ["analysis.duplicate_pattern_binding"]
  assert ids("f(xs) { let assert #(_x, _x) = xs }")
    == ["analysis.duplicate_pattern_binding"]
}

pub fn independent_patterns_can_reuse_names_test() {
  assert ids("f(xs) { match xs { Some(x) -> x Other(x) -> x } }") == []
  assert ids("f(xs) { let #(_, _) = xs\nlet [_, ..] = xs }") == []
  assert ids("f(x) { match x { Some(x) -> x None -> 0 } }") == []
}

pub fn checks_loop_patterns_test() {
  assert ids("f(xs) { loop #(x, x) in xs { x } }")
    == ["analysis.duplicate_pattern_binding"]
}

pub fn nested_closures_are_checked_test() {
  assert ids("f() { [fn(x, x) { x }] }") == ["analysis.duplicate_parameter"]
  assert ids("f() { call(fn(x, x) { x }) }") == ["analysis.duplicate_parameter"]
  assert ids("class User { let callback = fn(x, x) { x } }")
    == ["analysis.duplicate_parameter"]
  assert ids("f() { assert True as fn(x, x) { x } }")
    == ["analysis.duplicate_parameter"]
  assert ids("f() { loop { break fn(x, x) { x } } }")
    == ["analysis.duplicate_parameter"]
}

pub fn semantic_checks_wait_for_valid_syntax_test() {
  let diagnostics =
    compiler.check_source(
      "src/main.pooka",
      "module main\nf(x, x) { ; }\nf() {}",
    ).diagnostics
  assert !list.any(diagnostics, fn(value) {
    value.id == "analysis.duplicate_parameter"
    || value.id == "analysis.duplicate_declaration"
  })
}

pub fn duplicates_always_point_to_first_declaration_test() {
  let diagnostics =
    compiler.check_source(
      "src/main.pooka",
      "module main\nf() {}\nf() {}\nf() {}",
    ).diagnostics
  let assert [second, third] = diagnostics
  let assert [_, first_label] = second.labels
  let assert [_, other_label] = third.labels
  assert first_label.location == other_label.location
  assert first_label.location.span.start.line == 2
}

pub fn duplicate_diagnostics_snapshot_test() {
  support.rendered(
    "module main\nconvert(value: Int) { value }\nconvert(value: String) { value }\nf(pair, pair) {\n  let #(x, Some(x)) = pair\n}\n",
  )
  |> birdie.snap(
    title: "analysis: duplicate declarations parameters and pattern bindings",
  )
}
