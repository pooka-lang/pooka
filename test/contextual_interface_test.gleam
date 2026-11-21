//// A written promise should reach every item before the first item names it.
////
//// Contextual views belong to immutable builtin containers. They must neither
//// invent a shared interface for an unannotated list nor widen a mutable or
//// user-defined generic capability.

// SPDX-License-Identifier: Apache-2.0

import birdie
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import diagnostics/diagnostic
import gleam/dict
import support

const declarations =
  "interface Named { name() -> String }\nclass User with Named { name() { \"user\" } }\nclass Moon with Named { name() { \"moon\" } }\n"

fn check(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> declarations <> body),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

fn accepted(body: String) {
  assert check(body).diagnostics == []
}

fn rejected(body: String) {
  assert diagnostic.has_errors(check(body).diagnostics)
}

pub fn annotated_interface_lists_check_every_element_in_both_orders_test() {
  accepted(
    "main() { let a: List(Named) = [User(), Moon()]\nlet b: List(Named) = [Moon(), User()]\n#(a, b) }",
  )
}

pub fn parameters_and_return_annotations_supply_the_literal_view_test() {
  accepted(
    "take(values: List(Named)) { values }\nmake() -> List(Named) { [User(), Moon()] }\nmain() { take([Moon(), User()]) }",
  )
}

pub fn nested_tuple_option_and_result_literals_receive_the_view_test() {
  accepted(
    "main() { let items: List(Option(Result(#(Named, List(Named)), Named))) = [Some(Ok(#(User(), [User(), Moon()]))), Some(Error(Moon()))]\nitems }",
  )
}

pub fn nested_container_arguments_and_results_receive_the_view_test() {
  accepted(
    "take(value: Option(List(Named))) { value }\nmake() -> Result(List(Named), List(Named)) { Ok([User(), Moon()]) }\nfail() -> Result(List(Named), List(Named)) { Error([Moon(), User()]) }\nmain() { take(Some([Moon(), User()])) }",
  )
}

pub fn blocks_matches_and_contextual_callbacks_check_their_final_values_test() {
  accepted(
    "make(flag: Bool) -> List(Named) { match flag { True -> { [User(), Moon()] }\nFalse -> [Moon(), User()] } }\napply(make: fn() -> List(Named)) { make() }\nmain() { let result: Option(List(Named)) = { Some([User(), Moon()]) }\n#(result, apply(fn() { [Moon(), User()] })) }",
  )
}

pub fn spread_heads_and_tails_keep_the_written_interface_view_test() {
  accepted(
    "main() { let values: List(Named) = [User(), Moon(), ..[Moon(), User()]]\nvalues }",
  )
}

pub fn unannotated_lists_still_need_an_inferred_common_type_test() {
  rejected("main() { [User(), Moon()] }")
}

pub fn unrelated_values_and_structural_lookalikes_are_rejected_test() {
  rejected("main() { let values: List(Named) = [User(), 42]\nvalues }")
  rejected(
    "class Unmarked { name() { \"same method, no promise\" } }\nmain() { let values: List(Named) = [User(), Unmarked()]\nvalues }",
  )
}

pub fn interface_arguments_and_user_defined_generics_remain_invariant_test() {
  rejected(
    "interface Reader(a) { read() -> a }\nclass Text with Reader(String) { read() { \"text\" } }\nclass Number with Reader(Int) { read() { 1 } }\nmain() { let values: List(Reader(String)) = [Text(), Number()]\nvalues }",
  )
  rejected(
    "class Box(value: a)\nmain() { let value: Box(Named) = Box(User())\nvalue }",
  )
  rejected(
    "main() { let f: fn(Named) -> String = fn(value: User) { value.name() }\nf }",
  )
}

pub fn existing_precise_bindings_keep_their_original_type_test() {
  accepted(
    "take_named(value: List(Named)) { value }\ntake_user(value: List(User)) { value }\nmain() { let users = [User()]\nlet widened: List(Named) = users\n#(take_named(users), take_user(users), widened) }",
  )
}

pub fn user_constructors_named_like_builtins_keep_their_identity_test() {
  accepted("class Some(value: List(Named))\nmain() { Some([User(), Moon()]) }")
  rejected(
    "class Some(value: List(Named))\nmain() { let value: Option(List(Named)) = Some([User(), Moon()])\nvalue }",
  )
}

pub fn contextual_rejection_labels_the_incompatible_element_test() {
  let source =
    "module main\n"
    <> declarations
    <> "main() { let values: List(Named) = [User(), 42]\nvalues }"
  let report =
    check("main() { let values: List(Named) = [User(), 42]\nvalues }")
  birdie.snap(
    support.render_all(report.diagnostics, source),
    title: "types contextual interface container rejection",
  )
}

pub fn mixed_class_and_actor_interfaces_dispatch_after_container_lowering_test() {
  use directory <- support.with_directory("contextual_interfaces_runtime")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/contracts.pooka",
    "module contracts\ninterface Named { name() -> String }",
  )
  support.write(
    directory <> "/src/devices.pooka",
    "module devices\nimport contracts.{Named}\nclass Fixed with Named { name() { \"fixed\" } }\nactor Probe with Named { var label: String = \"probe\"\nname() -> String { label } }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport contracts.{Named}\nimport devices.{Fixed, Probe}\nmake() -> List(Named) { [Fixed(), Probe()] }\nmain() { let values: List(Named) = [Fixed(), Probe()]\nlet nested: Option(List(Named)) = Some([Probe(), Fixed()])\nlet assert Some(others) = nested\nlet assert [a, b] = values\nlet assert [c, d] = others\necho #(a.name(), b.name(), c.name(), d.name())\nlet assert [e, f] = make()\nassert e.name() == \"fixed\"\nassert f.name() == \"probe\" }",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
  assert outcome.stdout == "#(\"fixed\", \"probe\", \"probe\", \"fixed\")\n"
}

pub fn annotated_field_defaults_and_methods_receive_the_same_context_test() {
  accepted(
    "class Shelf { let values: List(Named) = [User(), Moon()]\nread() -> List(Named) { [Moon(), User()] } }\nmain() { Shelf().read() }",
  )
}
