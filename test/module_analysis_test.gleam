//// Trace the borrowing paths before typing the books.
////
//// Build module graphs directly to check import cycles, exports and
//// declaration relationships. A cycle may overlap another cycle or arrive
//// through a prefix; diagnostics should identify the actual loop and preserve
//// real source locations.

import birdie
import builder/check
import cli/command
import compiler/analysis/module
import diagnostics/diagnostic
import diagnostics/json as diagnostic_json
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/set
import gleam/string
import support
import utilities/colour
import utilities/location

fn source(identity: String, imports: String) -> module.SourceModule {
  module.SourceModule(
    identity,
    "src/" <> identity <> ".pooka",
    support.parse("module fragment\n" <> imports),
  )
}

pub fn no_cycles_in_empty_or_acyclic_graphs_test() {
  assert module.check([]) == []
  assert module.check([
      source("a", "import b"),
      source("b", "import c"),
      source("c", ""),
    ])
    == []
  assert module.check([
      source("a", "import b\nimport c"),
      source("b", "import d"),
      source("c", "import d"),
      source("d", ""),
    ])
    == []
}

pub fn direct_self_import_test() {
  let assert [value] = module.check([source("a", "import a")])
  assert value.id == "analysis.module_cycle"
  assert value.conclusion == "Module imports form a cycle: a -> a."
  assert list.length(value.labels) == 1
}

pub fn two_module_cycle_test() {
  let assert [value] =
    module.check([source("a", "import b"), source("b", "import a")])
  assert value.conclusion == "Module imports form a cycle: a -> b -> a."
  assert list.length(value.labels) == 2
}

pub fn longer_cycle_with_prefix_test() {
  let assert [value] =
    module.check([
      source("entry", "import a"),
      source("a", "import b"),
      source("b", "import c"),
      source("c", "import a"),
    ])
  assert value.conclusion == "Module imports form a cycle: a -> b -> c -> a."
  assert list.length(value.labels) == 3
}

pub fn separate_cycles_are_both_reported_test() {
  assert list.length(
      module.check([
        source("a", "import b"),
        source("b", "import a"),
        source("c", "import d"),
        source("d", "import c"),
      ]),
    )
    == 2
}

// Finding one loop does not prove every related loop was reported. The
// overlapping graph exercises cycle discovery beyond a single visited path.
pub fn overlapping_cycles_are_detected_test() {
  let values =
    module.check([
      source("a", "import b"),
      source("b", "import c\nimport a"),
      source("c", "import a"),
    ])
  assert list.length(values) == 2
  assert list.all(values, fn(value) { value.id == "analysis.module_cycle" })
}

pub fn paths_and_aliases_do_not_change_module_identity_test() {
  let assert [value] =
    module.check([
      source("http/client", "import api/request as requests"),
      source("api/request", "import http/client.{send}"),
    ])
  assert value.conclusion
    == "Module imports form a cycle: http/client -> api/request -> http/client."
}

pub fn unknown_external_modules_are_not_local_cycles_test() {
  assert module.check([source("a", "import io\nimport dependency/parser")])
    == []
}

pub fn cycle_diagnostic_snapshot_test() {
  let a = "module a\nimport b\n"
  let b = "module b\nimport a\n"
  module.check([source("a", "import b"), source("b", "import a")])
  |> render.render_all(
    dict.from_list([#("src/a.pooka", a), #("src/b.pooka", b)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "analysis: module cycle across files")
}

pub fn project_checks_report_module_cycles_test() {
  use directory <- support.with_directory("module_cycle_project")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/a.pooka", "module a\nimport b\n")
  support.write(directory <> "/src/b.pooka", "module b\nimport a\n")
  let assert Ok(report) = check.check_project(directory)
  let assert [value] = check.diagnostics(report)
  assert value.id == "analysis.module_cycle"
  let outcome = support.cli_main(["check", "--json"], command.plain(directory))
  assert outcome.status == 1
  assert support.diagnostics(outcome.stderr) == ""
}

pub fn tests_are_clients_not_importable_modules_test() {
  use directory <- support.with_directory("module_test_clients")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/a.pooka",
    "module a\nimport b\nf() { b.work() }\n",
  )
  support.write(
    directory <> "/test/b.spec.pooka",
    "module b\nimport a\ntest \"uses a\" { a.f() }\n",
  )

  let assert Ok(report) = check.check_project(directory)
  assert list.map(check.diagnostics(report), fn(d) { d.id })
    == ["module.unknown"]
}

pub fn unknown_modules_are_reported_with_a_suggestion_test() {
  use directory <- support.with_directory("module_unknown")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\nimport htpp\n")
  support.write(directory <> "/src/http.pooka", "module http\n")
  let assert Ok(report) = check.check_project(directory)
  let assert [diagnostic] = check.diagnostics(report)
  assert diagnostic.id == "module.unknown"
  assert diagnostic.conclusion == "Could not find module `htpp`."
  assert diagnostic.suggestions == ["Did you mean `http`?"]
}

pub fn io_and_iterator_require_real_library_sources_test() {
  use directory <- support.with_directory("module_core")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport io\nimport iterator\nmain() { Nil }\n",
  )
  let assert Ok(report) = check.check_project(directory)
  assert list.map(check.diagnostics(report), fn(value) { value.id })
    == ["module.unknown", "module.unknown"]
}

pub fn known_selective_imports_are_checked_test() {
  let target =
    module.SourceModule(
      "account",
      "src/account.pooka",
      support.parse("module account\nclass User {}\nload() {}\n"),
    )
  assert module.check_imports(
      [source("main", "import account.{User, load as fetch}")],
      [target],
      set.new(),
    )
    == []
  let assert [value] =
    module.check_imports(
      [source("main", "import account.{Missing as User}")],
      [
        target,
      ],
      set.new(),
    )
  assert value.id == "analysis.unknown_imported_name"
}

pub fn imports_do_not_reexport_declarations_test() {
  let target = source("account", "import elsewhere.{User}")
  let assert [value] =
    module.check_imports(
      [source("main", "import account.{User}")],
      [target],
      set.new(),
    )
  assert value.id == "analysis.unknown_imported_name"
}

pub fn private_imports_do_not_cascade_as_unknown_test() {
  assert module.check_imports(
      [source("main", "import account.{_secret}")],
      [
        source("account", ""),
      ],
      set.new(),
    )
    == []
}

pub fn tests_check_selective_imports_against_production_test() {
  use directory <- support.with_directory("module_import_members")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/account.pooka",
    "module account\nclass User {}\n",
  )
  support.write(
    directory <> "/test/account.spec.pooka",
    "module account_test\nimport account.{Missing}\n",
  )
  let assert Ok(report) = check.check_project(directory)
  let assert [value] = check.diagnostics(report)
  assert value.id == "analysis.unknown_imported_name"
  assert result_path(diagnostic.primary_location(value))
    == "test/account.spec.pooka"
}

fn result_path(location: Result(location.Location, Nil)) -> String {
  case location {
    Ok(value) -> value.path
    Error(Nil) -> ""
  }
}

pub fn unknown_local_import_diagnostic_snapshot_test() {
  let target =
    module.SourceModule(
      "account",
      "src/account.pooka",
      support.parse("module account\nclass User {}\n"),
    )
  module.check_imports(
    [source("main", "import account.{Missing}")],
    [target],
    set.new(),
  )
  |> render.render_all(
    dict.from_list([
      #("src/main.pooka", "module main\nimport account.{Missing}\n"),
    ]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "analysis: unknown local imported declaration")
}

pub fn project_checks_qualified_value_and_type_names_test() {
  use directory <- support.with_directory("module_qualified_names")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/account.pooka",
    "module account\nclass User {}\nload() { Nil }\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport account as users\nf(value: users.Missing) { users.missing() }\n",
  )
  let assert Ok(report) = check.check_project(directory)
  assert list.map(check.diagnostics(report), fn(value) { value.id })
    == ["analysis.unknown_module_member", "analysis.unknown_module_member"]
}

pub fn dependency_order_places_local_imports_first_test() {
  let assert Ok(ordered) =
    module.order([
      source("a", "import b"),
      source("b", "import c"),
      source("c", ""),
    ])
  assert list.map(ordered, fn(value) { value.identity }) == ["c", "b", "a"]
  let assert Error(_) =
    module.order([source("a", "import b"), source("b", "import a")])
}

// A failed parse belongs to its source file. The two readers should not get
// extra missing-module complaints merely because they arrived at its door.
fn broken_import_fixture(directory: String) -> check.Report {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nvalue() { 1\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helper\nmain() { echo helper.value() }\n",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\nimport helper.{value}\ntest \"value\" { assert value() == 1 }\n",
  )
  let assert Ok(report) = check.check_project(directory)
  report
}

pub fn failed_modules_do_not_disappear_at_production_and_selective_test_imports_test() {
  use directory <- support.with_directory("module_failed_import")
  let report = broken_import_fixture(directory)
  let assert [value] = check.diagnostics(report)
  assert value.id == "parse.unclosed_delimiter"
  assert result_path(diagnostic.primary_location(value)) == "src/helper.pooka"
}

pub fn failed_import_diagnostic_text_and_json_snapshot_test() {
  use directory <- support.with_directory("module_failed_import_snapshot")
  let report = broken_import_fixture(directory)
  let values = check.diagnostics(report)
  let sources =
    dict.from_list(
      list.map(report.files, fn(file) { #(file.path, file.source) }),
    )
  let output =
    render.render_all(values, sources, colour.PlainText, diagnostic.Quiet)
    <> "\nJSON:\n"
    <> diagnostic_json.render(values, diagnostic.Quiet)
  birdie.snap(output, title: "analysis: failed module keeps its own diagnostic")
}

pub fn failed_modules_do_not_hide_genuinely_missing_imports_test() {
  use directory <- support.with_directory("module_failed_and_missing")
  let _ = broken_import_fixture(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helper\nimport absent\nmain() { echo helper.value() }\n",
  )
  let assert Ok(report) = check.check_project(directory)
  let missing =
    list.filter(check.diagnostics(report), fn(value) {
      value.id == "module.unknown"
    })
  let assert [value] = missing
  assert value.conclusion == "Could not find module `absent`."
  assert list.length(check.diagnostics(report)) == 2
}

pub fn lexical_failures_do_not_create_missing_module_errors_test() {
  use directory <- support.with_directory("module_failed_lex")
  let _ = broken_import_fixture(directory)
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nvalue() { @ }\n",
  )
  let assert Ok(report) = check.check_project(directory)
  let values = check.diagnostics(report)
  assert list.any(values, fn(value) { string.starts_with(value.id, "lex.") })
  assert list.all(values, fn(value) {
    result_path(diagnostic.primary_location(value)) == "src/helper.pooka"
  })
}

pub fn failed_module_does_not_hide_independent_resolution_errors_test() {
  use directory <- support.with_directory("module_failed_and_unrelated")
  let _ = broken_import_fixture(directory)
  support.write(
    directory <> "/src/other.pooka",
    "module other\nwork() { missing() }\n",
  )
  let assert Ok(report) = check.check_project(directory)
  let values = check.diagnostics(report)
  assert list.length(values) == 2
  assert list.any(values, fn(value) {
    result_path(diagnostic.primary_location(value)) == "src/other.pooka"
  })
  assert !list.any(values, fn(value) { value.id == "module.unknown" })
}

pub fn broken_test_files_do_not_become_importable_modules_test() {
  use directory <- support.with_directory("module_broken_test_target")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helper\nmain() { Nil }\n",
  )
  support.write(
    directory <> "/test/helper.spec.pooka",
    "module helper_test\ntest \"broken\" {\n",
  )
  let assert Ok(report) = check.check_project(directory)
  let missing =
    list.filter(check.diagnostics(report), fn(value) {
      value.id == "module.unknown"
    })
  let assert [value] = missing
  assert value.conclusion == "Could not find module `helper`."
}

pub fn failed_local_dependency_modules_keep_their_package_identity_test() {
  use directory <- support.with_directory("module_failed_dependency")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nlibrary = { path = \"library\" }\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helper\nmain() { echo helper.value() }\n",
  )
  support.write(
    directory <> "/library/pooka.toml",
    "name = \"library\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/library/src/helper.pooka",
    "module helper\nvalue() { 1\n",
  )
  let assert Ok(report) = check.check_project(directory)
  let assert [value] = check.diagnostics(report)
  assert value.id == "parse.unclosed_delimiter"
}

// A failure elsewhere in the graph must not lend a transitive package to a
// caller that never declared it. Visibility is part of the address too.
pub fn failed_transitive_modules_do_not_hide_undeclared_imports_test() {
  use directory <- support.with_directory("module_failed_invisible_dependency")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nleft = { path = \"left\" }\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helper\nmain() { Nil }\n",
  )
  support.write(
    directory <> "/left/pooka.toml",
    "name = \"left\"\nversion = \"1.0.0\"\n[dependencies]\nright = { path = \"../right\" }\n",
  )
  support.write(
    directory <> "/left/src/left.pooka",
    "module left\nwork() { Nil }\n",
  )
  support.write(
    directory <> "/right/pooka.toml",
    "name = \"right\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/right/src/helper.pooka",
    "module helper\nvalue() { 1\n",
  )
  let assert Ok(report) = check.check_project(directory)
  let missing =
    list.filter(check.diagnostics(report), fn(value) {
      value.id == "module.unknown"
    })
  let assert [value] = missing
  assert value.conclusion == "Could not find module `helper`."
}
