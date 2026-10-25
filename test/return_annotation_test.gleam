//// Give every callable the same arrow home.
////
//// Check -> return annotations across functions, methods, callbacks and
//// foreign boundaries while : continues to annotate bindings and parameters.
//// Migration fixes must change only the old return separator. Written generic
//// results remain universal rather than being discarded during inference.
////
//// ```pooka
//// identity(value: Int) -> Int { value }
//// ```

import birdie
import cli/command
import compiler/parser/ast
import compiler/parser/parse_error
import compiler/typesystem/infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import diagnostics/fix
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support
import tools/formatter

pub fn arrows_parse_all_callable_signatures_test() {
  assert support.parse_errors(
      "module main\ninterface Reader { read() -> Int }\nclass Value { read() -> Int { 1 } }\nactor Counter { be increment() -> Nil { Nil }\nvalue() -> Int { 1 } }\nexternal Native from erlang \"erlang\" { abs(value: Int) -> Int }\nnative Fast from \"fast\" { run(value: Int) -> Int }\nmain() -> Int { 1 }\n",
    )
    == []
}

pub fn colons_still_annotate_parameters_fields_and_bindings_test() {
  assert support.parse_errors(
      "module main\nclass Box { let value: Int\nnew(value: Int) { self.value = value }\nget() -> Int { value } }\nmain(value: Int) -> Int {\nlet pair: #(Int, Int) = #(value, 2)\nlet #(first, second): #(Int, Int) = pair\nfirst + second\n}\n",
    )
    == []
}

pub fn return_types_are_optional_for_inferred_functions_and_methods_test() {
  assert support.parse_errors(
      "module main\nclass Value { get() { 1 } }\nmain() { Value().get() }\n",
    )
    == []
}

// The migration edits only the return separator. Parameter, field and binding
// colons remain valid syntax and must survive the fix.
pub fn colon_return_diagnostics_have_safe_automatic_fixes_test() {
  [
    "f(): Int { 1 }",
    "class Value { get(): Int { 1 } }",
    "actor Counter { be increment(): Nil { Nil } }",
    "interface Reader { read(): Int }",
    "main() { fn(value: Int): Int { value } }",
  ]
  |> list.each(fn(body) {
    let source = "module main\n" <> body <> "\n"
    let assert [error] = support.parse_errors(source)
    assert parse_error.id(error) == "parse.callable_colon_return"
    let edits =
      fix.automatic(
        [parse_error.to_diagnostic(error, support.path)],
        support.path,
      )
    let assert [_] = edits
    let assert Ok(migrated) = fix.apply(source, edits)
    assert support.parse_errors(migrated) == []
    assert string.contains(migrated, " ->")
  })
}

pub fn foreign_and_native_colons_are_still_rejected_test() {
  [
    "external Native from erlang \"erlang\" { abs(value: Int): Int }",
    "native Native from \"native\" { run(value: Int): Int }",
  ]
  |> list.each(fn(body) {
    let assert [parse_error.ExternalColonReturn(_)] =
      support.parse_errors("module main\n" <> body)
  })
}

pub fn annotated_anonymous_functions_retain_their_return_types_test() {
  let assert ast.AnonymousFunction(
    return_type: Some(ast.NamedType(None, "Int", [], _)),
    ..,
  ) = support.expression("fn(value: Int) -> Int { value + 1 }")
  let assert Ok(report) =
    infer.infer(
      support.expression("fn(value: Int) -> Int { value + 1 }"),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert report.diagnostics == []
  assert monotype.to_string(report.type_) == "fn(Int) -> Int"
}

// Keeping the written annotation in the AST is not enough. Feed it into
// inference so a callback body cannot contradict its promised result.
pub fn anonymous_return_types_are_checked_instead_of_discarded_test() {
  let assert Ok(report) =
    infer.infer(
      support.expression("fn(value: Int) -> String { value }"),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert list.any(report.diagnostics, fn(d) { d.id == "type.unification" })
  assert list.contains(
    support.diagnostic_ids("module main\nmain() { fn() -> Missing { 1 } }"),
    "analysis.unknown_type",
  )
}

pub fn formatter_preserves_arrow_annotations_and_binding_colons_test() {
  let source = "module main\nf(a:Int)->Int{let value:Int=a\nvalue}\n"
  let assert Ok(output) = formatter.format(source)
  assert output
    == "module main\n\nf(a: Int) -> Int {\n  let value: Int = a\n  value\n}\n"
  assert formatter.format(output) == Ok(output)
  assert support.parse_errors(output) == []
}

pub fn check_fix_migrates_existing_projects_test() {
  use directory <- support.with_directory("arrow_return_migration")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nidentity(value: Int): Int { value }\nmain(): Int { identity(1) }\n",
  )
  let report = support.cli_main(["check", "--fix"], command.plain(directory))
  assert report.status == 0
  let assert Ok(source) = simplifile.read(directory <> "/src/main.pooka")
  assert string.contains(source, "identity(value: Int) -> Int")
  assert string.contains(source, "main() -> Int")
  assert support.parse_errors(source) == []
}

pub fn arrow_signatures_execute_through_classes_interfaces_and_callbacks_test() {
  use directory <- support.with_directory("arrow_return_execution")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\ninterface Reader { read() -> Int }\nclass Value with Reader { read() -> Int { 42 } }\nread(value: Reader) -> Int { value.read() }\nmain() -> Nil { let add = fn(value: Int) -> Int { value + 1 }\necho add(read(Value()))\nNil }\n",
  )
  let report = support.cli_main(["run"], command.plain(directory))
  assert report.status == 0
  assert report.stdout == "43\n"
}

pub fn return_annotation_migration_diagnostic_snapshot_test() {
  support.rendered("module main\n\nidentity(value: Int): Int { value }\n")
  |> birdie.snap(title: "return types: colon migration diagnostic")
}

pub fn anonymous_generic_return_types_are_universal_test() {
  let assert Ok(valid) =
    infer.infer(
      support.expression("fn(value: a) -> a { value }"),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert valid.diagnostics == []
  let assert Ok(invalid) =
    infer.infer(
      support.expression("fn(value: a) -> a { 1 }"),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert list.any(invalid.diagnostics, fn(d) { d.id == "type.unification" })
}
