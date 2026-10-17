//// Yesterday's work is useful only while its assumptions still hold.
////
//// Compare reused builds with changed sources, interfaces, foreign inputs and
//// compiler identities. Missing or corrupt cache data must trigger a safe
//// rebuild. A failed attempt must not replace the stamp or artifacts of a
//// successful earlier build.
////
//// ```text
//// unchanged inputs -> reuse
//// changed assumptions -> invalidate affected work
//// failed rebuild -> keep the last successful stamp
//// ```

import builder/build
import builder/layout
import cli/command
import compiler/codegen/beam
import filepath
import gleam/list
import gleam/string
import simplifile
import support

fn setup(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo 42 }\n",
  )
}

/// Read the actual per-module BEAM bytes from a build report. Comparing these
/// snapshots checks artifact preservation rather than relying only on a reuse
/// flag.
fn binaries(report: build.Report) {
  list.map(report.modules, fn(name) {
    let assert Ok(bytes) =
      simplifile.read_bits(layout.beam(report.layout, name))
    #(name, bytes)
  })
}

pub fn unchanged_build_reuses_the_whole_pipeline_and_preserves_artifacts_test() {
  use directory <- support.with_directory("incremental_noop")
  setup(directory)
  let assert Ok(first) = build.build(directory)
  assert !first.reused
  let original = binaries(first)
  let assert Ok(second) = build.build_tests(directory)
  assert second.reused
  assert second.compiled == []
  assert second.compiled_foreign == []
  assert second.checked == first.checked
  assert second.diagnostics == first.diagnostics
  assert binaries(second) == original
  assert support.execute(second.directory, "pooka@app@main", []) == Ok("42\n")
}

pub fn changed_interfaces_are_checked_and_clean_builds_agree_test() {
  use directory <- support.with_directory("incremental_interfaces")
  setup(directory)
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nanswer() { 41 }\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helper\nmain() { echo helper.answer() }\n",
  )
  let assert Ok(_) = build.build(directory)
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nanswer() { 42 }\n",
  )
  let assert Ok(changed) = build.build(directory)
  assert !changed.reused
  assert changed.compiled == ["pooka@app@helper"]
  let expected = binaries(changed)
  assert support.execute(changed.directory, "pooka@app@main", []) == Ok("42\n")
  let assert Ok(Nil) = simplifile.delete(directory <> "/build")
  let assert Ok(clean) = build.build(directory)
  assert binaries(clean) == expected
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nanswer(value: Int) { value }\n",
  )
  let assert Error(incremental_error) = build.build(directory)
  let assert Ok(Nil) = simplifile.delete(directory <> "/build")
  let assert Error(clean_error) = build.build(directory)
  assert incremental_error.diagnostics == clean_error.diagnostics
}

pub fn foreign_source_headers_and_valid_but_replaced_beams_are_tracked_test() {
  use directory <- support.with_directory("incremental_foreign")
  setup(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Math from erlang \"math_helper\" { answer() -> Int }\nmain() { echo Math.answer() }\n",
  )
  support.write(
    directory <> "/ffi/math_helper.erl",
    "-module(math_helper).\n-export([answer/0]).\n-include(\"value.hrl\").\nanswer() -> ?VALUE.\n",
  )
  support.write(directory <> "/ffi/value.hrl", "-define(VALUE, 41).\n")
  let assert Ok(first) = build.build(directory)
  assert first.compiled_foreign == ["math_helper"]
  let assert Ok(second) = build.build(directory)
  assert second.reused
  support.write(
    directory <> "/src/other.pooka",
    "module other\nanswer() { 1 }\n",
  )
  let assert Ok(added) = build.build(directory)
  assert added.compiled_foreign == []
  support.write(directory <> "/ffi/value.hrl", "-define(VALUE, 42).\n")
  let assert Ok(updated) = build.build(directory)
  assert updated.compiled_foreign == ["math_helper"]
  assert updated.compiled == []
  assert support.execute(updated.directory, "pooka@app@main", []) == Ok("42\n")

  let assert Ok(old_foreign) =
    beam.compile_foreign_erlang(directory <> "/ffi/math_helper.erl")
  support.write(directory <> "/ffi/value.hrl", "-define(VALUE, 99).\n")
  let assert Ok(wrong_foreign) =
    beam.compile_foreign_erlang(directory <> "/ffi/math_helper.erl")
  support.write(directory <> "/ffi/value.hrl", "-define(VALUE, 42).\n")
  let assert Ok(Nil) =
    simplifile.write_bits(
      layout.beam(updated.layout, wrong_foreign.0),
      wrong_foreign.1,
    )
  let assert Ok(repaired) = build.build(directory)
  assert !repaired.reused
  assert repaired.compiled_foreign == []
  assert simplifile.read_bits(layout.beam(repaired.layout, old_foreign.0))
    == Ok(old_foreign.1)
  assert support.execute(repaired.directory, "pooka@app@main", []) == Ok("42\n")
}

// Cache data is an optimization rather than authority. Missing artifacts or
// an unreadable record must fall back to rebuilding from source.
pub fn cache_corruption_and_missing_outputs_fall_back_to_a_safe_build_test() {
  use directory <- support.with_directory("incremental_corruption")
  setup(directory)
  let assert Ok(first) = build.build(directory)
  let cache = filepath.join(first.layout.artifacts, "build.cache")
  support.write(cache, "not a build stamp")
  let assert Ok(second) = build.build(directory)
  assert !second.reused
  assert second.compiled == []
  let assert Ok(third) = build.build(directory)
  assert third.reused
  support.write(third.layout.application, "invalid OTP application")
  let assert Ok(repaired) = build.build(directory)
  assert !repaired.reused
  assert support.execute(repaired.directory, "pooka@app@main", []) == Ok("42\n")
  let assert Ok(Nil) =
    simplifile.delete_file(layout.beam(repaired.layout, "pooka@app@main"))
  let assert Ok(missing) = build.build(directory)
  assert missing.compiled == ["pooka@app@main"]
}

// The last successful stamp belongs to the last successful artifacts. A
// failed build cannot advance one side of that pair.
pub fn failures_do_not_replace_a_successful_build_stamp_test() {
  use directory <- support.with_directory("incremental_failure")
  setup(directory)
  let assert Ok(first) = build.build(directory)
  let cache = filepath.join(first.layout.artifacts, "build.cache")
  let assert Ok(before) = simplifile.read_bits(cache)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo missing() }\n",
  )
  let assert Error(_) = build.build(directory)
  assert simplifile.read_bits(cache) == Ok(before)
  setup(directory)
  let assert Ok(restored) = build.build(directory)
  assert restored.reused
}

pub fn dependency_changes_invalidate_the_graph_and_removed_modules_are_pruned_test() {
  use directory <- support.with_directory("incremental_dependency")
  setup(directory <> "/app")
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n[dependencies]\nlibrary = { path = \"../library\" }\n",
  )
  support.write(
    directory <> "/library/pooka.toml",
    "name = \"library\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/library/src/library.pooka",
    "module library\nanswer() { 41 }\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nimport library\nmain() { echo library.answer() }\n",
  )
  let assert Ok(first) = build.build(directory <> "/app")
  let assert Ok(second) = build.build(directory <> "/app")
  assert second.reused
  support.write(
    directory <> "/library/src/library.pooka",
    "module library\nanswer() { 42 }\n",
  )
  let assert Ok(changed) = build.build(directory <> "/app")
  assert changed.compiled == ["pooka@library@library"]
  assert support.execute(changed.directory, "pooka@app@main", []) == Ok("42\n")
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.2.0\"\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nmain() { echo 43 }\n",
  )
  let assert Ok(removed) = build.build(directory <> "/app")
  assert !removed.reused
  assert simplifile.is_directory(
      filepath.directory_name(first.layout.package) <> "/library",
    )
    == Ok(False)
  let assert Ok(resource) = simplifile.read(removed.layout.application)
  assert string.contains(resource, "0.2.0")
  assert support.execute(removed.directory, "pooka@app@main", []) == Ok("43\n")
}

pub fn native_gleam_caches_restore_interfaces_for_changed_dependants_test() {
  use directory <- support.with_directory("incremental_native_interfaces")
  setup(directory <> "/app")
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n[dependencies]\nmiddle = { path = \"../middle\" }\n",
  )
  support.write(
    directory <> "/base/gleam.toml",
    "name = \"base\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/base/src/base.gleam", "pub fn answer() { 41 }\n")
  support.write(
    directory <> "/middle/gleam.toml",
    "name = \"middle\"\nversion = \"0.1.0\"\n[dependencies]\nbase = { path = \"../base\" }\n",
  )
  support.write(
    directory <> "/middle/src/middle.gleam",
    "import base\npub fn answer() { base.answer() }\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nexternal Middle from erlang \"middle\" { answer() -> Int }\nmain() { echo Middle.answer() }\n",
  )
  let assert Ok(first) = build.build(directory <> "/app")
  assert list.contains(first.compiled_foreign, "base")
  assert list.contains(first.compiled_foreign, "middle")
  let assert Ok(warm) = build.build(directory <> "/app")
  assert warm.reused
  support.write(
    directory <> "/app/src/extra.pooka",
    "module extra\nanswer() { 1 }\n",
  )
  let assert Ok(root_change) = build.build(directory <> "/app")
  assert root_change.compiled_foreign == []
  support.write(
    directory <> "/middle/src/middle.gleam",
    "import base\npub fn answer() { base.answer() + 1 }\n",
  )
  let assert Ok(middle_change) = build.build(directory <> "/app")
  assert !list.contains(middle_change.compiled_foreign, "base")
  assert list.contains(middle_change.compiled_foreign, "middle")
  assert support.execute(middle_change.directory, "pooka@app@main", [])
    == Ok("42\n")
  support.write(directory <> "/base/src/base.gleam", "pub fn answer() { 42 }\n")
  let assert Ok(base_change) = build.build(directory <> "/app")
  assert list.contains(base_change.compiled_foreign, "base")
  assert list.contains(base_change.compiled_foreign, "middle")
  assert support.execute(base_change.directory, "pooka@app@main", [])
    == Ok("43\n")
  let assert Ok(entries) = simplifile.read_directory(base_change.layout.target)
  assert !list.any(entries, string.starts_with(_, ".pooka-native"))
}

// Being a readable BEAM file does not prove it is the compiler's expected
// output. Content changes must invalidate the artifact even when the format
// is valid.
pub fn a_valid_but_replaced_pooka_beam_is_recompiled_test() {
  use directory <- support.with_directory("incremental_replaced_module")
  setup(directory)
  let assert Ok(original) = build.build(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo 99 }\n",
  )
  let assert Ok(changed) = build.build(directory)
  let assert Ok(wrong) =
    simplifile.read_bits(layout.beam(changed.layout, "pooka@app@main"))
  setup(directory)
  let assert Ok(restored) = build.build(directory)
  assert support.execute(restored.directory, "pooka@app@main", []) == Ok("42\n")
  let assert Ok(Nil) =
    simplifile.write_bits(layout.beam(original.layout, "pooka@app@main"), wrong)
  let assert Ok(repaired) = build.build(directory)
  assert repaired.compiled == ["pooka@app@main"]
  assert support.execute(repaired.directory, "pooka@app@main", []) == Ok("42\n")
}

pub fn production_stamps_ignore_development_tests_but_keep_test_discovery_fresh_test() {
  use directory <- support.with_directory("incremental_test_discovery")
  setup(directory)
  let assert Ok(_) = build.build_production(directory)
  support.write(
    directory <> "/test/example.spec.pooka",
    "module example_test\ntest \"one\" { assert True }\n",
  )
  let assert Ok(production) = build.build_production(directory)
  assert production.reused
  let assert Ok(dev) = build.build_tests(directory)
  assert list.length(dev.tests) == 1
  support.write(
    directory <> "/test/example.spec.pooka",
    "module example_test\ntest \"one\" { assert True }\ntest \"two\" { assert True }\n",
  )
  let assert Ok(added) = build.build_tests(directory)
  assert !added.reused
  assert list.length(added.tests) == 2
  let assert Ok(Nil) =
    simplifile.delete_file(directory <> "/test/example.spec.pooka")
  let assert Ok(removed) = build.build_tests(directory)
  assert removed.tests == []
  assert !list.any(removed.modules, string.contains(_, "$test"))
  let assert Ok(prod_again) = build.build_production(directory)
  assert prod_again.reused
}

@external(erlang, "shipment_test_ffi", "run_cli")
fn run_cli(arguments: List(String), directory: String) -> #(Int, String)

// Run another VM so an in-memory cache cannot explain the reuse. The
// persisted stamp must contain enough information to make the same decision.
pub fn successful_stamps_are_reused_across_fresh_cli_processes_test() {
  use directory <- support.with_directory("incremental_fresh_vm")
  setup(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\n_unused() { Nil }\nmain() { echo 42 }\n",
  )
  let first = run_cli(["build"], directory)
  assert first.0 == 0
  assert string.contains(first.1, "warning: unused private declaration")
  let cache = directory <> "/build/dev/erlang/app/_pooka_artefacts/build.cache"
  let assert Ok(before) = simplifile.read_bits(cache)
  let second = run_cli(["build"], directory)
  assert second.0 == 0
  assert string.contains(second.1, "warning: unused private declaration")

  assert simplifile.read_bits(cache) == Ok(before)
}

import birdie
import gleam/bool
import gleam/int

fn summary(label: String, report: build.Report) -> String {
  label
  <> ": reused="
  <> bool.to_string(report.reused)
  <> "; rebuilt=["
  <> string.join(report.compiled, ", ")
  <> "]; foreign=["
  <> string.join(report.compiled_foreign, ", ")
  <> "]; tests="
  <> int.to_string(list.length(report.tests))
  <> "\n"
}

pub fn incremental_rebuild_decisions_snapshot_test() {
  use directory <- support.with_directory("incremental_decisions")
  setup(directory)
  let assert Ok(cold) = build.build(directory)
  let assert Ok(warm) = build.build(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo 43 }\n",
  )
  let assert Ok(changed) = build.build(directory)
  let assert Ok(reused) = build.build(directory)
  birdie.snap(
    summary("cold", cold)
      <> summary("unchanged", warm)
      <> summary("body changed", changed)
      <> summary("unchanged again", reused),
    "incremental rebuild decisions",
  )
}

@external(erlang, "incremental_test_ffi", "with_environment")
fn with_environment(name: String, value: String, run: fn() -> a) -> a

@external(erlang, "incremental_test_ffi", "executable")
fn executable(path: String) -> Nil

pub fn compiler_options_invalidate_whole_build_and_equal_forms_test() {
  use directory <- support.with_directory("incremental_compiler_options")
  setup(directory)
  let assert Ok(_) = build.build(directory)
  with_environment("ERL_COMPILER_OPTIONS", "[debug_info]", fn() {
    let assert Ok(changed) = build.build(directory)
    assert !changed.reused
    assert changed.compiled == ["pooka@app@main"]
    let assert Ok(warm) = build.build(directory)
    assert warm.reused
  })
  let assert Ok(restored) = build.build(directory)
  assert !restored.reused
  assert restored.compiled == ["pooka@app@main"]
}

pub fn compiler_executable_content_invalidates_stamps_test() {
  use directory <- support.with_directory("incremental_executable")
  setup(directory)

  let program = directory <> "/bin/gleam"
  support.write(program, "#!/bin/sh\nexit 0\n")
  executable(program)
  use <- with_environment(
    "PATH",
    directory <> "/bin:/usr/bin:/bin:/opt/homebrew/bin",
  )
  let assert Ok(_) = build.build(directory)
  let assert Ok(warm) = build.build(directory)
  assert warm.reused
  support.write(program, "#!/bin/sh\nexit 1\n")
  let assert Ok(changed) = build.build(directory)
  assert !changed.reused
  assert changed.compiled == []
  let assert Ok(warm_again) = build.build(directory)
  assert warm_again.reused
}

pub fn cached_build_logs_do_not_claim_to_recompile_modules_test() {
  use directory <- support.with_directory("incremental_logging")
  setup(directory)
  let env = command.plain(directory)
  let cold = support.cli_main(["build"], env)
  assert cold.status == 0
  assert string.contains(cold.stderr, "Compiled 1 module in ")
  let warm = support.cli_main(["build"], env)
  assert warm.status == 0
  assert !string.contains(warm.stderr, "Compiling")
  assert string.contains(warm.stderr, "Compiled in ")
  assert !string.contains(warm.stderr, "1 module")
}

@external(erlang, "pooka_incremental_ffi", "enclosing_archive")
fn enclosing_archive(path: String) -> Result(String, Nil)

// An installed compiler is a flat escript archive, so its modules report paths
// such as `.../bin/pooka/pooka_incremental_ffi.beam`. The escript itself must
// be found and fingerprinted; otherwise a rebuilt compiler with an unchanged
// version number would leave build stamps valid.
pub fn installed_compiler_escript_is_part_of_the_build_identity_test() {
  use directory <- support.with_directory("incremental_escript_identity")
  support.write(directory <> "/bin/pooka", "#!/usr/bin/env escript\n")
  assert enclosing_archive(directory <> "/bin/pooka")
    == Ok(directory <> "/bin/pooka")
  assert enclosing_archive(directory <> "/bin/pooka/nested/module")
    == Ok(directory <> "/bin/pooka")
  assert enclosing_archive(directory <> "/bin") == Error(Nil)
}
