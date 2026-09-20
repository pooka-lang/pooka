//// Give each box its own type arguments.
////
//// Check constructors, fields, bound methods and nominal class patterns in
//// module inference. Independent instances must receive independent generic
//// variables, while written universal parameters remain promises inside their
//// own bodies. Private access is checked against receiver identity.
////
//// ```pooka
//// class Box(value: a)
//// main() { #(Box(1), Box("tea")) }
//// ```

import birdie
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
    list.find(report.functions, fn(function) { function.name.name == "main" })
  monotype.to_string(main.type_)
}

// The constructor and the field view must agree about the same nominal
// instance. These small cases establish the contract before generics and
// methods join it.
pub fn explicit_class_construction_and_fields_infer_test() {
  assert main_type(
      "class User { let name: String\nnew(name) { self.name = name } }\nmain() { User(\"Pooka\").name }",
    )
    == "fn() -> String"
}

pub fn generic_classes_instantiate_independently_test() {
  assert main_type(
      "class Box(a) { let value: a\nnew(value) { self.value = value } }\nmain() { #(Box(42).value, Box(\"Pooka\").value) }",
    )
    == "fn() -> #(Int, String)"
}

pub fn methods_resolve_implicit_fields_and_shadowing_test() {
  assert main_type(
      "class User { let name: String\nnew(name) { self.name = name }\ngreet() { \"Hello \" + name }\nchoose(name: Int) { name } }\nmain() { let user = User(\"Pooka\")\n#(user.greet(), user.choose(42)) }",
    )
    == "fn() -> #(String, Int)"
}

pub fn inferred_generic_methods_are_instantiated_per_reference_test() {
  assert main_type(
      "class Identity { identity(value) { value } }\nmain() { let instance = Identity()\n#(instance.identity(42), instance.identity(\"s\")) }",
    )
    == "fn() -> #(Int, String)"
}

// A class parameter stands for every permitted argument, not whichever
// concrete type a method happens to prefer. Its body cannot specialize that
// promise.
pub fn class_parameters_remain_universal_inside_bodies_test() {
  let report =
    check(
      "class Box(a) { let value: a\nnew(value) { self.value = 1 } }\nmain() { Nil }",
    )
  assert report.diagnostics != []
}

pub fn unannotated_fields_are_inferred_from_constructor_constraints_test() {
  assert main_type(
      "class Number { let value\nnew(value: Int) { self.value = value } }\nmain() { Number(42).value }",
    )
    == "fn() -> Int"
}

pub fn private_members_are_checked_using_receiver_identity_test() {
  let report =
    check(
      "class Secret { let _value: Int\nnew(value) { self._value = value }\nread(other: Secret) { other._value } }\nmain() { Secret(42)._value }",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.private_member"]
}

pub fn unknown_members_and_wrong_constructor_arguments_are_errors_test() {
  assert check(
      "class Number { let value: Int\nnew(value) { self.value = value } }\nmain() { Number(\"bad\") }",
    ).diagnostics
    != []
  assert list.map(
      check("class Empty {}\nmain() { Empty().missing }").diagnostics,
      fn(value) { value.id },
    )
    == ["type.unknown_member"]
}

pub fn class_and_function_dependencies_are_inferred_in_order_test() {
  assert main_type(
      "main() { User(\"Pooka\").greet() }\nclass User { let name: String\nnew(name) { self.name = name }\ngreet() { greeting(name) } }\ngreeting(name: String) { \"Hello \" + name }",
    )
    == "fn() -> String"
}

pub fn class_annotations_and_first_class_constructor_references_test() {
  assert main_type(
      "class Box(a) { let value: a\nnew(value) { self.value = value } }\nread(box: Box(Int)) { box.value }\nmain() { let construct = Box.new\nread(construct(42)) }",
    )
    == "fn() -> Int"
}

pub fn class_member_diagnostics_snapshot_test() {
  let report =
    check(
      "class Secret { let _value: Int\nnew(value) { self._value = value } }\nmain() { Secret(42)._value }",
    )
  report.diagnostics
  |> support.pretty
  |> birdie.snap(title: "types nominal private member access")
}

pub fn generic_method_annotations_can_transform_class_parameters_test() {
  assert main_type(
      "class Box(a) { let value: a\nnew(value) { self.value = value }\nmap(transform: fn(a) -> b) -> Box(b) { Box(transform(value)) } }\nmain() { Box(42).map(fn(n) { n == 42 }).value }",
    )
    == "fn() -> Bool"
}

pub fn implicit_method_calls_instantiate_published_signatures_test() {
  assert main_type(
      "class Identity { identity(value) { value }\nboth() { #(identity(42), identity(\"s\")) } }\nmain() { Identity().both() }",
    )
    == "fn() -> #(Int, String)"
}

pub fn class_pattern_coverage_uses_instantiated_field_types_test() {
  let report =
    check(
      "class Box(a) { let value: a\nnew(value) { self.value = value } }\nmain() { match Box(True) { Box(True) -> 1 } }",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.non_exhaustive_match"]
  assert main_type(
      "class Box(a) { let value: a\nnew(value) { self.value = value } }\nmain() { match Box(True) { Box(True) -> 1\nBox(False) -> 2 } }",
    )
    == "fn() -> Int"
}

pub fn class_pattern_coverage_finds_unreachable_nested_branches_test() {
  let report =
    check(
      "class Box(a) { let value: a\nnew(value) { self.value = value } }\nmain() { match #(Box(True), False) { #(Box(_), _) -> 1\n#(Box(True), False) -> 2 } }",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unreachable_pattern"]
}

// A recursive field can describe an endless family of shapes. Coverage
// checking must stop safely when a fallback already covers the remaining
// cases.
pub fn recursive_nominal_patterns_terminate_with_a_fallback_test() {
  assert main_type(
      "class Node { let next: Option(Node)\nnew(next) { self.next = next } }\nmain() { match Node(None) { Node(Some(Node(None))) -> 1\nNode(_) -> 2 } }",
    )
    == "fn() -> Int"
}
