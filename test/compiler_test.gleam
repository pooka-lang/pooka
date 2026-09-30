//// Keep each front-end report attached to its own source.
////
//// Exercise the public single-source compiler entry point: module names,
//// paths, phase diagnostics and resolution results. Lexing and parsing may
//// both have useful news, but their reports should arrive in source order
//// without stale diagnostics from an earlier project pass.

import compiler/compiler
import gleam/dict
import gleam/list
import gleam/set
import support

pub fn clean_source_has_no_diagnostics_test() {
  let checked =
    compiler.check_source(
      "src/main.pooka",
      "module main\n\nmain() {\n  Nil\n}\n",
    )
  assert checked.diagnostics == []
}

pub fn expected_module_paths_test() {
  assert compiler.expected_module_path("src/user.pooka") == Ok("user")
  assert compiler.expected_module_path("src/http/client.pooka")
    == Ok("http/client")
  assert compiler.expected_module_path("test/user.spec.pooka") == Error(Nil)
}

pub fn expected_module_names_test() {
  assert compiler.expected_module_name("src/user.pooka") == Ok("user")
  assert compiler.expected_module_name("src/http/client.pooka") == Ok("client")
  assert compiler.expected_module_name("test/user.spec.pooka") == Error(Nil)
}

pub fn a_nested_module_declares_only_its_own_name_test() {
  let checked =
    compiler.check_source("src/http/client.pooka", "module client\n")
  assert checked.diagnostics == []
}

pub fn module_name_must_match_the_file_test() {
  let checked =
    compiler.check_source("src/http/client.pooka", "module server\n")
  assert list.map(checked.diagnostics, fn(d) { d.id })
    == ["module.name_mismatch"]
}

pub fn module_header_with_a_matching_path_test() {
  let checked =
    compiler.check_source("src/http/client.pooka", "module http/client\n")
  assert list.map(checked.diagnostics, fn(d) { d.id })
    == ["parse.module_header_path"]
}

pub fn test_files_may_name_their_module_freely_test() {
  let checked =
    compiler.check_source("test/user.spec.pooka", "module user_test\n")
  assert checked.diagnostics == []
}

// One malformed token need not hide an independent syntax error elsewhere.
// The combined front end should retain both useful reports in source order.
pub fn lexical_and_syntax_errors_are_reported_together_test() {
  let ids =
    support.diagnostic_ids(
      "module main\n\nfirst() {\n  let a = 0b2\n}\n\nsecond() {\n  let b = )\n}\n",
    )
  assert ids == ["lex.invalid_number", "parse.unexpected_token"]
}

pub fn diagnostics_are_in_source_order_test() {
  let checked =
    compiler.check_source(
      "src/main.pooka",
      "module main\n\nfirst() {\n  let a = )\n}\n\nsecond() {\n  let b = 0b2\n}\n",
    )
  let lines =
    list.map(checked.diagnostics, fn(diagnostic) {
      let assert [label, ..] = diagnostic.labels
      label.location.span.start.line
    })
  assert lines == [4, 8]
}

pub fn local_resolution_is_part_of_the_front_end_test() {
  let ids =
    support.diagnostic_ids(
      "module main\nf(value) { missing(value) }\ng(value: Missing) { value }\n",
    )
  assert ids == ["analysis.unknown_name", "analysis.unknown_type"]
}

pub fn forward_names_and_nested_bindings_resolve_in_the_front_end_test() {
  assert support.diagnostic_ids(
      "module main\nmain() { identity(1) }\nidentity(value) { let result = value\nresult }",
    )
    == []
}

// Project context can refine an earlier single-module preview. Replace that
// resolution report rather than appending stale complaints to the new answer.
pub fn project_resolution_replaces_its_previous_diagnostics_test() {
  let file =
    compiler.check_source(
      "src/main.pooka",
      "module main\nimport account\nf() { account.missing()\nunknown }\n",
    )
  assert list.length(file.diagnostics) == 1
  let exports = dict.from_list([#("account", set.from_list(["load"]))])
  let resolved = compiler.with_exports(file, exports)
  assert list.map(resolved.diagnostics, fn(value) { value.id })
    == ["analysis.unknown_module_member", "analysis.unknown_name"]
  assert compiler.with_exports(resolved, exports).diagnostics
    == resolved.diagnostics
}
