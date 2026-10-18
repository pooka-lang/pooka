//// A matching silhouette is not a signed agreement.
////
//// Interface conformance is declared explicitly and checked against method
//// signatures. Follow generic substitutions, inherited implementations,
//// interface views and dispatch. Similar method names alone must not invent an
//// implementation or expose private requirements.

import birdie
import cli/command
import compiler/codegen/beam
import compiler/codegen/erlang
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/typed_ast
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

fn ids(body: String) -> List(String) {
  check(body).diagnostics |> list.map(fn(value) { value.id })
}

const printable = "interface Printable { print() -> String }\n"

pub fn explicit_implementations_are_accepted_as_interface_values_test() {
  assert ids(
      printable
      <> "class User with Printable { print() { \"user\" } }\nrender(value: Printable) { value.print() }\nmain() -> Printable { echo { User() } }",
    )
    == []
}

// Having methods with the right names is only a resemblance. This language
// requires an explicit implementation before accepting an interface view.
pub fn structural_similarity_is_not_interface_conformance_test() {
  assert ids(
      printable
      <> "class User { print() { \"user\" } }\nmain() -> Printable { echo { User() } }",
    )
    == ["type.unification"]
}

pub fn missing_and_incompatible_methods_are_reported_test() {
  assert ids(printable <> "class User with Printable {}")
    == ["type.missing_interface_method"]
  assert ids(printable <> "class User with Printable { print() { 42 } }")
    == ["type.incompatible_interface_method"]
  assert ids(
      printable
      <> "class User with Printable { print(value: Int) { \"user\" } }",
    )
    == ["type.incompatible_interface_method"]
}

pub fn inherited_methods_and_interfaces_preserve_conformance_test() {
  assert ids(
      printable
      <> "class User with Printable { print() { \"user\" } }\nclass Admin is User {}\nmain() -> Printable { echo { Admin() } }",
    )
    == []
  assert ids(
      printable
      <> "class User { print() { \"user\" } }\nclass Admin is User with Printable {}\nmain() -> Printable { echo { Admin() } }",
    )
    == []
}

pub fn generic_interfaces_preserve_type_arguments_test() {
  let source =
    "interface Item(a) { get() -> a }\nclass Box(a) with Item(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\n"
  assert ids(
      source
      <> "read(item: Item(String)) { item.get() }\nmain() { echo { read(Box(\"hi\")) } }",
    )
    == []
  assert ids(source <> "main() -> Item(String) { echo { Box(42) } }")
    == ["type.unification"]
}

pub fn generic_methods_are_checked_universally_test() {
  let source = "interface Identity { id(value: a) -> a }\n"
  assert ids(source <> "class Good with Identity { id(value) { value } }") == []
  assert ids(source <> "class Bad with Identity { id(value: Int) { value } }")
    == ["type.incompatible_interface_method"]
}

pub fn multiple_interfaces_can_share_a_compatible_method_test() {
  assert ids(
      "interface A { get() -> Int }\ninterface B { get() -> Int }\nclass Value with A, B { get() { 42 } }",
    )
    == []
  assert ids(
      "interface A { get() -> Int }\ninterface B { get() -> String }\nclass Value with A, B { get() { 42 } }",
    )
    == ["type.incompatible_interface_method"]
}

pub fn interface_matches_remain_open_and_narrow_concrete_subjects_test() {
  let source =
    printable
    <> "class User with Printable { print() { \"user\" }\nname() { \"name\" } }\n"
  assert ids(
      source
      <> "render(value: Printable) { match value { User -> value.name() } }",
    )
    == ["type.non_exhaustive_match"]
  assert ids(
      source
      <> "render(value: Printable) { match value { User -> value.name()\n_ -> value.print() } }",
    )
    == []
}

pub fn interface_signatures_do_not_expose_extra_class_members_test() {
  assert ids(printable <> "render(value: Printable) { value.missing() }")
    == ["type.unknown_member"]
}

pub fn conformance_diagnostics_snapshot_test() {
  let source =
    "module main\ninterface Printable { print() -> String }\nclass Missing with Printable {}\nclass Wrong with Printable { print() { 42 } }\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  support.render_all(report.diagnostics, source)
  |> birdie.snap(title: "types: interface conformance")
}

fn run(name: String, files: List(#(String, String))) -> String {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  list.each(files, fn(file) {
    support.write(directory <> "/src/" <> file.0, file.1)
  })
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
  outcome.stdout
}

pub fn interface_methods_and_bound_references_execute_test() {
  assert run("interface_calls", [
      #(
        "main.pooka",
        "module main\n"
          <> printable
          <> "class User with Printable { let name: String\nnew(name) { self.name = name }\nprint() { name } }\nrender(value: Printable) { let print = value.print\nprint() }\nmain() { echo { render(User(\"Pooka\")) } }",
      ),
    ])
    == "\"Pooka\"\n"
}

pub fn generic_interface_calls_execute_test() {
  assert run("interface_generic", [
      #(
        "main.pooka",
        "module main\ninterface Item(a) { get() -> a }\nclass Box(a) with Item(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\nread(value: Item(String)) { value.get() }\nmain() { echo { read(Box(\"generic\")) } }",
      ),
    ])
    == "\"generic\"\n"
}

pub fn interface_dispatch_preserves_overrides_and_subclass_only_methods_test() {
  assert run("interface_inheritance", [
      #(
        "main.pooka",
        "module main\n"
          <> printable
          <> "class Base with Printable { new() {}\nprint() { \"base\" } }\nclass Child is Base { print() { \"child\" } }\ninterface Extra { extra() -> Int }\nclass Other is Base with Extra { extra() { 42 } }\nrender(value: Printable) { value.print() }\nextra(value: Extra) { value.extra() }\nmain() { echo { #(render(Base()), render(Child()), render(Other()), extra(Other())) } }",
      ),
    ])
    == "#(\"base\", \"child\", \"base\", 42)\n"
}

pub fn separately_defined_implementations_dispatch_without_a_closed_registry_test() {
  assert run("interface_imports", [
      #(
        "contracts.pooka",
        "module contracts\ninterface Printable { print() -> String }",
      ),
      #(
        "render.pooka",
        "module render\nimport contracts.{Printable as Show}\nrender(value: Show) { let print = value.print\nprint() }",
      ),
      #(
        "data/item.pooka",
        "module item\nimport contracts\nclass Item with contracts.Printable { print() { \"open\" } }",
      ),
      #(
        "main.pooka",
        "module main\nimport render\nimport data/item.{Item}\nmain() { echo { render.render(Item()) } }",
      ),
    ])
    == "\"open\"\n"
}

pub fn interface_matches_narrow_then_fall_back_to_dynamic_dispatch_test() {
  assert run("interface_patterns", [
      #(
        "main.pooka",
        "module main\n"
          <> printable
          <> "class User with Printable { print() { \"user\" }\nname() { \"named\" } }\nclass Other with Printable { print() { \"other\" } }\nrender(value: Printable) { match value { User -> value.name()\n_ -> value.print() } }\nmain() { echo { #(render(User()), render(Other())) } }",
      ),
    ])
    == "#(\"named\", \"other\")\n"
}

pub fn interface_method_local_quantifiers_instantiate_independently_test() {
  let report =
    check(
      "interface Identity { id(value: a) -> a }\nboth(value: Identity) { #(value.id(42), value.id(\"s\")) }",
    )
  assert report.diagnostics == []
  let assert [function] = report.functions
  assert monotype.to_string(function.type_)
    == "fn(main.Identity) -> #(Int, String)"
}

pub fn requirement_signatures_guide_unannotated_primitive_methods_test() {
  assert ids(
      "interface Add { add(left: Int, right: Int) -> Int }\nclass Calculator with Add { add(left, right) { left + right } }",
    )
    == []
}

pub fn inherited_generic_interface_arguments_are_substituted_test() {
  assert ids(
      "interface Item(a) { get() -> a }\nclass Box(a) with Item(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\nclass Text is Box(String) { new(value) { super.new(value) } }\nmain() -> Item(String) { echo { Text(\"text\") } }",
    )
    == []
}

pub fn missing_requirements_are_grouped_in_one_diagnostic_test() {
  let report =
    check(
      "interface Pair { first() -> Int\nsecond() -> Int }\nclass Missing with Pair {}",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.missing_interface_method"]
}

pub fn bound_interface_methods_capture_the_receiver_once_test() {
  assert run("interface_once", [
      #(
        "main.pooka",
        "module main\n"
          <> printable
          <> "class User with Printable { print() { \"user\" } }\ncreate() -> Printable { echo(\"once\")\nUser() }\nmain() { echo { let print = create().print\n#(print(), print()) } }",
      ),
    ])
    == "\"once\"\n#(\"user\", \"user\")\n"
}

pub fn interface_views_are_covariant_inside_immutable_builtin_containers_test() {
  assert ids(
      printable
      <> "class User with Printable { print() { \"user\" } }\nrender(values: List(Printable)) { Nil }\nmain() { echo { let users: List(User) = [User()]\nrender(users) } }",
    )
    == []
}

pub fn annotated_polymorphic_methods_can_satisfy_concrete_requirements_test() {
  assert ids(
      "interface IntIdentity { id(value: Int) -> Int }\nclass Identity with IntIdentity { id(value: a) -> a { value } }",
    )
    == []
}

pub fn interface_dispatch_abstract_forms_snapshot_test() {
  let syntax =
    support.parse(
      "module main\ninterface Printable { print() -> String }\nclass User with Printable { print() { \"user\" } }\nrender(value: Printable) { let print = value.print\nprint() }\nmain() { render(User()) }",
    )
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  assert inferred.diagnostics == []
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  let assert Ok(generated) = erlang.generate(typed, "app", "main", dict.new())
  let assert Ok(_) = beam.compile(generated.forms)

  birdie.snap(
    beam.pretty(generated.forms),
    title: "codegen open interface dispatch",
  )
}

pub fn generic_class_parameters_hidden_by_an_interface_cannot_escape_test() {
  let source =
    "interface Named { name() -> String }\nclass Box(a) with Named { let value: a\nnew(value) { self.value = value }\nname() { \"box\" } }\n"
  assert ids(
      source
      <> "read(value: Named) { match value { Box(item) -> item\n_ -> panic } }",
    )
    == ["type.pattern_type_escape"]
  assert ids(
      source
      <> "read(value: Named) { match value { Box(_) -> value.value\n_ -> panic } }",
    )
    == ["type.pattern_type_escape"]
  assert ids(
      source
      <> "read(value: Named) { match value { Box(_) -> value.name()\n_ -> \"other\" } }",
    )
    == []
}

pub fn hidden_pattern_parameters_cannot_be_cast_to_a_chosen_type_test() {
  assert ids(
      "interface Named { name() -> String }\nclass Box(a) with Named { let value: a\nnew(value) { self.value = value }\nname() { \"box\" } }\nread(value: Named) { match value { Box(item) -> { let number: Int = item\nnumber }\n_ -> 0 } }",
    )
    == ["type.unification"]
}

pub fn returning_the_receiver_can_hide_unknown_arguments_through_its_interface_test() {
  assert ids(
      "interface Named { name() -> String }\nclass Box(a) with Named { let value: a\nnew(value) { self.value = value }\nname() { \"box\" } }\nkeep(value: Named) -> Named { match value { Box(_) -> value\n_ -> value } }",
    )
    == []
}

pub fn hidden_subclass_parameters_do_not_become_universal_return_types_test() {
  assert ids(
      "class Family {}\nclass Box(a) is Family { let value: a\nnew(value) { self.value = value } }\nread(value: Family) { match value { Box(item) -> item } }",
    )
    == ["type.pattern_type_escape"]
}

pub fn test_clients_can_implement_interfaces_used_by_production_callers_test() {
  use directory <- support.with_directory("interface_test_client")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/render.pooka",
    "module render\ninterface Printable { print() -> String }\nrender(value: Printable) { value.print() }",
  )
  support.write(
    directory <> "/test/render.spec.pooka",
    "module render_test\nimport render.{Printable}\nclass TestValue with Printable { print() { \"test\" } }\ntest \"test-local implementation\" { assert render.render(TestValue()) == \"test\" }",
  )
  let outcome = support.cli_main(["test"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
}
