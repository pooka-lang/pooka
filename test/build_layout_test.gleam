//// Each package keeps its own shelf.
////
//// Exercise the development and production directory layouts, per-module
//// artifacts and package-local cleanup. Failed builds must preserve earlier
//// output; successful migrations may remove only artifacts the compiler owns.
//// Generated Erlang source must not return through a cached build.
////
//// ```text
//// build/dev/erlang/<package>/
//// build/prod/erlang/<package>/
//// ```

import birdie
import builder/build
import builder/layout
import cli/command
import gleam/list
import gleam/string
import simplifile
import support

fn project(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 42 } }",
  )
}

// The layout is part of the toolchain contract. Assert concrete package paths
// rather than merely checking that some BEAM file was produced.
pub fn development_package_uses_gleam_style_directories_test() {
  use directory <- support.with_directory("build_layout_dev")
  project(directory)
  let assert Ok(report) = build.build(directory)
  assert report.layout.package == directory <> "/build/dev/erlang/app"
  assert report.directory == report.layout.package <> "/ebin"
  assert simplifile.is_directory(report.layout.include) == Ok(True)
  assert simplifile.is_file(layout.beam(report.layout, "pooka@app@main"))
    == Ok(True)
  let assert Ok(files) = simplifile.get_files(report.layout.package)
  assert !list.any(files, string.ends_with(_, ".erl"))
  assert simplifile.is_file(layout.abstract_forms(
      report.layout,
      "pooka@app@main",
    ))
    == Ok(True)
  assert simplifile.is_directory(directory <> "/build/erlang") == Ok(False)
  let assert Ok(entries) = simplifile.read_directory(report.directory)
  assert list.all(entries, fn(entry) {
    string.ends_with(entry, ".beam") || string.ends_with(entry, ".app")
  })

  assert support.execute(report.directory, "pooka@app@main", []) == Ok("42\n")
}

pub fn no_op_build_run_and_test_share_the_development_cache_test() {
  use directory <- support.with_directory("build_layout_cache")
  project(directory)
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\nimport main\ntest \"value\" { assert main.main() == 42 }",
  )
  let assert Ok(first) = build.build(directory)
  assert list.length(first.compiled) == 2
  assert list.length(first.tests) == 1
  let assert Ok(second) = build.build_tests(directory)
  assert second.compiled == []
  assert second.reused
  assert second.layout == first.layout
  let assert Ok(third) = build.build(directory)
  assert third.compiled == []
  assert third.modules == first.modules
}

pub fn cache_rebuilds_only_changed_module_forms_test() {
  use directory <- support.with_directory("build_layout_changed")
  project(directory)
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nvalue() { 1 }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helper\nmain() { echo { helper.value() } }",
  )
  let assert Ok(_) = build.build(directory)
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nvalue() { 2 }",
  )
  let assert Ok(second) = build.build(directory)
  assert second.compiled == ["pooka@app@helper"]
  assert support.execute(second.directory, "pooka@app@main", []) == Ok("2\n")

  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nvalue(required: Int) { required }",
  )
  let assert Error(_) = build.build(directory)
}

pub fn missing_or_corrupt_beam_and_forms_recompile_test() {
  use directory <- support.with_directory("build_layout_corruption")
  project(directory)
  let assert Ok(first) = build.build(directory)
  let target = layout.beam(first.layout, "pooka@app@main")
  let assert Ok(Nil) = simplifile.delete_file(target)
  let assert Ok(second) = build.build(directory)
  assert second.compiled == ["pooka@app@main"]
  support.write(target, "not a BEAM")
  let assert Ok(third) = build.build(directory)
  assert third.compiled == ["pooka@app@main"]
  support.write(
    layout.abstract_forms(first.layout, "pooka@app@main"),
    "invalid cache",
  )
  let assert Ok(fourth) = build.build(directory)
  assert fourth.compiled == ["pooka@app@main"]
  support.write(first.layout.fingerprint, "another toolchain")
  let assert Ok(fifth) = build.build(directory)
  assert fifth.compiled == ["pooka@app@main"]
}

pub fn obsolete_modules_are_removed_without_touching_other_packages_test() {
  use directory <- support.with_directory("build_layout_prune")
  project(directory)
  support.write(directory <> "/src/old.pooka", "module old\nvalue() { 1 }")
  let assert Ok(first) = build.build(directory)
  support.write(first.layout.ebin <> "/keep.txt", "unrelated")
  support.write(
    directory <> "/build/dev/erlang/dependency/ebin/other.beam",
    "dependency",
  )
  let assert Ok(Nil) = simplifile.delete_file(directory <> "/src/old.pooka")
  let assert Ok(second) = build.build(directory)
  assert second.compiled == []
  assert simplifile.is_file(layout.beam(second.layout, "pooka@app@old"))
    == Ok(False)
  assert simplifile.is_file(second.layout.artifacts <> "/pooka@app@old.erl")
    == Ok(False)
  assert simplifile.is_file(layout.abstract_forms(
      second.layout,
      "pooka@app@old",
    ))
    == Ok(False)
  assert simplifile.read(second.layout.ebin <> "/keep.txt") == Ok("unrelated")
  assert simplifile.read(
      directory <> "/build/dev/erlang/dependency/ebin/other.beam",
    )
    == Ok("dependency")
  let assert Ok(resource) = simplifile.read(second.layout.application)
  assert !string.contains(resource, "pooka@app@old")
}

pub fn production_output_is_separate_and_ignores_test_clients_test() {
  use directory <- support.with_directory("build_layout_production")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 42 } }",
  )
  support.write(
    directory <> "/test/invalid.spec.pooka",
    "this is not valid Pooka",
  )
  let assert Ok(production) = build.build_production(directory)
  assert production.layout.package == directory <> "/build/prod/erlang/app"
  assert production.tests == []
  assert production.modules == ["pooka@app@main"]
  assert support.execute(production.directory, "pooka@app@main", [])
    == Ok("42\n")
  let assert Error(_) = build.build(directory)
  assert simplifile.is_file(layout.beam(production.layout, "pooka@app@main"))
    == Ok(True)
}

pub fn development_and_production_caches_do_not_overwrite_each_other_test() {
  use directory <- support.with_directory("build_layout_modes")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 42 } }",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\ntest \"separate spec\" { assert True }",
  )
  let assert Ok(dev) = build.build(directory)
  let assert Ok(prod) = build.build_production(directory)
  assert list.length(dev.tests) == 1
  assert prod.tests == []
  let assert Ok(dev_again) = build.build_tests(directory)
  let assert Ok(prod_again) = build.build_production(directory)
  assert dev_again.compiled == []
  assert prod_again.compiled == []
  assert dev_again.reused
  assert prod_again.reused
  assert dev.directory != prod.directory
}

// A failed attempt has no authority to sweep the previous output. Cleanup and
// migration must wait until a replacement build succeeds.
pub fn failed_build_preserves_package_and_legacy_artifacts_test() {
  use directory <- support.with_directory("build_layout_failure")
  project(directory)
  let assert Ok(first) = build.build(directory)
  let assert Ok(before) = simplifile.read(first.layout.application)
  support.write(directory <> "/build/erlang/pooka@app@main.erl", "legacy")
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 1 + True } }",
  )
  let assert Error(_) = build.build(directory)
  assert simplifile.read(first.layout.application) == Ok(before)
  assert simplifile.read(directory <> "/build/erlang/pooka@app@main.erl")
    == Ok("legacy")
}

pub fn successful_build_migrates_only_known_legacy_files_test() {
  use directory <- support.with_directory("build_layout_legacy")
  project(directory)
  support.write(directory <> "/build/erlang/pooka@app@main.erl", "old Erlang")
  support.write(directory <> "/build/erlang/pooka@app@main.beam", "old BEAM")
  support.write(
    directory <> "/build/erlang/pooka_runtime_ffi.beam",
    "old runtime",
  )
  let assert Ok(_) = build.build(directory)
  assert simplifile.is_directory(directory <> "/build/erlang") == Ok(False)
  support.write(directory <> "/build/erlang/pooka@app@old.erl", "old generated")
  support.write(directory <> "/build/erlang/keep.txt", "unrelated")
  support.write(
    directory <> "/build/erlang/pooka_runtime_ffi.beam",
    "old runtime",
  )
  let assert Ok(_) = build.build(directory)
  assert simplifile.read(directory <> "/build/erlang/keep.txt")
    == Ok("unrelated")
  assert simplifile.is_file(directory <> "/build/erlang/pooka@app@old.erl")
    == Ok(False)
}

pub fn clean_removes_both_modes_and_their_artifacts_test() {
  use directory <- support.with_directory("build_layout_clean")
  project(directory)
  let assert Ok(_) = build.build(directory)
  let assert Ok(_) = build.build_production(directory)
  let result = support.cli_main(["clean"], command.plain(directory <> "/src"))
  assert result.status == 0
  assert simplifile.is_directory(directory <> "/build") == Ok(False)
}

pub fn otp_application_resource_snapshot_test() {
  use directory <- support.with_directory("build_layout_app")
  project(directory)
  let assert Ok(report) = build.build(directory)
  let assert Ok(resource) = simplifile.read(report.layout.application)
  birdie.snap(resource, title: "build OTP application resource")
}

pub fn root_package_runtime_has_priority_over_other_package_paths_test() {
  use directory <- support.with_directory("build_layout_runtime_priority")
  project(directory)
  let assert Ok(_) = build.build(directory)
  support.write(
    directory <> "/build/dev/erlang/aaa/ebin/pooka_runtime_ffi.beam",
    "invalid sibling",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 5.5 % 2.0 } }",
  )
  let assert Ok(report) = build.build(directory)
  assert support.execute(report.directory, "pooka@app@main", []) == Ok("1.5\n")
}

pub fn build_and_runner_support_unicode_project_paths_test() {
  use directory <- support.with_directory("build_layout_Δοκιμή")
  project(directory)
  let assert Ok(report) = build.build(directory)
  assert support.execute(report.directory, "pooka@app@main", ["Δοκιμή"])
    == Ok("42\n")
}

pub fn application_version_changes_do_not_recompile_unchanged_forms_test() {
  use directory <- support.with_directory("build_layout_version")
  project(directory)
  let assert Ok(_) = build.build(directory)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.2.0\"\n",
  )
  let assert Ok(report) = build.build(directory)
  assert report.compiled == []
  let assert Ok(resource) = simplifile.read(report.layout.application)
  assert string.contains(resource, "0.2.0")
  assert support.execute(report.directory, "pooka@app@main", []) == Ok("42\n")
}

// A legacy path can point outside the managed tree. Removing its entry must
// never follow the link and erase its target.
pub fn legacy_directory_symlink_targets_are_preserved_test() {
  use directory <- support.with_directory("build_layout_legacy_symlink")
  project(directory)
  support.write(directory <> "/outside/pooka@app@main.erl", "preserve target")
  support.write(directory <> "/build/keep.txt", "unrelated")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      directory <> "/outside",
      directory <> "/build/erlang",
    )
  let assert Ok(_) = build.build(directory)
  assert simplifile.is_symlink(directory <> "/build/erlang") == Ok(True)
  assert simplifile.read(directory <> "/outside/pooka@app@main.erl")
    == Ok("preserve target")
}

// A cache hit is still responsible for retiring old generated .erl artifacts.
// Reuse must not bring an obsolete build format back into the directory.
pub fn cached_builds_remove_previous_erlang_source_artifacts_test() {
  use directory <- support.with_directory("build_no_erlang_source")
  project(directory)
  let assert Ok(first) = build.build(directory)
  support.write(
    first.layout.artifacts <> "/pooka@app@main.erl",
    "old live module source",
  )
  support.write(
    first.layout.artifacts <> "/pooka@app@removed.erl",
    "old removed module source",
  )
  support.write(
    first.layout.ebin <> "/pooka@app@main.erl",
    "old misplaced source",
  )
  support.write(first.layout.artifacts <> "/keep.txt", "unrelated")
  let assert Ok(second) = build.build(directory)
  assert second.compiled == []
  let assert Ok(files) = simplifile.get_files(second.layout.package)
  assert !list.any(files, string.ends_with(_, ".erl"))
  assert simplifile.is_file(layout.abstract_forms(
      second.layout,
      "pooka@app@main",
    ))
    == Ok(True)
  assert simplifile.read(second.layout.artifacts <> "/keep.txt")
    == Ok("unrelated")
  assert support.execute(second.directory, "pooka@app@main", []) == Ok("42\n")
}

pub fn production_builds_do_not_emit_erlang_source_test() {
  use directory <- support.with_directory("build_prod_no_erlang_source")
  project(directory)
  let assert Ok(report) = build.build_production(directory)
  let assert Ok(files) = simplifile.get_files(report.layout.package)
  assert !list.any(files, string.ends_with(_, ".erl"))
  assert support.execute(report.directory, "pooka@app@main", []) == Ok("42\n")
}

// A library has no main to start. Its production build is still a complete OTP
// application, and development test clients must stay on their own shelf.
pub fn production_library_cli_excludes_tests_and_dev_dependencies_test() {
  use directory <- support.with_directory("production_library_cli")
  support.write(
    directory <> "/pooka.toml",
    "name = \"library\"\nversion = \"1.0.0\"\ndescription = \"A useful library\"\n[dev-dependencies]\nmissing = { path = \"does-not-exist\" }\n",
  )
  support.write(
    directory <> "/src/value.pooka",
    "module value\nanswer() { 42 }",
  )
  support.write(directory <> "/test/broken.spec.pooka", "invalid test source")
  let outcome =
    support.cli_main(["build", "--target", "prod"], command.plain(directory))
  assert outcome.status == 0
  let paths = layout.erlang(directory, "library", layout.Production)
  let assert Ok(files) = simplifile.read_directory(paths.ebin)
  assert !list.any(files, string.contains(_, "$test"))
  let assert Ok(resource) = simplifile.read(paths.application)
  assert string.contains(resource, "A useful library")
  assert !string.contains(resource, "$test")
  assert !string.contains(resource, "missing")
  let assert Ok(cached) = build.build_production(directory)
  assert cached.reused
  assert cached.tests == []
  assert cached.entry == Error(Nil)
  assert cached.modules == ["pooka@library@value"]
}

pub fn application_metadata_updates_without_recompiling_modules_test() {
  use directory <- support.with_directory("application_metadata")
  project(directory)
  let assert Ok(first) = build.build(directory)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\ndescription = 'A \"quoted\" library'\nlicences = [\"Apache-2.0\", \"MIT\"]\n",
  )
  let assert Ok(second) = build.build(directory)
  assert second.compiled == []
  let assert Ok(before) = simplifile.read(first.layout.application)
  assert string.contains(before, "A \\\"quoted\\\" library")
  assert string.contains(before, "licenses")
  assert string.contains(before, "Apache-2.0")
  assert string.contains(before, "MIT")
}

// Independently built packages meet later in releases. Neither may claim the
// package runtime module, and removing that artifact must invalidate cache.
pub fn independent_packages_own_distinct_runtime_modules_test() {
  use directory <- support.with_directory("package_runtime_apps")
  let first = directory <> "/first"
  let second = directory <> "/second"
  support.write(
    first <> "/pooka.toml",
    "name = \"first\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    first <> "/src/main.pooka",
    "module main\nexternal Other from erlang \"pooka@second@main\" { value() -> Int }\nmain() { echo { Other.value() + 1 } }",
  )
  support.write(
    second <> "/pooka.toml",
    "name = \"second\"\nversion = \"1.0.0\"\n",
  )
  support.write(second <> "/src/main.pooka", "module main\nvalue() { 41 }")
  let assert Ok(a) = build.build_production(first)
  let assert Ok(b) = build.build_production(second)
  list.each([a, b], fn(report) {
    let name = "pooka@" <> report.checked.project.name <> "@@runtime"
    assert simplifile.is_file(report.directory <> "/" <> name <> ".beam")
      == Ok(True)
    let assert Ok(resource) = simplifile.read(report.layout.application)
    assert string.contains(resource, name)
    assert !string.contains(resource, "pooka_runtime_ffi")
    assert string.contains(resource, "{applications,[kernel,stdlib]}")
    assert simplifile.is_directory(report.layout.target <> "/pooka_runtime")
      == Ok(False)
  })
  let assert Ok(Nil) =
    simplifile.copy_directory(b.layout.package, a.layout.target <> "/second")
  assert support.execute(a.directory, "pooka@first@main", []) == Ok("42\n")
  let runtime = a.directory <> "/pooka@first@@runtime.beam"
  let assert Ok(Nil) = simplifile.delete_file(runtime)
  support.write(a.directory <> "/pooka_runtime_ffi.beam", "legacy helper")
  let assert Ok(repaired) = build.build_production(first)
  assert !repaired.reused
  assert simplifile.is_file(runtime) == Ok(True)
  assert simplifile.is_file(a.directory <> "/pooka_runtime_ffi.beam")
    == Ok(False)
}

pub fn ordinary_runtime_source_module_does_not_collide_with_helper_test() {
  use directory <- support.with_directory("runtime_source_module")
  project(directory)
  support.write(
    directory <> "/src/runtime.pooka",
    "module runtime\nanswer() { 42 }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport runtime\nmain() { echo runtime.answer() }",
  )
  let assert Ok(report) = build.build_production(directory)
  assert simplifile.is_file(report.directory <> "/pooka@app@runtime.beam")
    == Ok(True)
  assert simplifile.is_file(report.directory <> "/pooka@app@@runtime.beam")
    == Ok(True)
  assert support.execute(report.directory, "pooka@app@main", []) == Ok("42\n")
}

pub fn runtime_specialization_preserves_user_function_names_and_strings_test() {
  use directory <- support.with_directory("runtime_user_spelling")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\npooka_runtime_ffi() { 42 }\nmain() { echo #(pooka_runtime_ffi(), \"pooka_runtime_ffi\") }",
  )
  let assert Ok(report) = build.build_production(directory)
  assert support.execute(report.directory, "pooka@app@main", [])
    == Ok("#(42, \"pooka_runtime_ffi\")\n")
}
