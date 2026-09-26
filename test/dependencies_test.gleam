//// A package graph is more than a pile of source directories.
////
//// Build temporary local dependency graphs and exercise their public
//// interfaces, source ownership and production scope. Canonical paths catch
//// cycles and aliases; deterministic lockfiles and previous artifacts survive
//// failed resolution. Dependencies must not lend their own development
//// requirements to clients.
////
//// ```text
//// root -> declared dependencies -> their transitive dependencies
////        only declared imports are visible to the root
//// ```

import birdie
import builder/build
import builder/check
import builder/escript
import builder/fix
import cli/command
import gleam/list
import gleam/string
import project/package
import project/project
import simplifile
import support

@external(erlang, "shipment_test_ffi", "run_escript")
fn execute(
  script: String,
  args: List(String),
  directory: String,
) -> #(Int, String)

fn package_at(
  root: String,
  name: String,
  requirements: String,
  source: String,
) {
  support.write(
    root <> "/pooka.toml",
    "name = \"" <> name <> "\"\nversion = \"0.1.0\"\n" <> requirements,
  )
  support.write(
    root <> "/src/" <> name <> ".pooka",
    "module " <> name <> "\n" <> source,
  )
}

fn application(root: String, requirements: String, source: String) {
  support.write(
    root <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n" <> requirements,
  )
  support.write(root <> "/src/main.pooka", "module main\n" <> source)
}

fn local(name: String, path: String) -> String {
  name <> " = { path = \"" <> path <> "\" }\n"
}

fn resolve(root: String) {
  let assert Ok(config) = project.load(root)
  package.resolve(config, True)
}

pub fn local_packages_compile_generic_classes_and_cross_package_interfaces_test() {
  use directory <- support.with_directory("deps_nominal")
  package_at(
    directory <> "/library",
    "library",
    "",
    "interface Value(a) { get() -> a }\nclass Box(a) with Value(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\nread(value: Value(Int)) -> Int { value.get() }",
  )
  support.write(
    directory <> "/library/test/excluded.spec.pooka",
    "module excluded_test\ntest \"dependency tests are excluded\" { unknown() }",
  )
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("library", "../library"),
    "import library.{Box, Value}\nclass Own with Value(Int) { get() { 42 } }\nmain() { echo #(library.read(Box(41)), library.read(Own()), Box(True).get()) }",
  )
  let result = support.cli_main(["run"], command.plain(directory <> "/app"))
  assert result.status == 0
  assert support.diagnostics(result.stderr) == ""
  assert result.stdout == "#(41, 42, True)\n"
  assert simplifile.is_file(
      directory
      <> "/app/build/dev/erlang/library/ebin/pooka@library@library.beam",
    )
    == Ok(True)
  assert simplifile.is_directory(directory <> "/library/build") == Ok(False)
}

pub fn transitive_diamonds_are_resolved_once_in_dependency_order_test() {
  use directory <- support.with_directory("deps_diamond")
  package_at(directory <> "/leaf", "leaf", "", "answer() { 40 }")
  package_at(
    directory <> "/left",
    "left",
    "[dependencies]\n" <> local("leaf", "../leaf"),
    "import leaf\nanswer() { leaf.answer() + 1 }",
  )
  package_at(
    directory <> "/right",
    "right",
    "[dependencies]\n" <> local("leaf", "../leaf/../leaf"),
    "import leaf\nanswer() { leaf.answer() + 2 }",
  )
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("right", "../right") <> local("left", "../left"),
    "import left\nimport right\nmain() { echo #(left.answer(),right.answer()) }",
  )
  let assert Ok(graph) = resolve(directory <> "/app")
  assert list.map(graph.packages, fn(p) { p.name })
    == ["leaf", "left", "right", "app"]
  let result = support.cli_main(["run"], command.plain(directory <> "/app"))
  assert result.status == 0
  assert result.stdout == "#(41, 42)\n"
}

pub fn transitive_dependencies_do_not_become_undeclared_imports_test() {
  use directory <- support.with_directory("deps_visibility")
  package_at(directory <> "/leaf", "leaf", "", "answer() { 42 }")
  package_at(
    directory <> "/middle",
    "middle",
    "[dependencies]\n" <> local("leaf", "../leaf"),
    "answer() { 42 }",
  )
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("middle", "../middle"),
    "import leaf\nmain() { echo leaf.answer() }",
  )
  let result = support.cli_main(["check"], command.plain(directory <> "/app"))
  assert result.status == 1
  assert string.contains(result.stderr, "Could not find module `leaf`")
}

// The root can borrow development packages for its tests. A production export
// must resolve its own smaller graph without making those test-only packages
// necessary.
pub fn root_dev_dependencies_are_available_in_tests_but_not_production_exports_test() {
  use directory <- support.with_directory("deps_dev")
  package_at(directory <> "/helper", "helper", "", "answer() { 42 }")
  application(
    directory <> "/app",
    "[dev-dependencies]\n" <> local("helper", "../helper"),
    "main() { Nil }",
  )
  support.write(
    directory <> "/app/test/main.spec.pooka",
    "module main_test\nimport helper\ntest \"dev helper\" { assert helper.answer() == 42 }",
  )
  let result = support.cli_main(["test"], command.plain(directory <> "/app"))
  assert result.status == 0
  assert string.contains(result.stdout, "1 test, 1 passed")
  let assert Ok(report) = escript.export(directory <> "/app")
  assert report.build.checked.packages == []
  assert execute(report.path, [], directory) == #(0, "")
}

pub fn dependency_dev_requirements_and_tests_are_not_loaded_test() {
  use directory <- support.with_directory("deps_nested_dev")
  package_at(
    directory <> "/library",
    "library",
    "[dev-dependencies]\n" <> local("missing", "../does-not-exist"),
    "answer() { 42 }",
  )
  support.write(
    directory <> "/library/test/broken.spec.pooka",
    "invalid syntax",
  )
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("library", "../library"),
    "import library\nmain() { echo library.answer() }",
  )
  let result = support.cli_main(["run"], command.plain(directory <> "/app"))
  assert result.status == 0
  assert result.stdout == "42\n"
}

pub fn cycles_include_canonical_owner_relative_paths_test() {
  use directory <- support.with_directory("deps_cycle")
  package_at(
    directory <> "/a",
    "a",
    "[dependencies]\n" <> local("b", "../b"),
    "",
  )
  package_at(
    directory <> "/b",
    "b",
    "[dependencies]\n" <> local("a", "../a/./"),
    "",
  )
  let assert Error(error) = resolve(directory <> "/a")
  let report =
    support.cli_main(["deps", "download"], command.plain(directory <> "/a"))
  assert report.status == 1
  assert string.contains(report.stderr, "Dependency cycle:")
  assert simplifile.is_file(directory <> "/a/pooka.lock") == Ok(False)
  let _ = error
}

pub fn symlink_aliases_do_not_bypass_cycle_checks_test() {
  use directory <- support.with_directory("deps_symlink_cycle")
  package_at(
    directory <> "/a",
    "a",
    "[dependencies]\n" <> local("b", "../b"),
    "",
  )
  package_at(
    directory <> "/b",
    "b",
    "[dependencies]\n" <> local("a", "../alias"),
    "",
  )
  let assert Ok(Nil) =
    simplifile.create_symlink(directory <> "/a", directory <> "/alias")
  let assert Error(_) = resolve(directory <> "/a")
}

pub fn name_mismatches_and_conflicting_sources_are_errors_test() {
  use directory <- support.with_directory("deps_conflicts")
  package_at(directory <> "/v1", "shared", "", "answer() { 1 }")
  package_at(directory <> "/v2", "shared", "", "answer() { 2 }")
  package_at(
    directory <> "/left",
    "left",
    "[dependencies]\n" <> local("shared", "../v1"),
    "",
  )
  package_at(
    directory <> "/right",
    "right",
    "[dependencies]\n" <> local("shared", "../v2"),
    "",
  )
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("left", "../left") <> local("right", "../right"),
    "main() { Nil }",
  )
  let conflict =
    support.cli_main(["deps", "download"], command.plain(directory <> "/app"))
  assert conflict.status == 1
  assert string.contains(
    conflict.stderr,
    "Conflicting sources for package `shared`",
  )
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("wrong", "../v1"),
    "main() { Nil }",
  )
  let mismatch =
    support.cli_main(["deps", "download"], command.plain(directory <> "/app"))
  assert mismatch.status == 1
  assert string.contains(mismatch.stderr, "declares package name `shared`")
}

pub fn ambiguous_modules_are_reported_at_real_dependency_paths_test() {
  use directory <- support.with_directory("deps_module_collision")
  package_at(directory <> "/a", "a", "", "")
  package_at(directory <> "/b", "b", "", "")
  support.write(directory <> "/a/src/collision.pooka", "module collision\n")
  support.write(directory <> "/b/src/collision.pooka", "module collision\n")
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("a", "../a") <> local("b", "../b"),
    "main() { Nil }",
  )
  let result = support.cli_main(["check"], command.plain(directory <> "/app"))
  assert result.status == 1
  assert string.contains(
    result.stderr,
    "module is provided by multiple packages",
  )
  assert string.contains(result.stderr, directory <> "/a/src/collision.pooka")
  assert !string.contains(result.stderr, "$package")
}

// A lockfile describes a successfully resolved graph. A failed search must
// not overwrite that record with a partial selection.
pub fn local_lockfiles_are_deterministic_and_preserved_on_resolution_failure_test() {
  use directory <- support.with_directory("deps_lock")
  package_at(directory <> "/library", "library", "", "answer() { 42 }")
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("library", "../library"),
    "main() { Nil }",
  )
  let report =
    support.cli_main(["deps", "download"], command.plain(directory <> "/app"))
  assert report.status == 0
  let assert Ok(before) = simplifile.read(directory <> "/app/pooka.lock")
  assert !string.contains(before, directory)
  let again =
    support.cli_main(["deps", "download"], command.plain(directory <> "/app"))
  assert again == report
  assert simplifile.read(directory <> "/app/pooka.lock") == Ok(before)
  let snapshot = report.stdout <> "\n--- lockfile ---\n" <> before
  birdie.snap(snapshot, title: "dependencies local graph and lockfile")
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("library", "../missing"),
    "main() { Nil }",
  )
  assert support.cli_main(
      ["deps", "download"],
      command.plain(directory <> "/app"),
    ).status
    == 1
  assert simplifile.read(directory <> "/app/pooka.lock") == Ok(before)
}

pub fn malformed_or_future_lockfiles_are_not_overwritten_test() {
  use directory <- support.with_directory("deps_bad_lock")
  application(directory, "", "main() { Nil }")
  support.write(directory <> "/pooka.lock", "version = 999\n")
  assert support.cli_main(["deps", "download"], command.plain(directory)).status
    == 1
  assert simplifile.read(directory <> "/pooka.lock") == Ok("version = 999\n")
}

// Show the dependency's actual source path in a diagnostic, but keep
// automatic root-project fixes from rewriting someone else's package.
pub fn dependency_type_errors_use_real_paths_and_fixes_do_not_edit_dependencies_test() {
  use directory <- support.with_directory("deps_diagnostics")
  package_at(directory <> "/library", "library", "", "answer() -> Int { True }")
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("library", "../library"),
    "main() { Nil }",
  )
  let failed = support.cli_main(["check"], command.plain(directory <> "/app"))
  assert failed.status == 1
  assert string.contains(
    failed.stderr,
    directory <> "/library/src/library.pooka",
  )
  assert !string.contains(failed.stderr, "$package")
  let original = "module library\nimport internal\nanswer() { 42 }\n"
  support.write(directory <> "/library/src/library.pooka", original)
  support.write(directory <> "/library/src/internal.pooka", "module internal\n")
  let assert Ok(report) = check.check_project(directory <> "/app")
  assert fix.plan(report) == Ok([])
  assert simplifile.read(directory <> "/library/src/library.pooka")
    == Ok(original)
}

pub fn removed_dependencies_are_pruned_only_from_the_managed_build_graph_test() {
  use directory <- support.with_directory("deps_remove")
  package_at(directory <> "/library", "library", "", "answer() { 42 }")
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("library", "../library"),
    "main() { Nil }",
  )
  let assert Ok(_) = build.build(directory <> "/app")
  support.write(directory <> "/app/build/dev/erlang/unmanaged/keep", "keep")
  application(directory <> "/app", "", "main() { Nil }")
  let assert Ok(_) = build.build(directory <> "/app")
  assert simplifile.is_directory(directory <> "/app/build/dev/erlang/library")
    == Ok(False)
  assert simplifile.read(directory <> "/app/build/dev/erlang/unmanaged/keep")
    == Ok("keep")
}

pub fn escripts_include_dependency_foreign_code_and_resources_after_relocation_test() {
  use directory <- support.with_directory("deps_export")
  let original = directory <> "/original"
  package_at(
    original <> "/library",
    "library",
    "",
    "external Resource from erlang \"dep_resource\" { read() -> String }\nread() { Resource.read() }",
  )
  support.write(original <> "/library/priv/answer.txt", "library resource")
  support.write(
    original <> "/library/ffi/dep_resource.erl",
    "-module(dep_resource).\n-export([read/0]).\nread() -> {ok, Data} = file:read_file(filename:join(code:priv_dir(library), \"answer.txt\")), Data.\n",
  )
  application(
    original <> "/app",
    "[dependencies]\n" <> local("library", "../library"),
    "import library\nmain() { echo library.read() }",
  )
  let assert Ok(report) = escript.export(original <> "/app")
  let moved = directory <> "/moved"
  let assert Ok(Nil) = simplifile.copy_file(report.path, moved)
  let assert Ok(Nil) = simplifile.delete(original)
  assert execute(moved, [], directory)
    == #(0, "src/main.pooka:3\n\"library resource\"\n")
}

pub fn malformed_dependency_declarations_fail_before_resolution_test() {
  use directory <- support.with_directory("deps_bad_manifest")
  list.each(
    [
      "library = { path = 1 }",
      "library = { path = \"\" }",
      "library = { git = \"repo\", branch = \"a\", tag = \"b\" }",
      "library = \"not a version\"",
    ],
    fn(declaration) {
      application(
        directory,
        "[dependencies]\n" <> declaration,
        "main() { Nil }",
      )
      assert support.cli_main(["deps", "download"], command.plain(directory)).status
        == 1
    },
  )
}

pub fn malformed_lock_package_records_are_not_overwritten_test() {
  use directory <- support.with_directory("deps_bad_lock_record")
  application(directory, "", "main() { Nil }")
  let corrupt = "version = 1\n[[packages]]\nname = 42\n"
  support.write(directory <> "/pooka.lock", corrupt)
  assert support.cli_main(["deps", "download"], command.plain(directory)).status
    == 1
  assert simplifile.read(directory <> "/pooka.lock") == Ok(corrupt)
}

pub fn invalid_lockfiles_fail_before_replacing_existing_beams_test() {
  use directory <- support.with_directory("deps_lock_publication")
  application(directory, "", "main() { echo 42 }")
  let assert Ok(report) = build.build(directory)
  let path = report.directory <> "/pooka@app@main.beam"
  let assert Ok(before) = simplifile.read_bits(path)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo 99 }",
  )
  support.write(directory <> "/pooka.lock", "version = 999\n")
  let assert Error(_) = build.build(directory)
  assert simplifile.read_bits(path) == Ok(before)
}

pub fn source_defined_iterator_contracts_work_from_a_dependency_test() {
  use directory <- support.with_directory("deps_iterator")
  package_at(directory <> "/standard", "standard", "", "")
  support.write(
    directory <> "/standard/src/iterator.pooka",
    "module iterator\ninterface Iterator(a) { next() -> Option(a) }\nactor Single with Iterator(Int) { let value: Int\nnew(value) { self.value = value }\nnext() -> Option(Int) { Some(value) } }\n",
  )
  application(
    directory <> "/app",
    "[dependencies]\n" <> local("standard", "../standard"),
    "import iterator.{Iterator as Cursor, Single}\nactor Own with Cursor(Int) { next() -> Option(Int) { Some(42) } }\nfirst(values: Cursor(Int)) { loop value in values { break value } }\nmain() { echo #(first(Own.new()),first(Single.new(41))) }",
  )
  let report = support.cli_main(["run"], command.plain(directory <> "/app"))
  assert report.status == 0
  assert report.stdout == "#(42, 41)\n"
}

// Listing the recorded graph is an inspection, not an update request. It must
// not contact sources or refresh revision pins as a side effect.
pub fn dependency_inspection_is_offline_and_preserves_lockfile_test() {
  use directory <- support.with_directory("deps_inspection")
  package_at(directory <> "/shared", "shared", "", "answer() { 42 }")
  package_at(
    directory <> "/left",
    "left",
    "[dependencies]\n" <> local("shared", "../shared"),
    "answer() { 42 }",
  )
  package_at(
    directory <> "/right",
    "right",
    "[dependencies]\n" <> local("shared", "../shared"),
    "answer() { 42 }",
  )
  application(
    directory <> "/app",
    "[dependencies]\n"
      <> local("left", "../left")
      <> "[dev-dependencies]\n"
      <> local("right", "../right"),
    "main() { Nil }",
  )
  let env = command.plain(directory <> "/app")
  assert support.cli_main(["deps", "download"], env).status == 0
  let assert Ok(before) = simplifile.read(directory <> "/app/pooka.lock")

  let assert Ok(_) = simplifile.delete(directory <> "/shared")
  let assert Ok(_) = simplifile.delete(directory <> "/left")
  let assert Ok(_) = simplifile.delete(directory <> "/right")
  let listed = support.cli_main(["deps", "list"], env)
  assert listed.status == 0
  assert listed.stderr == ""
  assert string.contains(listed.stdout, "shared 0.1.0")
  let tree = support.cli_main(["deps", "tree"], env)
  assert tree.status == 0
  assert string.contains(tree.stdout, "└── shared 0.1.0 (path: ../shared) (*)")
  assert simplifile.read(directory <> "/app/pooka.lock") == Ok(before)
  tree.stdout |> birdie.snap(title: "dependencies locked tree")
}

pub fn dependency_inspection_marks_missing_locks_without_resolving_test() {
  use directory <- support.with_directory("deps_missing_inspection")
  application(
    directory,
    "[dependencies]\nmissing = { path = \"../unavailable\" }\n",
    "main() { Nil }",
  )
  let env = command.plain(directory)
  assert support.cli_main(["deps", "list"], env).status == 0
  assert support.cli_main(["deps", "tree"], env).stdout
    == "app 0.1.0\n└── missing (not locked)\n"
  assert simplifile.is_file(directory <> "/pooka.lock") == Ok(False)
}
