//// Constructors and functions can call across the same circle.
////
//// Keep regressions for recursive groups containing class or actor members and
//// module functions. Prepared signatures must be shared before checking
//// bodies, then generalized together. Neither unchecked member constraints nor
//// class parameters may escape into unrelated callers.

import birdie
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
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

fn main_type(body: String) -> String {
  let report = check(body)
  assert report.diagnostics == []
  let assert Ok(main) =
    list.find(report.functions, fn(value) { value.name.name == "main" })
  monotype.to_string(main.type_)
}

fn output(name: String, body: String) -> String {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> body)
  let report = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(report.stderr) == ""
  assert report.status == 0
  report.stdout
}

pub fn constructor_and_module_function_can_refer_to_each_other_test() {
  assert output(
      "recursive_constructor_function",
      "class Count { let value: Int\nnew(value) { self.value = count(value) } }\ncount(value: Int) -> Int { match value { 0 -> 0\n_ -> Count(value - 1).value + 1 } }\nmain() { echo { Count(5).value } }",
    )
    == "5\n"
}

pub fn mutually_recursive_class_methods_execute_test() {
  assert output(
      "recursive_classes",
      "class Even { run(n: Int) -> Bool { match n { 0 -> True\n_ -> Odd().run(n - 1) } } }\nclass Odd { run(n: Int) -> Bool { match n { 0 -> False\n_ -> Even().run(n - 1) } } }\nmain() { echo { #(Even().run(42), Odd().run(42)) } }",
    )
    == "#(True, False)\n"
}

pub fn recursive_member_and_function_signatures_generalize_together_test() {
  assert main_type(
      "class Identity { id(value) { helper(value) } }\nhelper(value) { let _instance = Identity()\nvalue }\nmain() { echo { #(Identity().id(42), Identity().id(\"s\"), helper(True)) } }",
    )
    == "fn() -> #(Int, String, Bool)"
}

// Generalization belongs after the recursive component has settled. A
// recursive use cannot demand a fresh, incompatible instance while its own
// definition is unfinished.
pub fn recursive_uses_remain_monomorphic_until_the_group_is_checked_test() {
  let report =
    check(
      "class Identity { id(value) { helper(value) } }\nhelper(value) { let _used = Identity().id(1)\nvalue }\nmain() { echo { Identity().id(\"s\") } }",
    )
  assert report.diagnostics != []
}

pub fn generic_class_parameters_do_not_escape_into_module_signatures_test() {
  assert main_type(
      "class Box(a) { let value: a\nnew(value) { self.value = value }\nread() { helper(value) } }\nhelper(value) { Box(value).value }\nmain() { echo { #(helper(42), helper(\"s\")) } }",
    )
    == "fn() -> #(Int, String)"
}

pub fn constructors_can_recurse_through_their_own_prepared_signature_test() {
  assert output(
      "self_recursive_constructor",
      "class Count { let value: Int\nnew(n: Int) { self.value = match n { 0 -> 0\n_ -> Count(n - 1).value + 1 } } }\nmain() { echo { Count(5).value } }",
    )
    == "5\n"
}

pub fn constructors_do_not_generalize_unchecked_member_constraints_test() {
  let report =
    check(
      "class Value { new(value) { constrain(value) }\ncopy(value) { Value(value) }\nconstrain(value) { value + 1\nNil } }\nmain() { echo { Value(1).copy(\"bad\") } }",
    )
  assert report.diagnostics != []
}

pub fn hierarchy_members_can_refer_back_to_subclass_factories_test() {
  assert output(
      "recursive_hierarchy",
      "class Base { new() {}\nkind() { \"base\" }\nchoose(n: Int) { make(n) } }\nclass Child is Base { kind() { \"child\" } }\nmake(n: Int) { match n { 0 -> Base()\n_ -> Child() } }\nmain() { echo { Child().choose(1).kind() } }",
    )
    == "\"child\"\n"
}

pub fn actor_methods_and_module_functions_can_share_recursive_signatures_test() {
  assert output(
      "recursive_actor_function",
      "actor Counter { var count = 42\nvalue() { helper(count) } }\nhelper(value) { let _other = Counter.new()\nvalue }\nmain() { echo { Counter.new().value() } }",
    )
    == "42\n"
}

pub fn recursive_declaration_signatures_snapshot_test() {
  let report =
    check(
      "class Identity { id(value) { helper(value) } }\nhelper(value) { let _instance = Identity()\nvalue }\nmain() { #(Identity().id(42), Identity().id(\"s\"), helper(True)) }",
    )
  assert report.diagnostics == []
  let assert Ok(class) =
    unify.named_class(report.state, support.path, "", "Identity")
  let functions =
    list.map(report.functions, fn(function) {
      #(function.name.name, monotype.to_string(function.type_))
    })
  let members =
    list.map(class.methods, fn(method) {
      #(
        class.source.name.name <> "." <> method.name.name,
        monotype.to_string(unify.apply(method.type_, report.state)),
      )
    })
  support.pretty(list.append(functions, members))
  |> birdie.snap(title: "types recursive declaration signatures")
}

// Keep the failure in its defining component. Later callers still need
// recovery types so they do not manufacture a second set of errors from the
// same cause.
pub fn failed_recursive_components_do_not_cascade_into_later_callers_test() {
  let report =
    check(
      "class Value { let value: Int\nnew() { self.value = make() } }\nmake() { let _value = Value()\n\"bad\" }\nmain() { echo { Value().value + True } }",
    )
  assert list.length(report.diagnostics) == 1
}
