//// A closure begins another little room.
////
//// Check where self, super, propagation and loop control are permitted before
//// type inference. A nested callable must not borrow its caller's loop exits,
//// and a guard cannot become a return boundary. Independent operand errors
//// should still be visited.

import birdie
import compiler/analysis/context
import gleam/list
import support

fn ids(body: String) -> List(String) {
  context.check(support.parse("module main\n" <> body), support.path)
  |> list.map(fn(value) { value.id })
}

pub fn self_is_available_only_in_constructors_test() {
  assert ids("class User { let name: String new(name) { self.name = name } }")
    == []
  assert ids("actor User { let name: String new(name) { self.name = name } }")
    == []
  assert ids("f() { self }") == ["analysis.self_outside_constructor"]
  assert ids("class User { get() { self.name } }")
    == ["analysis.self_outside_constructor"]
  assert ids("class User { let name = self }")
    == ["analysis.self_outside_constructor"]
  assert ids("actor User { be get() { self } }")
    == ["analysis.self_outside_constructor"]
}

// Entering a closure resets the callable context. It may capture values from
// outside without acquiring permission to exit an outer callable or loop.
pub fn closure_starts_a_new_callable_test() {
  assert ids("class User { new() { let f = fn() { self } } }")
    == ["analysis.self_outside_constructor"]
  assert ids("actor User { be get() { let f = fn() { load()? } } }") == []
  assert ids("class User { new() { let f = fn() { load()? } } }") == []
}

pub fn propagation_is_valid_in_functions_and_methods_test() {
  assert ids("f() { load()? }") == []
  assert ids("class User { load() { read()? } }") == []
  assert ids("actor User { load() { read()? } }") == []
}

pub fn propagation_is_invalid_outside_functions_test() {
  assert ids("class User { new() { load()? } }")
    == ["analysis.propagation_context"]
  assert ids("actor User { be load() { read()? } }")
    == ["analysis.propagation_context"]
  assert ids("class User { let name = load()? }")
    == ["analysis.propagation_context"]
  assert ids("test \"load\" { load()? }") == ["analysis.propagation_context"]
}

pub fn propagation_is_invalid_in_guards_test() {
  assert ids("f(x) { match x { value if valid(value)? -> value } }")
    == ["analysis.propagation_context"]
  assert ids("f(x) { match x { value if { load()?\nTrue } -> value } }")
    == ["analysis.propagation_context"]
  assert ids("f(x) { match x { value if True -> load()? } }") == []
  assert ids("f(x) { match x { value if check(fn() { load()? }) -> value } }")
    == []
}

pub fn break_and_continue_need_a_loop_test() {
  assert ids("f() { break }") == ["analysis.break_outside_loop"]
  assert ids("f() { continue }") == ["analysis.continue_outside_loop"]
  assert ids("f() { loop { match True { True -> break\nFalse -> continue } } }")
    == []
  assert ids("f() { loop { { break 1 } } }") == []
}

pub fn closures_cannot_control_outer_loops_test() {
  assert ids("f() { loop { let work = fn() { break } } }")
    == ["analysis.break_outside_loop"]
  assert ids("f() { loop { let work = fn() { continue } } }")
    == ["analysis.continue_outside_loop"]
  assert ids("f() { loop { let work = fn() { loop { break } } } }") == []
}

// The source expression is evaluated before the new loop begins. A break
// encountered there cannot target a loop whose body has not been entered.
pub fn loop_iterable_is_outside_the_new_loop_test() {
  assert ids("f() { loop x in { break } { x } }")
    == ["analysis.break_outside_loop"]
  assert ids("f() { loop { loop x in { break } { x } } }") == []
}

pub fn super_needs_a_superclass_test() {
  assert ids(
      "class Animal {}\nclass Dog is Animal { new() { super.new() } speak() { super.speak() } }",
    )
    == []
  assert ids("class Dog { speak() { super.speak() } }")
    == ["analysis.super_without_superclass"]
  assert ids("actor Dog { speak() { super.speak() } }")
    == ["analysis.super_without_superclass"]
  assert ids("f() { super }") == ["analysis.super_without_superclass"]
}

pub fn explicit_behaviour_result_annotation_test() {
  assert ids("actor Counter { be add() -> Nil { Nil } }") == []
  assert ids("actor Counter { be add() -> Int { 1 } }")
    == ["analysis.behaviour_result"]

  assert ids("actor Counter { be add() { 1 } }") == []
}

pub fn nested_operand_errors_are_all_reported_test() {
  assert ids("class User { new() { self.name = load()? } get() { self } }")
    == ["analysis.propagation_context", "analysis.self_outside_constructor"]
  assert ids("f() { break self }")
    == ["analysis.break_outside_loop", "analysis.self_outside_constructor"]
}

pub fn contexts_do_not_leak_between_functions_test() {
  assert ids("f() { loop { break } }\ng() { break }")
    == ["analysis.break_outside_loop"]
  assert ids("class User { new() { self } get() { self } }")
    == ["analysis.self_outside_constructor"]
}

pub fn bit_array_size_expressions_are_checked_test() {
  assert ids("f() { <<1:size(self)>> }")
    == ["analysis.self_outside_constructor"]
  assert ids("f(bytes) { let <<x:size(n)>> = bytes }") == []
  assert ids("f(bytes) { match bytes { <<x:size(n)>> -> x } }") == []
}

pub fn context_diagnostics_snapshot_test() {
  support.rendered(
    "module main\nexternal Store from erlang \"store\" {\n  load() -> Result(Int, String)\n}\nclass User {\n  new() { Store.load()? }\n  get() { self.name }\n}\nf() { continue }\nactor Counter {\n  be increment() -> Int { 1 }\n}\n",
  )
  |> birdie.snap(title: "analysis: invalid expression contexts")
}
