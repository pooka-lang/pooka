//// A binding's written coat is the one its later callers should see.
////
//// Check the published result as well as diagnostics: merely accepting the
//// initializer is not enough when a generic call later shares that type.

import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import support

const family = "class Base {}\nclass A is Base {}\nclass B is Base {}\n"

fn infer(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> family <> body),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

fn signature(report: module_infer.Module, name: String) -> String {
  let assert Ok(function) =
    list.find(report.functions, fn(value) { value.name.name == name })
  monotype.to_string(function.type_)
}

pub fn explicit_binding_widens_a_subclass_before_a_generic_call_test() {
  let report =
    infer(
      "apply(value: a, change: fn(a) -> a) -> a { change(value) }\nmain() { let value: Base = A()\napply(value, fn(_) { B() }) }",
    )
  assert report.diagnostics == []
  assert signature(report, "main") == "fn() -> main.Base"
}

pub fn annotated_and_inferred_bindings_keep_different_views_test() {
  let report =
    infer(
      "wide() { let value: Base = A()\nvalue }\nnarrow() { let value = A()\nvalue }",
    )
  assert report.diagnostics == []
  assert signature(report, "wide") == "fn() -> main.Base"
  assert signature(report, "narrow") == "fn() -> main.A"
}

pub fn an_invalid_initializer_keeps_its_diagnostic_and_error_type_test() {
  let report = infer("main() { let value: Base = 1\nvalue }")
  assert list.length(report.diagnostics) == 1
  assert signature(report, "main") == "<error>"
}
