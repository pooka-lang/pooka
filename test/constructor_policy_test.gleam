//// An omitted constructor does not inherit a suitcase of arguments.
////
//// Check when a default constructor is allowed and how an implicit zero-
//// argument parent call is handled. Own required fields, parent arity and
//// generic substitutions remain independent obligations. Runtime cases follow
//// initialization through several ancestors.

import birdie
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import support

fn check(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> body),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

pub fn required_own_fields_need_a_source_constructor_test() {
  assert list.map(
      check("class Missing { let value: Int }").diagnostics,
      fn(value) { value.id },
    )
    == ["type.missing_constructor"]
  assert list.map(
      check("actor Missing { var value: Int }").diagnostics,
      fn(value) { value.id },
    )
    == ["type.missing_constructor"]
  assert list.map(check("class Missing { let value }").diagnostics, fn(value) {
      value.id
    })
    == ["type.missing_constructor"]
}

// An omitted child constructor is not an alias for the parent signature.
// Parent initialization and the child's own callable arity must be decided
// separately.
pub fn implicit_subclass_constructors_do_not_inherit_parent_arguments_test() {
  let report =
    check(
      "class Parent { let value: Int\nnew(value) { self.value = value } }\nclass Child is Parent {}",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.missing_super_constructor"]
}

pub fn implicit_parent_calls_are_arity_checked_and_exactly_once_test() {
  assert support.diagnostic_ids(
      "module main\nclass Parent { let value = 42 }\nclass Child is Parent { new() { super.new(1) } }",
    )
    == ["analysis.super_constructor_arity"]
  assert support.diagnostic_ids(
      "module main\nclass Parent { let value = 42 }\nclass Child is Parent { new() { super.new()\nsuper.new() } }",
    )
    == ["analysis.super_initialized_twice"]
  assert support.diagnostic_ids(
      "module main\nclass Parent { let value = 42 }\nclass Child is Parent { new(flag) { match flag { True -> super.new()\nFalse -> Nil } } }",
    )
    == ["analysis.super_not_initialized"]
}

fn output(name: String, source: String) -> String {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
  let report = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(report.stderr) == ""
  assert report.status == 0
  report.stdout
}

pub fn zero_argument_default_initializers_run_through_multiple_ancestors_test() {
  assert output(
      "constructor_default_chain",
      "class Base { let base = 20 }\nclass Middle is Base { let middle = 10 }\nclass Leaf is Middle { let leaf = 12 }\nmain() { echo { let value = Leaf()\nvalue.base + value.middle + value.leaf } }",
    )
    == "42\n"
}

pub fn explicit_zero_argument_parents_can_initialize_an_implicit_subclass_test() {
  assert output(
      "constructor_zero_parent",
      "class Parent { let value: Int\nnew() { self.value = 42 } }\nclass Child is Parent {}\nmain() { echo { Child().value } }",
    )
    == "42\n"
}

pub fn generic_parent_constructor_arguments_are_substituted_and_forwarded_test() {
  assert output(
      "constructor_generic_parent",
      "class Parent(a) { let value: a\nnew(value: a) { self.value = value } }\nclass Child is Parent(Int) { new(value: Int) { super.new(value) } }\nmain() { echo { let make = Child.new\nmake(42).value } }",
    )
    == "42\n"
}

// A parent call reached through a guard still counts as an explicit
// initialization. Synthesizing another call would initialize the same parent
// twice.
pub fn explicit_parent_calls_in_guards_do_not_trigger_implicit_double_initialization_test() {
  use directory <- support.with_directory("constructor_guard_parent")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/ffi/clock.erl",
    "-module(clock).\n-export([next/0]).\nnext() -> N = case get(ticks) of undefined -> 0; V -> V end, put(ticks, N + 1), N + 1.\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Clock from erlang \"clock\" { next() -> Int }\nclass Parent { let value: Int = Clock.next() }\nclass Child is Parent { new(flag: Bool) { match flag { _ if { super.new()\nflag } -> Nil\n_ -> Nil } } }\nmain() { echo { Child(False).value } }",
  )
  let report = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(report.stderr) == ""
  assert report.status == 0
  assert report.stdout == "1\n"
}

pub fn default_constructor_policy_diagnostics_snapshot_test() {
  let source =
    "module main\nclass Parent { let value: Int\nnew(value) { self.value = value } }\nclass Child is Parent {}\nactor Missing { var count: Int }\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  support.render_all(report.diagnostics, source)
  |> birdie.snap(title: "types default constructor policy")
}
