//// A binding's written coat is the one its later callers should see.
////
//// Check the published result as well as diagnostics: merely accepting the
//// initializer is not enough when a generic call later shares that type.

import birdie
import cli/command
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

const apply = "apply(value: a, change: fn(a) -> a) -> a { change(value) }\n"

pub fn tuple_annotations_apply_to_whole_values_and_destructured_bindings_test() {
  let report =
    infer(
      apply
      <> "whole() { let pair: #(Base, Int) = #(A(), 1)\nlet #(value, _) = pair\napply(value, fn(_) { B() }) }\npattern() { let #(value, _): #(Base, Int) = #(A(), 1)\napply(value, fn(_) { B() }) }",
    )
  assert report.diagnostics == []
  assert signature(report, "whole") == "fn() -> main.Base"
  assert signature(report, "pattern") == "fn() -> main.Base"
}

pub fn collection_annotations_are_not_narrowed_by_the_first_element_test() {
  let report =
    infer(
      apply
      <> "main() { let values: List(Base) = [A()]\napply(values, fn(_) { [B()] }) }",
    )
  assert report.diagnostics == []
  assert signature(report, "main") == "fn() -> List(main.Base)"
}

pub fn option_and_result_annotations_preserve_their_inner_views_test() {
  let report =
    infer(
      apply
      <> "maybe() { let value: Option(Base) = Some(A())\napply(value, fn(_) { Some(B()) }) }\noutcome() { let value: Result(Base, String) = Ok(A())\napply(value, fn(_) { Ok(B()) }) }",
    )
  assert report.diagnostics == []
  assert signature(report, "maybe") == "fn() -> Option(main.Base)"
  assert signature(report, "outcome") == "fn() -> Result(main.Base, String)"
}

pub fn nested_tuple_and_list_patterns_receive_the_declared_types_test() {
  let report =
    infer(
      apply
      <> "main() { let #(values, maybe): #(List(Base), Option(Base)) = #([A()], Some(A()))\n#(apply(values, fn(_) { [B()] }), apply(maybe, fn(_) { Some(B()) })) }",
    )
  assert report.diagnostics == []
  assert signature(report, "main")
    == "fn() -> #(List(main.Base), Option(main.Base))"
}

pub fn let_assert_preserves_an_annotated_payload_view_test() {
  let report =
    infer(
      apply
      <> "main() { let assert Some(value): Option(Base) = Some(A())\napply(value, fn(_) { B() }) }",
    )
  assert report.diagnostics == []
  assert signature(report, "main") == "fn() -> main.Base"
}

pub fn generic_parent_annotations_keep_independent_arguments_test() {
  let report =
    infer(
      "class Parent(a) { let value: a\nnew(value: a) { self.value = value } }\nclass Child(a) is Parent(a) { new(value: a) { super.new(value) } }\nmain() { let first: Parent(Int) = Child(1)\nlet second: Parent(String) = Child(\"owl\")\n#(first, second) }",
    )
  assert report.diagnostics == []
  assert signature(report, "main")
    == "fn() -> #(main.Parent(Int), main.Parent(String))"
}

pub fn interface_annotations_are_open_views_for_generic_calls_test() {
  let report =
    infer(
      "interface Reader { read() -> Int }\nclass One with Reader { read() -> Int { 1 } }\nclass Two with Reader { read() -> Int { 2 } }\n"
      <> apply
      <> "main() { let reader: Reader = One()\napply(reader, fn(_) { Two() }) }",
    )
  assert report.diagnostics == []
  assert signature(report, "main") == "fn() -> main.Reader"
}

pub fn annotation_does_not_expose_subclass_only_members_snapshot_test() {
  let source =
    "module main\nclass Base {}\nclass A is Base { only_a() -> Int { 1 } }\nmain() {\n  let value: Base = A()\n  value.only_a()\n}\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert list.length(report.diagnostics) == 1
  support.render_all(report.diagnostics, source)
  |> birdie.snap(
    title: "types: annotated binding exposes only its declared view",
  )
}

fn run(name: String, source: String) -> command.Outcome {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
  support.cli_main(["run"], command.plain(directory))
}

pub fn widened_binding_views_execute_with_subclass_dispatch_test() {
  let report =
    run(
      "annotated_binding_dispatch",
      "class Base { tag() -> String { \"base\" } }\nclass A is Base { tag() -> String { \"a\" } }\nclass B is Base { tag() -> String { \"b\" } }\n"
        <> apply
        <> "main() { let value: Base = A()\nassert apply(value, fn(_) { B() }).tag() == \"b\"\nlet #(nested, _): #(Base, Int) = #(A(), 1)\nassert apply(nested, fn(_) { B() }).tag() == \"b\"\nlet values: List(Base) = [A()]\nlet assert [selected] = apply(values, fn(_) { [B()] })\nassert selected.tag() == \"b\" }",
    )
  assert report.status == 0
  assert support.diagnostics(report.stderr) == ""
}

pub fn annotated_interface_views_execute_with_another_implementation_test() {
  let report =
    run(
      "annotated_interface_dispatch",
      "interface Reader { read() -> Int }\nclass One with Reader { read() -> Int { 1 } }\nclass Two with Reader { read() -> Int { 2 } }\n"
        <> apply
        <> "main() { let reader: Reader = One()\nassert apply(reader, fn(_) { Two() }).read() == 2 }",
    )
  assert report.status == 0
  assert support.diagnostics(report.stderr) == ""
}
