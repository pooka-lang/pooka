//// Pack the program so it can leave home.
////
//// Run exported escripts after relocation and removal of their original
//// project. The archive needs production BEAM modules, foreign code and real
//// resources, while test sources and discarded main results stay out of its
//// observable output. Failure cases check temporary-resource cleanup.

import builder/escript
import cli/command
import gleam/list
import gleam/string
import simplifile
import support

@external(erlang, "shipment_test_ffi", "run_escript")
fn execute(
  script: String,
  arguments: List(String),
  directory: String,
) -> #(Int, String)

@external(erlang, "shipment_test_ffi", "escript_files")
fn files(script: String) -> List(String)

fn project(directory: String, source: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
}

// Remove the original project before launching the copy. Otherwise an export
// with hidden absolute paths could pass by borrowing files still at home.
pub fn escript_runs_after_relocation_without_the_project_test() {
  use directory <- support.with_directory("escript_relocation")
  let original = directory <> "/project"
  project(original, "main() { echo 42 }")
  let assert Ok(report) = escript.export(original)
  let moved = directory <> "/moved script ' Δοκιμή"
  let assert Ok(Nil) = simplifile.copy_file(report.path, moved)
  let assert Ok(Nil) = simplifile.delete(original)
  assert execute(moved, [], directory) == #(0, "src/main.pooka:2\n42\n")
  let assert Ok(entries) = simplifile.read_directory(directory)
  assert !list.any(entries, string.starts_with(_, "pooka-escript-"))
}

pub fn escript_discards_main_results_and_excludes_tests_test() {
  use directory <- support.with_directory("escript_silent_production")
  project(directory, "main() { 42 }")
  support.write(directory <> "/test/invalid.spec.pooka", "invalid syntax")
  let report = support.cli_main(["export", "escript"], command.plain(directory))
  assert report.status == 0
  assert report.stdout == "Exported escript to build/app.\n"
  assert execute(directory <> "/build/app", [], directory) == #(0, "")
  let packaged = files(directory <> "/build/app")
  assert list.contains(packaged, "app/ebin/app.app")
  assert list.contains(packaged, "app/ebin/pooka@app@main.beam")
  assert !list.any(packaged, string.ends_with(_, ".erl"))
  assert !list.any(packaged, string.contains(_, "$test"))
  assert !list.any(packaged, string.contains(_, "compiler@"))
}

pub fn escript_preserves_foreign_modules_and_real_priv_resources_test() {
  use directory <- support.with_directory("escript_resources")
  project(
    directory,
    "external Resource from erlang \"resource\" { read() -> String }\nmain() { echo Resource.read() }",
  )
  support.write(directory <> "/priv/nested/answer.txt", "forty two")
  support.write(
    directory <> "/ffi/resource.erl",
    "-module(resource).\n-export([read/0]).\nread() -> {ok, Content} = file:read_file(filename:join([code:priv_dir(app), \"nested\", \"answer.txt\"])), Content.\n",
  )
  support.write(directory <> "/build/app.escript", "previous generated export")
  let assert Ok(report) = escript.export(directory)
  assert report.path == directory <> "/build/app"
  assert simplifile.is_file(directory <> "/build/app.escript") == Ok(False)
  assert list.contains(files(report.path), "app/priv/nested/answer.txt")
  assert execute(report.path, [], directory)
    == #(0, "src/main.pooka:3\n\"forty two\"\n")
}

pub fn escript_reports_failures_and_cleans_temporary_resources_test() {
  use directory <- support.with_directory("escript_failure")
  project(directory, "main() { panic as \"expected failure\" }")
  let assert Ok(report) = escript.export(directory)
  let #(status, output) = execute(report.path, [], directory)
  assert status == 1
  assert string.contains(output, "panic: expected failure")
  let assert Ok(entries) = simplifile.read_directory(directory)
  assert !list.any(entries, string.starts_with(_, "pooka-escript-"))
}

pub fn failed_exports_preserve_the_previous_executable_test() {
  use directory <- support.with_directory("escript_transaction")
  project(directory, "main() { echo 42 }")
  let assert Ok(report) = escript.export(directory)
  let assert Ok(before) = simplifile.read_bits(report.path)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { 1 + True }",
  )
  let assert Error(_) = escript.export(directory)
  assert simplifile.read_bits(report.path) == Ok(before)
  assert execute(report.path, [], directory) == #(0, "src/main.pooka:2\n42\n")
}
