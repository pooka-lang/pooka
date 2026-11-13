//// A function's body can be wrong without making its written contract disappear.
//// Recovery keeps declarations for checking callers, never for building bad code.

import compiler/parser/ast
import compiler/typesystem/infer as expression_infer
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/option.{None}
import support

const prelude =
  "class Box(value: Int)\nmap_first(items: List(a), change: fn(a) -> b) -> b { let assert [first, ..rest] = items\nchange(first) }\n"

fn infer(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> prelude <> body),
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

pub fn a_bad_body_does_not_erase_a_declared_container_result_test() {
  let report =
    infer(
      "make() -> List(Box) { [Box(\"wrong\")] }\nmain() { map_first(make(), fn(box) { box.value }) }",
    )
  assert list.length(report.diagnostics) == 1
  assert signature(report, "make") == "fn() -> List(main.Box)"
  assert signature(report, "main") == "fn() -> Int"
}

pub fn explicit_parameter_contracts_still_report_independent_call_errors_test() {
  let report =
    infer(
      "make(value: Int) -> Box { Box(\"wrong\") }\nmain() { make(\"also wrong\") }",
    )
  assert list.length(report.diagnostics) == 2
  assert signature(report, "make") == "fn(Int) -> main.Box"
}

pub fn a_partly_written_contract_keeps_the_declared_result_test() {
  let report =
    infer(
      "make(value) -> List(Box) { [Box(\"wrong\")] }\nmain() { map_first(make(Nil), fn(box) { box.value }) }",
    )
  assert list.length(report.diagnostics) == 1
  assert signature(report, "make") == "fn(<error>) -> List(main.Box)"
  assert signature(report, "main") == "fn() -> Int"
}

pub fn an_unwritten_result_is_not_guessed_from_a_failed_body_test() {
  let report = infer("make() { Box(\"wrong\") }\nmain() { make().value }")
  assert list.length(report.diagnostics) == 1
  assert signature(report, "make") == "<error>"
  assert signature(report, "main") == "fn() -> <error>"
}

pub fn recovered_generics_remain_independent_at_each_call_test() {
  let report =
    infer(
      "keep(value: a) -> a { 1 }\nmain() { #(keep(1), keep(\"owl\"), keep(True)) }",
    )
  assert list.length(report.diagnostics) == 1
  assert signature(report, "keep") == "fn(a) -> a"
  assert signature(report, "main") == "fn() -> #(Int, String, Bool)"
}

pub fn separate_failed_generic_contracts_do_not_share_variables_test() {
  let report =
    infer(
      "first(value: a) -> a { 1 }\nsecond(value: a) -> List(a) { [1] }\nmain() { #(first(\"owl\"), second(True)) }",
    )
  assert list.length(report.diagnostics) == 2
  assert signature(report, "main") == "fn() -> #(String, List(Bool))"
}

pub fn mutually_recursive_functions_keep_written_contracts_after_one_body_error_test() {
  let report =
    infer(
      "left(n: Int) -> Box { let _ = Box(\"wrong\")\nright(n) }\nright(n: Int) -> Box { left(n) }\nmain() { right(0).value }",
    )
  assert list.length(report.diagnostics) == 1
  assert signature(report, "left") == "fn(Int) -> main.Box"
  assert signature(report, "right") == "fn(Int) -> main.Box"
  assert signature(report, "main") == "fn() -> Int"
}

pub fn class_function_components_preserve_written_function_results_test() {
  let report =
    infer(
      "class Recursive { let value: Int\nnew(value: Int) { self.value = value\nlet _ = make() } }\nmake() -> Recursive { Recursive(\"wrong\") }\nmain() { make().value }",
    )
  assert list.length(report.diagnostics) == 1
  assert signature(report, "make") == "fn() -> main.Recursive"
}

pub fn invalid_contract_annotations_are_not_recovered_test() {
  let syntax = support.parse("module main\nmake() -> List(Int, String) { [] }")
  let assert [ast.FunctionDeclaration(function)] = syntax.declarations
  assert expression_infer.recovery_scheme(function, unify.new(), support.path)
    == None
}

pub fn written_parameters_still_check_callers_when_the_result_is_unwritten_test() {
  let report =
    infer(
      "make(value: Int) { Box(\"wrong\") }\nmain() { make(\"also wrong\") }",
    )
  assert list.length(report.diagnostics) == 2
  assert signature(report, "make") == "fn(Int) -> <error>"
}
