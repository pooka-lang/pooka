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
import diagnostics/render
import gleam/dict
import gleam/list
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
    )
    == []
  let assert [value] =
    module.check_imports([source("main", "import account.{Missing as User}")], [
      target,
    ])
  assert value.id == "analysis.unknown_imported_name"
}

pub fn imports_do_not_reexport_declarations_test() {
  let target = source("account", "import elsewhere.{User}")
  let assert [value] =
    module.check_imports([source("main", "import account.{User}")], [target])
  assert value.id == "analysis.unknown_imported_name"
}

pub fn private_imports_do_not_cascade_as_unknown_test() {
  assert module.check_imports([source("main", "import account.{_secret}")], [
      source("account", ""),
    ])
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
  module.check_imports([source("main", "import account.{Missing}")], [target])
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
