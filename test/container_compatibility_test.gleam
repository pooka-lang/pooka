//// Widen the view without replacing the value.
////
//// Immutable built-in containers may carry subclasses where a base view is
//// expected. Function results can widen too; function parameters and user-
//// defined generic arguments retain their invariant rules. Sibling joins must
//// be symmetric, and a widened value must still dispatch as its original
//// subclass.
////
//// ```text
//// List(Child) -> List(Parent)   allowed view
//// Parent      -> Child        no implicit downcast
//// ```

import birdie
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import diagnostics/diagnostic
import gleam/dict
import gleam/list
import support

const hierarchy =
  "class Ref {}\nclass Tmp(id: Int) is Ref\nclass Con(value: Int) is Ref\n"

fn check(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> hierarchy <> body),
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

pub fn annotated_builtin_containers_accept_subclasses_test() {
  accepted(
    "main() { let refs: List(Ref) = [Tmp(1)]\nlet optional: Option(Ref) = Some(Tmp(2))\nlet result: Result(Ref, Ref) = Ok(Tmp(3))\nlet failure: Result(Ref, Ref) = Error(Con(4))\nlet pair: #(Ref, Ref) = #(Tmp(5), Con(6))\n#(refs, optional, result, failure, pair) }",
  )
}

pub fn container_arguments_accept_subclasses_test() {
  accepted(
    "take_list(value: List(Ref)) { value }\ntake_option(value: Option(Ref)) { value }\ntake_result(value: Result(Ref, Ref)) { value }\ntake_tuple(value: #(Ref, Ref)) { value }\nmain() { #(take_list([Tmp(1)]), take_option(Some(Tmp(2))), take_result(Ok(Tmp(3))), take_result(Error(Con(4))), take_tuple(#(Tmp(5), Con(6)))) }",
  )
}

pub fn container_return_values_accept_subclasses_test() {
  accepted(
    "refs() -> List(Ref) { [Tmp(1)] }\noptional() -> Option(Ref) { Some(Tmp(2)) }\nsuccess() -> Result(Ref, Ref) { Ok(Tmp(3)) }\nfailure() -> Result(Ref, Ref) { Error(Con(4)) }\npair() -> #(Ref, Ref) { #(Tmp(5), Con(6)) }",
  )
}

pub fn nested_container_compatibility_is_recursive_test() {
  accepted(
    "main() { let value: List(Option(Result(#(Ref, List(Ref)), Ref))) = [Some(Ok(#(Tmp(1), [Con(2)])))]\nvalue }",
  )
}

// A compatible use may request a base view, but the original binding must
// keep its more precise inferred type for its other uses.
pub fn existing_container_values_can_be_widened_without_changing_their_type_test() {
  accepted(
    "take_base(value: List(Ref)) { value }\ntake_tmp(value: List(Tmp)) { value }\nmain() { let values: List(Tmp) = [Tmp(1)]\nlet widened: List(Ref) = values\nlet _ = take_base(values)\n#(widened, take_tmp(values)) }",
  )
}

pub fn function_results_are_covariant_test() {
  accepted(
    "make() -> Tmp { Tmp(1) }\nmain() { let factory: fn() -> Ref = make\nlet factories: List(fn() -> Option(Ref)) = [fn() { Some(Tmp(2)) }]\n#(factory(), factories) }",
  )
}

// Widening a returned value is safe here; changing which inputs a function
// accepts is another promise. Container covariance must not leak into
// parameters.
pub fn function_parameter_types_remain_invariant_test() {
  rejected(
    "consume(value: Tmp) -> Int { value.id }\nmain() { let consumer: fn(Ref) -> Int = consume\nconsumer }",
  )
  rejected(
    "consume(value: Ref) -> Int { 1 }\nmain() { let consumer: fn(Tmp) -> Int = consume\nconsumer }",
  )
}

pub fn user_defined_generic_arguments_remain_invariant_test() {
  rejected(
    "class Box(value: a)\nmain() { let value: Box(Ref) = Box(Tmp(1))\nvalue }",
  )
}

pub fn compatibility_does_not_allow_downcasts_or_sibling_casts_test() {
  rejected("narrow(value: Ref) -> List(Tmp) { [value] }")
  rejected("main() { let value: Option(Tmp) = Some(Con(1))\nvalue }")
  rejected("main() { let value: Result(Tmp, Tmp) = Error(Con(1))\nvalue }")
}

pub fn unrelated_elements_and_tuple_arities_still_fail_test() {
  rejected("main() { let value: List(Int) = [\"no\"]\nvalue }")
  rejected("main() { let value: #(Ref, Int) = #(Tmp(1), \"no\")\nvalue }")
  rejected("main() { let value: #(Ref, Ref) = #(Tmp(1))\nvalue }")
}

// Swapping operands must not change whether equality type-checks. Both nested
// siblings should meet at the same common base.
pub fn nested_sibling_equality_is_symmetric_test() {
  accepted(
    "main() { #(Some(Tmp(1)) == Some(Con(1)), Some(Con(1)) == Some(Tmp(1)), [Tmp(1)] != [Con(1)], #(Tmp(1), 2) == #(Con(1), 2)) }",
  )
}

pub fn nested_sibling_lists_and_match_branches_find_a_common_base_test() {
  let report =
    check(
      "choose(flag: Bool) { match flag { True -> Some(Tmp(1))\nFalse -> Some(Con(2)) } }\nmain() { [Some(Tmp(1)), Some(Con(2))] }",
    )
  assert report.diagnostics == []
  let assert Ok(main) =
    list.find(report.functions, fn(value) { value.name.name == "main" })
  assert monotype.to_string(main.type_) == "fn() -> List(Option(main.Ref))"
  let assert Ok(choose) =
    list.find(report.functions, fn(value) { value.name.name == "choose" })
  assert monotype.to_string(choose.type_) == "fn(Bool) -> Option(main.Ref)"
}

pub fn interface_views_work_inside_builtin_containers_test() {
  accepted(
    "interface Named { name() -> String }\nclass User with Named { name() -> String { \"Ada\" } }\nmain() { let values: List(Named) = [User()]\nlet optional: Option(Named) = Some(User())\n#(values, optional) }",
  )
}

pub fn nested_generic_parent_arguments_are_checked_test() {
  accepted(
    "class Parent(a) { let value: a\nnew(value: a) { self.value = value } }\nclass Child(a) is Parent(a) { new(value: a) { super.new(value) } }\nmain() { let values: List(Parent(Int)) = [Child(1)]\nvalues }",
  )
  rejected(
    "class Parent(a) { let value: a\nnew(value: a) { self.value = value } }\nclass Child(a) is Parent(a) { new(value: a) { super.new(value) } }\nmain() { let values: List(Parent(String)) = [Child(1)]\nvalues }",
  )
}

// Compatibility is a change of view rather than object reconstruction.
// Execute the widened values to check that subclass identity and dispatch
// survive.
pub fn runtime_uses_the_original_subclass_values_test() {
  use directory <- support.with_directory("globe_container_covariance")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\n"
      <> hierarchy
      <> "take(values: List(Ref)) -> List(Ref) { values }\nrefs() -> List(Ref) { [Tmp(1)] }\nmain() { let values: List(Ref) = [Tmp(1)]\nassert values == refs()\nassert take([Tmp(1)]) == values\nassert Some(Tmp(1)) != Some(Con(1))\nlet optional: Option(Ref) = Some(Tmp(2))\nlet result: Result(Ref, Ref) = Ok(Con(3))\nassert optional == Some(Tmp(2))\nassert result == Ok(Con(3))\necho True }",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 0
  assert outcome.stdout == "True\n"
}

pub fn nested_container_error_diagnostic_test() {
  let source =
    "module main\n"
    <> hierarchy
    <> "main() { let value: List(Option(Tmp)) = [Some(Con(1))]\nvalue }"
  let report =
    check("main() { let value: List(Option(Tmp)) = [Some(Con(1))]\nvalue }")
  support.render_all(report.diagnostics, source)
  |> birdie.snap("types_nested_container_compatibility_diagnostic")
}
