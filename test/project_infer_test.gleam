//// A client should receive a checked interface, not a borrowed local scope.
////
//// Infer temporary multi-module projects in dependency order. Imported
//// signatures, namespaces and type errors must keep their source ownership.
//// Tests can consume production interfaces without publishing their private
//// helper modules to ordinary imports.

import builder/check
import builder/infer
import compiler/typesystem/monotype
import diagnostics/diagnostic
import gleam/list
import support

fn project(directory: String) -> Nil {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
}

pub fn dependencies_are_inferred_before_callers_test() {
  use directory <- support.with_directory("infer_project_order")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers as util\nmain() { #(util.identity(1), util.identity(\"s\")) }",
  )
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\nidentity(value: a) -> a { value }",
  )
  let assert Ok(report) = infer.preview(directory)
  assert report.diagnostics == []
  assert list.map(report.modules, fn(value) { value.identity })
    == ["helpers", "main"]
  let assert [_, main] = report.modules
  let assert [function] = main.inferred.functions
  assert monotype.to_string(function.type_) == "fn() -> #(Int, String)"
}

// An alias changes the local name, not the polymorphic signature supplied by
// the exporting module. Each use must instantiate that same exported scheme
// correctly.
pub fn selective_import_aliases_share_the_exported_scheme_test() {
  use directory <- support.with_directory("infer_project_selective")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers.{identity as id}\nmain() { #(id(1), helpers.identity(\"s\")) }",
  )
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\nidentity(value) { value }",
  )
  let assert Ok(report) = infer.preview(directory)
  assert report.diagnostics == []
  let assert [_, main] = report.modules
  let assert [function] = main.inferred.functions
  assert monotype.to_string(function.type_) == "fn() -> #(Int, String)"
}

pub fn qualified_argument_mismatches_are_reported_test() {
  use directory <- support.with_directory("infer_project_mismatch")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers\nmain() { helpers.describe(\"wrong\") }",
  )
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\ndescribe(value: Int) -> String { \"ok\" }",
  )
  let assert Ok(report) = infer.preview(directory)
  let assert [value] = report.diagnostics
  assert value.id == "type.unification"
  let assert Ok(at) = diagnostic.primary_location(value)
  assert at.path == "src/main.pooka"
}

pub fn module_names_are_not_first_class_values_test() {
  use directory <- support.with_directory("infer_project_module_value")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers\nmain() { helpers }",
  )
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\nidentity(value) { value }",
  )
  let assert Ok(report) = infer.preview(directory)
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.module_as_value"]
}

pub fn typed_external_signatures_can_be_imported_test() {
  use directory <- support.with_directory("infer_project_external")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport ffi.{Native}\nimport ffi as native\nmain() { #(Native.read(1), native.Native.read(2)) }",
  )
  support.write(
    directory <> "/src/ffi.pooka",
    "module ffi\nexternal Native from erlang \"native\" {\n  read(value: Int) -> String\n}",
  )
  let assert Ok(report) = infer.preview(directory)
  assert report.diagnostics == []
}

pub fn imported_namespaces_check_their_functions_test() {
  use directory <- support.with_directory("infer_project_external_unknown")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport ffi.{Native}\nmain() { Native.write(1) }",
  )
  support.write(
    directory <> "/src/ffi.pooka",
    "module ffi\nexternal Native from erlang \"native\" {\n  read(value: Int) -> String\n}",
  )
  let assert Ok(report) = infer.preview(directory)
  assert list.map(report.diagnostics, fn(d) { d.id })
    == ["type.unknown_external_function"]
}

pub fn private_namespaces_are_not_importable_test() {
  use directory <- support.with_directory("infer_project_external_private")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport ffi\nmain() { ffi._Native.read(1) }",
  )
  support.write(
    directory <> "/src/ffi.pooka",
    "module ffi\nexternal _Native from erlang \"native\" {\n  read(value: Int) -> String\n}",
  )
  let assert Error(infer.InvalidProgram(checked)) = infer.preview(directory)
  assert list.map(check.diagnostics(checked), fn(d) { d.id })
    |> list.contains("analysis.private_declaration")
}

pub fn result_propagation_keeps_imported_error_types_test() {
  use directory <- support.with_directory("infer_project_result")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers.{read}\nmain() { let value = read(1)?\nOk(value) }",
  )
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\nread(value: Int) -> Result(Int, String) { Ok(value) }",
  )
  let assert Ok(report) = infer.preview(directory)
  assert report.diagnostics == []
  let assert [_, main] = report.modules
  let assert [function] = main.inferred.functions
  assert monotype.to_string(function.type_) == "fn() -> Result(Int, String)"
}

pub fn test_files_consume_production_interfaces_test() {
  use directory <- support.with_directory("infer_project_tests")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nidentity(value) { value }",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\nimport main\ntest \"identity\" { assert main.identity(1) == 1 }",
  )
  let assert Ok(report) = infer.preview(directory)
  assert report.diagnostics == []
  assert list.map(report.modules, fn(value) { value.path })
    == ["src/main.pooka", "test/main.spec.pooka"]
}

pub fn test_helpers_do_not_become_importable_modules_test() {
  use directory <- support.with_directory("infer_project_test_visibility")
  project(directory)
  support.write(directory <> "/src/main.pooka", "module main\n")
  support.write(
    directory <> "/test/first.spec.pooka",
    "module first\nhelper() { 1 }",
  )
  support.write(
    directory <> "/test/second.spec.pooka",
    "module second\nimport first\ntest \"helper\" { assert first.helper() == 1 }",
  )

  let assert Error(infer.InvalidProgram(checked)) = infer.preview(directory)
  let assert [diagnostic] = check.diagnostics(checked)
  assert diagnostic.id == "module.unknown"
  let assert Ok(label) = diagnostic.primary_location(diagnostic)
  assert label.path == "test/second.spec.pooka"
}

pub fn unresolved_dependencies_are_explicit_preview_limits_test() {
  use directory <- support.with_directory("infer_project_dependency")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport network\nmain() { network.println(\"hello\") }",
  )

  let assert Error(infer.InvalidProgram(checked)) = infer.preview(directory)
  assert list.map(check.diagnostics(checked), fn(d) { d.id })
    == ["module.unknown"]
}

pub fn interface_requirements_state_their_full_signature_test() {
  use directory <- support.with_directory("infer_project_nominal")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\ninterface Incomplete { read() }\nmain() { Nil }",
  )

  let assert Error(infer.InvalidProgram(checked)) = infer.preview(directory)
  assert list.map(check.diagnostics(checked), fn(d) { d.id })
    == ["parse.requirement_missing_return_type"]
}

pub fn structural_errors_stop_the_preview_before_typing_test() {
  use directory <- support.with_directory("infer_project_structural")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { missing() }",
  )
  let assert Error(infer.InvalidProgram(_)) = infer.preview(directory)
}

pub fn circular_modules_stop_the_preview_test() {
  use directory <- support.with_directory("infer_project_cycle")
  project(directory)
  support.write(directory <> "/src/a.pooka", "module a\nimport b")
  support.write(directory <> "/src/b.pooka", "module b\nimport a")
  let assert Error(infer.InvalidProgram(_)) = infer.preview(directory)
}

pub fn project_loading_errors_remain_distinct_test() {
  use directory <- support.with_directory("infer_project_not_found")
  let assert Error(infer.ProjectFailed(_)) = infer.preview(directory)
}

pub fn match_coverage_errors_keep_dependency_source_locations_test() {
  use directory <- support.with_directory("infer_project_coverage")
  project(directory)
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\nchoose(flag: Bool) { match flag { True -> 1 } }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers\nmain() { helpers.choose(False) }",
  )
  let assert Ok(report) = infer.preview(directory)
  let assert [value] = report.diagnostics
  assert value.id == "type.non_exhaustive_match"
  let assert Ok(at) = diagnostic.primary_location(value)
  assert at.path == "src/helpers.pooka"
}

// A warning does not invalidate a typed public interface. Clients must still
// receive the usable signatures after the warning is recorded.
pub fn unreachable_branch_warnings_preserve_imported_signatures_test() {
  use directory <- support.with_directory("infer_project_unreachable")
  project(directory)
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\nchoose(flag: Bool) { match flag { _ -> 1\nTrue -> 2 } }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers\nmain() { helpers.choose(False) }",
  )
  let assert Ok(report) = infer.preview(directory)
  let assert [value] = report.diagnostics
  assert value.id == "type.unreachable_pattern"
  let assert [_, main] = report.modules
  let assert [function] = main.inferred.functions
  assert monotype.to_string(function.type_) == "fn() -> Int"
}

pub fn binary_layout_errors_in_test_clients_are_reported_test() {
  use directory <- support.with_directory("infer_project_binary_layout")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nidentity(value) { value }",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main\nimport main.{identity}\ntest \"binary layout\" { identity(<<<<1:1>>:bytes>>) }",
  )
  let assert Ok(report) = infer.preview(directory)
  let assert [value] = report.diagnostics
  assert value.id == "type.unaligned_bit_array_segment"
  let assert Ok(at) = diagnostic.primary_location(value)
  assert at.path == "test/main.spec.pooka"
}
