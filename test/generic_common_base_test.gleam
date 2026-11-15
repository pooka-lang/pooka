//// Let both siblings arrive before deciding which family name to write down.

import builder/build
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import diagnostics/diagnostic
import gleam/dict
import gleam/list
import support

const family =
  "class Shape {}\nclass Circle is Shape {}\nclass Square is Shape {}\n"

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

pub fn generic_arguments_share_the_nearest_common_base_in_both_orders_test() {
  list.each(["Circle(), Square()", "Square(), Circle()"], fn(arguments) {
    let report =
      infer(
        "pair(first: a, second: a) -> List(a) { [first, second] }\nmain() { pair("
        <> arguments
        <> ") }\n",
      )
    assert report.diagnostics == []
    assert signature(report, "main") == "fn() -> List(main.Shape)"
  })
}

pub fn immutable_container_constraints_join_their_element_views_test() {
  let report =
    infer(
      "pair(first: a, second: a) -> List(a) { [first, second] }\nmain() { pair([Circle()], [Square()]) }\n",
    )
  assert report.diagnostics == []
  assert signature(report, "main") == "fn() -> List(List(main.Shape))"
}

pub fn a_later_declared_handler_seeds_an_earlier_callback_test() {
  let report =
    infer(
      "class Clock {}\nclass Tick is Clock {}\nclass Mailbox(m) {}\npost(box: Mailbox(m), message: m) -> Nil { Nil }\nstart(init: fn(Mailbox(m)) -> Nil, handle: fn(m) -> Nil) -> Nil { Nil }\nhandle(message: Clock) -> Nil { Nil }\nmain() { start(fn(me) { post(me, Tick()) }, handle) }\n",
    )
  assert report.diagnostics == []
}

pub fn an_inline_annotated_handler_also_supplies_callback_context_test() {
  let report =
    infer(
      "class Clock {}\nclass Tick is Clock {}\nclass Mailbox(m) {}\npost(box: Mailbox(m), message: m) -> Nil { Nil }\nstart(init: fn(Mailbox(m)) -> Nil, handle: fn(m) -> Nil) -> Nil { Nil }\nmain() { start(fn(me) { post(me, Tick()) }, fn(message: Clock) { Nil }) }\n",
    )
  assert report.diagnostics == []
}

pub fn invariant_generic_arguments_do_not_widen_with_a_sibling_value_test() {
  let report =
    infer(
      "class Box(a) {}\nkeep(box: Box(a), value: a) -> Nil { Nil }\nmain() { let box: Box(Circle) = Box()\nkeep(box, Square()) }\n",
    )
  assert diagnostic.has_errors(report.diagnostics)
  let reverse =
    infer(
      "class Box(a) {}\nkeep(value: a, box: Box(a)) -> Nil { Nil }\nmain() { let box: Box(Circle) = Box()\nkeep(Square(), box) }\n",
    )
  assert diagnostic.has_errors(reverse.diagnostics)
}

pub fn unrelated_types_and_incompatible_function_parameters_remain_errors_test() {
  let unrelated =
    infer(
      "pair(first: a, second: a) -> List(a) { [first, second] }\nmain() { pair(Circle(), 1) }\n",
    )
  assert diagnostic.has_errors(unrelated.diagnostics)
  let callbacks =
    infer(
      "pair(first: a, second: a) -> List(a) { [first, second] }\nmain() { pair(fn(value: Circle) { value }, fn(value: Square) { value }) }\n",
    )
  assert diagnostic.has_errors(callbacks.diagnostics)
}

pub fn inferred_family_values_execute_and_survive_repeated_builds_test() {
  use directory <- support.with_directory("generic_common_base_runtime")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\n"
      <> family
      <> "pair(first: a, second: a) -> List(a) { [first, second] }\nmain() { assert pair(Circle(), Square()) == [Circle(), Square()] }\n",
  )
  let env = command.plain(directory)
  assert support.cli_main(["run"], env).status == 0
  let assert Ok(warm) = build.build(directory)
  assert warm.reused
}

pub fn the_nearest_intermediate_base_is_kept_test() {
  let report =
    infer(
      "class Round is Shape {}\nclass Small is Round {}\nclass Large is Round {}\npair(first: a, second: a) -> List(a) { [first, second] }\nmain() { pair(Small(), Large()) }\n",
    )
  assert report.diagnostics == []
  assert signature(report, "main") == "fn() -> List(main.Round)"
}

pub fn generic_base_arguments_remain_invariant_test() {
  let report =
    infer(
      "class Container(a) {}\nclass Left(a) is Container(a) {}\nclass Right(a) is Container(a) {}\npair(first: a, second: a) -> List(a) { [first, second] }\nmain() { let left: Left(Circle) = Left()\nlet right: Right(Square) = Right()\npair(left, right) }\n",
    )
  assert diagnostic.has_errors(report.diagnostics)
}

pub fn callback_context_does_not_make_a_captured_function_polymorphic_test() {
  let report =
    infer(
      "main() { let identity = fn(value) { value }\nlet first: Int = identity(1)\nidentity(Circle()) }\n",
    )
  // A let-bound identity is polymorphic. The captured value below is not.
  assert report.diagnostics == []
  let captured =
    infer(
      "main() { let use = fn(value) { let captured = fn(_) { value }\nlet first: Circle = captured(Nil)\nlet second: Square = captured(Nil)\nvalue }\nuse(Circle()) }\n",
    )
  assert diagnostic.has_errors(captured.diagnostics)
}
