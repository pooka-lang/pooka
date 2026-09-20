//// A pattern can introduce a dependency without making a call.
////
//// Keep regressions for classes first mentioned by destructuring. Their field
//// layouts must be prepared before the dependent function or closure is
//// inferred, including nested patterns, inherited fields and recursive
//// constructor groups. Ordering must not excuse an incorrect pattern arity.
////
//// ```text
//// caller -> closure -> class pattern -> prepared field types
//// ```

import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import gleam/dict
import support

fn check(body: String) {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> body),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert report.diagnostics == []
}

// The only mention of the class is inside a closure pattern. Dependency
// discovery must still prepare its fields before checking the caller above
// it.
pub fn closure_above_class_can_reach_a_pattern_only_dependency_test() {
  check(
    "caller() { fn(value) { unwrap(value) } }\nclass Box(value: Int)\nunwrap(value) { match value { Box(inner) -> inner } }\nmain() { caller()(Box(42)) }",
  )
}

pub fn direct_caller_above_class_can_reach_a_pattern_only_dependency_test() {
  check(
    "caller(value) { unwrap(value) }\nclass Box(value: Int)\nunwrap(value) { match value { Box(inner) -> inner } }\nmain() { caller(Box(42)) }",
  )
}

pub fn nested_patterns_prepare_every_referenced_class_test() {
  check(
    "caller() { fn(value) { unwrap(value) } }\nclass Box(value: Int)\nunwrap(value) { match value { Some(#(Box(inner), [Box(other)])) -> inner + other\n_ -> 0 } }\nmain() { caller()(Some(#(Box(20), [Box(22)]))) }",
  )
}

pub fn let_assert_patterns_prepare_their_class_test() {
  check(
    "caller() { fn(value) { unwrap(value) } }\nclass Box(value: Int)\nunwrap(value) { let assert Box(inner) = value\ninner }\nmain() { caller()(Box(42)) }",
  )
}

pub fn let_patterns_prepare_their_class_test() {
  check(
    "caller() { fn(value) { unwrap(value) } }\nclass Box(value: Int)\nunwrap(value) { let Box(inner) = value\ninner }\nmain() { caller()(Box(42)) }",
  )
}

pub fn generic_class_pattern_dependencies_are_order_independent_test() {
  check(
    "caller() { fn(value) { unwrap(value) } }\nclass Box(a) { let value: a\nnew(value: a) { self.value = value } }\nunwrap(value) { match value { Box(inner) -> inner } }\nmain() { #(caller()(Box(42)), caller()(Box(\"ok\"))) }",
  )
}

pub fn inherited_pattern_fields_are_ready_before_matching_test() {
  check(
    "caller() { fn(value) { unwrap(value) } }\nclass Parent(value: Int)\nclass Box is Parent { new(value: Int) { super.new(value) } }\nunwrap(value) { match value { Box(inner) -> inner\n_ -> 0 } }\nmain() { caller()(Box(42)) }",
  )
}

// Preparing a class early fixes ordering only. It must not weaken the check
// that a class pattern supplies the right number of fields.
pub fn incorrect_pattern_arity_is_still_rejected_test() {
  let assert Ok(report) =
    module_infer.infer(
      support.parse(
        "module main\ncaller() { fn(value) { unwrap(value) } }\nclass Box(value: Int)\nunwrap(value) { match value { Box() -> 0 } }",
      ),
      dict.new(),
      unify.new(),
      support.path,
    )
  let assert [error] = report.diagnostics
  assert error.id == "type.pattern_arity"
}

pub fn closure_before_class_executes_with_prepared_pattern_fields_test() {
  use directory <- support.with_directory("g3_closure_class_pattern")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\ncaller() { fn(value) { unwrap(value) } }\nclass Box(value: Int)\nunwrap(value) { match value { Box(inner) -> inner } }\nmain() { assert caller()(Box(42)) == 42\necho True }",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 0
  assert outcome.stdout == "True\n"
}

pub fn loop_patterns_prepare_their_class_test() {
  check(
    "caller() { fn(values) { consume(values) } }\nclass Box(value: Int)\nconsume(values) { loop Box(inner) in values { let _ = inner } }\nmain() { caller()([Box(42)]) }",
  )
}

pub fn pattern_dependencies_can_form_a_recursive_constructor_group_test() {
  check(
    "caller() { fn(value) { unwrap(value) } }\nclass Box { let value: Int\nnew(value: Int) { self.value = match value { 0 -> 0\n_ -> unwrap(Box(value - 1)) + 1 } } }\nunwrap(value) { match value { Box(inner) -> inner } }\nmain() { caller()(Box(3)) }",
  )
}
