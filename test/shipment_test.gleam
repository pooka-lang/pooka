//// Pack the library, then take away the old address.
////
//// Run directory shipments after relocation, preserving production
//// dependencies, foreign modules and runtime resources. Launchers must pass
//// arguments faithfully. Staging and symlink cases ensure a failed or replaced
//// export does not damage an earlier shipment or another directory.

import birdie
import builder/shipment
import cli/command
import gleam/list
import gleam/string
import simplifile
import support

@external(erlang, "shipment_test_ffi", "run")
fn execute(
  script: String,
  arguments: List(String),
  directory: String,
) -> #(Int, String)

@external(erlang, "shipment_test_ffi", "has_executable")
fn has_executable(name: String) -> Bool

fn project(directory: String, source: String) -> Nil {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
}

pub fn shipment_runs_after_relocation_without_the_project_test() {
  use directory <- support.with_directory("shipment_relocation")
  let original = directory <> "/original"
  project(original, "main() { echo { 42 } }")
  let assert Ok(report) = shipment.export(original)
  let moved = directory <> "/moved shipment ' Δοκιμή"
  let assert Ok(Nil) = simplifile.copy_directory(report.directory, moved)
  let assert Ok(Nil) = simplifile.delete(original)
  assert execute(moved <> "/entrypoint.sh", ["run"], directory)
    == #(0, "src/main.pooka:2\n42\n")
}

pub fn shipment_contains_only_production_artifacts_test() {
  use directory <- support.with_directory("shipment_production")
  project(directory, "main() { echo { 42 } }")
  support.write(directory <> "/test/invalid.spec.pooka", "invalid syntax")
  let assert Ok(report) = shipment.export(directory <> "/src")
  let assert Ok(files) = simplifile.get_files(report.directory)
  assert list.all(files, fn(path) {
    !string.ends_with(path, ".erl")
    && !string.ends_with(path, ".abstr")
    && !string.contains(path, "test.pooka")
    && !string.contains(path, "_pooka_artefacts")
  })
  let assert Ok(app) = simplifile.read(report.directory <> "/app/ebin/app.app")
  assert !string.contains(app, "$test")
  assert string.contains(app, "pooka@app@@entrypoint")
  assert simplifile.is_file(
      report.directory <> "/app/ebin/pooka@app@@runtime.beam",
    )
    == Ok(True)
  assert execute(report.directory <> "/entrypoint.sh", [], directory)
    == #(0, "src/main.pooka:2\n42\n")
}

pub fn shipment_includes_foreign_beams_and_runtime_priv_resources_test() {
  use directory <- support.with_directory("shipment_priv")
  let original = directory <> "/original"
  project(
    original,
    "external Resource from erlang \"resource\" { read() -> Result(String, String) }\nmain() { echo { let assert Ok(text) = Resource.read()\ntext } }",
  )
  support.write(
    original <> "/ffi/resource.erl",
    "-module(resource).\n-export([read/0]).\nread() -> file:read_file(filename:join(code:priv_dir(app), \"nested/data.txt\")).\n",
  )
  support.write(original <> "/priv/nested/data.txt", "portable")
  let assert Ok(report) = shipment.export(original)
  let moved = directory <> "/moved"
  let assert Ok(Nil) = simplifile.copy_directory(report.directory, moved)
  let assert Ok(Nil) = simplifile.delete(original)
  assert execute(moved <> "/entrypoint.sh", ["run"], directory)
    == #(0, "src/main.pooka:3\n\"portable\"\n")
}

pub fn shipment_preserves_resource_permissions_test() {
  use directory <- support.with_directory("shipment_permissions")
  project(directory, "main() { Nil }")
  support.write(directory <> "/priv/helper", "#!/bin/sh\nexit 0\n")
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(directory <> "/priv/helper", 0o755)
  let assert Ok(report) = shipment.export(directory)
  let assert Ok(resource) =
    simplifile.file_info(report.directory <> "/app/priv/helper")
  assert simplifile.file_info_permissions_octal(resource) == 0o755
  let assert Ok(launcher) =
    simplifile.file_info(report.directory <> "/entrypoint.sh")
  assert simplifile.file_info_permissions_octal(launcher) == 0o755
}

pub fn failed_build_preserves_a_previous_shipment_test() {
  use directory <- support.with_directory("shipment_failed_build")
  project(directory, "main() { echo { 42 } }")
  let assert Ok(first) = shipment.export(directory)
  let assert Ok(beam) =
    simplifile.read_bits(first.directory <> "/app/ebin/pooka@app@main.beam")
  project(directory, "main() { echo { 1 + True } }")
  let assert Error(_) = shipment.export(directory)
  assert simplifile.read_bits(
      first.directory <> "/app/ebin/pooka@app@main.beam",
    )
    == Ok(beam)
  assert execute(first.directory <> "/entrypoint.sh", ["run"], directory)
    == #(0, "src/main.pooka:2\n42\n")
}

// Resource copying can fail after compilation succeeded. Publish from staging
// only when every part is ready, preserving the previous shipment on failure.
pub fn failed_resource_copy_preserves_previous_shipment_and_cleans_staging_test() {
  use directory <- support.with_directory("shipment_failed_resource")
  project(directory, "main() { echo { 42 } }")
  let assert Ok(first) = shipment.export(directory)
  support.write(directory <> "/outside", "not a resource")
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/priv")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      directory <> "/outside",
      directory <> "/priv/link",
    )
  let assert Error(error) = shipment.export(directory)
  assert list.any(error.diagnostics, fn(value) {
    value.id == "export.resource_symlink"
  })
  assert execute(first.directory <> "/entrypoint.sh", ["run"], directory)
    == #(0, "src/main.pooka:2\n42\n")
  let assert Ok(entries) = simplifile.read_directory(directory <> "/build")
  assert !list.any(entries, string.contains(_, "shipment.tmp-"))
}

pub fn reexport_replaces_obsolete_resources_and_modules_test() {
  use directory <- support.with_directory("shipment_replace")
  project(directory, "main() { echo { 1 } }")
  support.write(directory <> "/priv/old.txt", "old")
  support.write(directory <> "/src/old.pooka", "module old\nvalue() { 1 }")
  let assert Ok(_) = shipment.export(directory)
  let assert Ok(Nil) = simplifile.delete_file(directory <> "/src/old.pooka")
  let assert Ok(Nil) = simplifile.delete_file(directory <> "/priv/old.txt")
  project(directory, "main() { echo { 2 } }")
  let assert Ok(second) = shipment.export(directory)
  assert simplifile.is_file(second.directory <> "/app/ebin/pooka@app@old.beam")
    == Ok(False)
  assert simplifile.is_file(second.directory <> "/app/priv/old.txt")
    == Ok(False)
  assert execute(second.directory <> "/entrypoint.sh", ["run"], directory)
    == #(0, "src/main.pooka:2\n2\n")
}

pub fn shipment_launcher_preserves_program_arguments_test() {
  use directory <- support.with_directory("shipment_arguments")
  project(
    directory,
    "external Args from erlang \"args\" { valid() -> Bool }\nmain() { echo { Args.valid() } }",
  )
  support.write(
    directory <> "/ffi/args.erl",
    "-module(args).\n-export([valid/0]).\nvalid() -> init:get_plain_arguments() =:= [\"a b\", \"'quoted'\", \"$(data)\"].\n",
  )
  let assert Ok(report) = shipment.export(directory)
  assert execute(
      report.directory <> "/entrypoint.sh",
      ["run", "a b", "'quoted'", "$(data)"],
      directory,
    )
    == #(0, "src/main.pooka:3\nTrue\n")
}

pub fn shipment_failure_returns_a_nonzero_exit_status_test() {
  use directory <- support.with_directory("shipment_panic")
  project(directory, "main() { echo { panic as \"deployment failure\" } }")
  let assert Ok(report) = shipment.export(directory)
  let #(status, output) =
    execute(report.directory <> "/entrypoint.sh", ["run"], directory)
  assert status == 1
  assert string.contains(output, "panic: deployment failure")
}

pub fn missing_entrypoint_and_bad_arguments_are_diagnostics_test() {
  use directory <- support.with_directory("shipment_cli_errors")
  project(directory, "helper() { 42 }")
  let outcome =
    support.cli_main(["export", "shipment"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "missing executable entrypoint")
  let outcome =
    support.cli_main(
      ["export", "shipment", "--extra"],
      command.plain(directory),
    )
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "does not accept")
  assert simplifile.is_directory(directory <> "/build/shipment") == Ok(False)
}

pub fn shipment_bundles_the_elixir_runtime_when_needed_test() {
  case has_executable("elixirc") {
    False -> Nil
    True -> {
      use directory <- support.with_directory("shipment_elixir_runtime")
      let original = directory <> "/original"
      project(
        original,
        "external Formatter from elixir \"Formatter\" { upper(text: String) -> String }\nmain() { echo { Formatter.upper(\"portable\") } }",
      )
      support.write(
        original <> "/ffi/formatter.ex",
        "defmodule Formatter do\n  def upper(text), do: String.upcase(text)\nend\n",
      )
      let assert Ok(report) = shipment.export(original)
      assert simplifile.is_file(report.directory <> "/elixir/ebin/elixir.app")
        == Ok(True)
      assert simplifile.is_directory(report.directory <> "/ex_unit")
        == Ok(False)
      let moved = directory <> "/moved"
      let assert Ok(Nil) = simplifile.copy_directory(report.directory, moved)
      let assert Ok(Nil) = simplifile.delete(original)
      assert execute(moved <> "/entrypoint.sh", ["run"], directory)
        == #(0, "src/main.pooka:3\n\"PORTABLE\"\n")
    }
  }
}

pub fn shipment_launcher_snapshot_test() {
  let bootstrap = "pooka@app@@entrypoint"
  let scripts =
    shipment.shell_script(bootstrap)
    <> "\n--- PowerShell ---\n"
    <> shipment.powershell_script(bootstrap)
  birdie.snap(scripts, title: "shipment portable launchers")
}

// A stale BEAM file in the output directory is not automatically part of the
// package graph. Bundle owned production modules, not every file found
// nearby.
pub fn shipment_does_not_bundle_unowned_build_modules_test() {
  use directory <- support.with_directory("shipment_owned_modules")
  project(directory, "main() { echo { 42 } }")
  let assert Ok(first) = shipment.export(directory)
  support.write(
    first.build.directory <> "/unowned.beam",
    "not an application module",
  )
  support.write(
    first.build.layout.target <> "/unrelated/ebin/unrelated.beam",
    "not a dependency",
  )
  let assert Ok(second) = shipment.export(directory)
  assert simplifile.is_file(second.directory <> "/app/ebin/unowned.beam")
    == Ok(False)
  assert simplifile.is_directory(second.directory <> "/unrelated") == Ok(False)
  assert execute(second.directory <> "/entrypoint.sh", ["run"], directory)
    == #(0, "src/main.pooka:2\n42\n")
}

pub fn replacing_a_shipment_symlink_preserves_its_target_test() {
  use directory <- support.with_directory("shipment_output_symlink")
  project(directory, "main() { echo { 42 } }")
  support.write(directory <> "/outside/keep.txt", "keep")
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/build")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      directory <> "/outside",
      directory <> "/build/shipment",
    )
  let assert Ok(report) = shipment.export(directory)
  assert simplifile.is_symlink(report.directory) == Ok(False)
  assert simplifile.read(directory <> "/outside/keep.txt") == Ok("keep")
  assert execute(report.directory <> "/entrypoint.sh", ["unknown"], directory).0
    == 1
}

pub fn malformed_export_arguments_do_not_build_the_project_test() {
  use directory <- support.with_directory("shipment_format_errors")
  project(directory, "main() { echo { 1 + True } }")
  let missing = support.cli_main(["export"], command.plain(directory))
  assert missing.status == 1
  assert string.contains(missing.stderr, "missing export format")
  let unknown =
    support.cli_main(["export", "shipmnt"], command.plain(directory))
  assert unknown.status == 1
  assert string.contains(unknown.stderr, "pooka export shipment")
  assert simplifile.is_directory(directory <> "/build") == Ok(False)
}

pub fn invalid_priv_type_preserves_the_previous_shipment_test() {
  use directory <- support.with_directory("shipment_priv_type")
  project(directory, "main() { echo { 42 } }")
  let assert Ok(first) = shipment.export(directory)
  support.write(directory <> "/priv", "not a directory")
  let assert Error(error) = shipment.export(directory)
  assert list.any(error.diagnostics, fn(value) {
    value.id == "export.resource_type"
  })
  assert execute(first.directory <> "/entrypoint.sh", ["run"], directory)
    == #(0, "src/main.pooka:2\n42\n")
}

pub fn foreign_bootstrap_collision_is_an_export_diagnostic_test() {
  use directory <- support.with_directory("shipment_bootstrap_collision")
  project(directory, "main() { echo { 42 } }")
  support.write(
    directory <> "/ffi/conflict.erl",
    "-module('pooka@app@@entrypoint').\n-export([value/0]).\nvalue() -> 1.\n",
  )
  let assert Error(error) = shipment.export(directory)
  assert list.any(error.diagnostics, fn(value) {
    value.id == "export.module_collision"
  })
  assert simplifile.is_directory(directory <> "/build/shipment") == Ok(False)
}

pub fn elixir_library_only_external_does_not_need_project_elixir_source_test() {
  case has_executable("elixir") {
    False -> Nil
    True -> {
      use directory <- support.with_directory("shipment_elixir_library")
      project(
        directory,
        "external Text from elixir \"String\" { upcase(text: String) -> String }\nmain() { echo { Text.upcase(\"portable\") } }",
      )
      let assert Ok(report) = shipment.export(directory)
      assert execute(report.directory <> "/entrypoint.sh", ["run"], directory)
        == #(0, "src/main.pooka:3\n\"PORTABLE\"\n")
    }
  }
}

pub fn shipment_includes_referenced_elixir_apps_and_their_dependencies_test() {
  case has_executable("elixir") {
    False -> Nil
    True -> {
      use directory <- support.with_directory("shipment_elixir_application")
      project(
        directory,
        "external Template from elixir \"EEx\" { eval_string(source: String) -> String }\nmain() { echo { Template.eval_string(\"<%= 40 + 2 %>\") } }",
      )
      let assert Ok(report) = shipment.export(directory)
      assert simplifile.is_file(report.directory <> "/eex/ebin/eex.app")
        == Ok(True)
      assert simplifile.is_file(report.directory <> "/elixir/ebin/elixir.app")
        == Ok(True)
      assert execute(report.directory <> "/entrypoint.sh", ["run"], directory)
        == #(0, "src/main.pooka:3\n\"42\"\n")
    }
  }
}

// Repacking an executable must not replace the library's manifest label with
// the old generic description. The embedded runtime stays in this package's module inventory.
pub fn shipment_keeps_metadata_and_embeds_its_runtime_module_test() {
  use directory <- support.with_directory("shipment_metadata")
  project(directory, "main() { Nil }")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ndescription = \"A travelling application\"\nlicences = [\"MIT\"]\n",
  )
  let assert Ok(report) = shipment.export(directory)
  let assert Ok(resource) =
    simplifile.read(report.directory <> "/app/ebin/app.app")
  assert string.contains(resource, "A travelling application")
  assert string.contains(resource, "{licenses,[\"MIT\"]}")
  assert string.contains(resource, "pooka@app@@runtime")
  assert !string.contains(resource, "pooka_runtime_ffi")
  assert string.contains(resource, "{applications,[kernel,stdlib]}")
  assert simplifile.is_directory(report.directory <> "/pooka_runtime")
    == Ok(False)
}
