//// The front desk should answer before opening a project.
////
//// Check command parsing, help, project creation and the shape of successful
//// or failed outcomes. Plain and coloured help must carry the same words, with
//// every style reset. Filesystem and diagnostic checks use temporary projects
//// rather than a developer's current checkout.
////
//// ```sh
//// pooka --help
//// pooka deps --help
//// pooka new my_app
//// ```

import birdie
import cli/cli
import cli/command
import cli/commands/help
import gleam/bit_array
import gleam/list
import gleam/string
import pooka
import project/hexdocs
import project/lockfile
import project/package
import project/project
import simplifile
import support
import tom
import utilities/colour

pub fn parse_test() {
  assert cli.parse([]) == cli.Help
  assert cli.parse(["--help"]) == cli.Help
  assert cli.parse(["-h"]) == cli.Help
  assert cli.parse(["help"]) == cli.Help
  assert cli.parse(["check", "--help"]) == cli.CommandHelp(["check"])
  assert cli.parse(["-V"]) == cli.Version
  assert cli.parse(["--version"]) == cli.Version
  assert cli.parse(["new", "app"]) == cli.New(["app"])
  assert cli.parse(["check", "--verbose"]) == cli.Check(["--verbose"])
  assert cli.parse(["run", "--", "input.txt"]) == cli.Run(["--", "input.txt"])
  assert cli.parse(["test"]) == cli.Test([])
  assert cli.parse(["export", "escript"]) == cli.Export(["escript"])
  assert cli.parse(["frobnicate"]) == cli.Unknown("frobnicate")
}

pub fn every_command_of_the_specification_exists_test() {
  let names = list.map(cli.commands(), fn(info) { info.name })
  [
    "new", "check", "build", "run", "test", "format", "docs", "add", "remove",
    "deps", "export", "publish", "clean",
  ]
  |> list.each(fn(name) {
    assert list.contains(names, name)
  })

  assert !list.contains(names, "init")
  assert !list.contains(names, "lsp")
  assert cli.parse(["lsp"]) == cli.Unknown("lsp")
}

pub fn help_snapshot_test() {
  help.text(cli.commands(), pooka.version, colour.PlainText)
  |> string.replace(pooka.version, "<version>")
  |> birdie.snap(title: "cli: help")
}

pub fn coloured_help_snapshot_test() {
  help.text(cli.commands(), pooka.version, colour.Ansi)
  |> string.replace(pooka.version, "<version>")
  |> support.show_escapes
  |> birdie.snap(title: "cli: help with colour")
}

pub fn version_test() {
  let outcome = support.cli_main(["--version"], command.plain("."))
  assert outcome.stdout == "pooka " <> pooka.version <> "\n"
  assert outcome.status == 0
  let plain = command.plain(".")
  assert cli.main(["-V"], "9.8.7", plain).stdout == "pooka 9.8.7\n"
  assert string.contains(cli.main(["--help"], "9.8.7", plain).stdout, "9.8.7")
}

pub fn version_matches_the_package_test() {
  let assert Ok(manifest) = simplifile.read("gleam.toml")
  let assert Ok(config) = tom.parse(manifest)
  let assert Ok(package) = tom.get_string(config, ["version"])
  assert pooka.version == package
}

pub fn unknown_command_suggests_a_command_test() {
  let outcome = support.cli_main(["chek"], command.plain("."))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "Did you mean `pooka check`?")
}

pub fn unknown_command_snapshot_test() {
  support.cli_main(["frobnicate"], command.plain(".")).stderr
  |> birdie.snap(title: "cli: unknown command")
}

pub fn new_creates_a_project_test() {
  use directory <- support.with_directory("cli_new")
  let outcome = support.cli_main(["new", "my_app"], command.plain(directory))
  assert outcome.status == 0
  assert string.contains(outcome.stdout, "create my_app/src/main.pooka")
  assert simplifile.is_file(directory <> "/my_app/pooka.toml") == Ok(True)
}

pub fn new_without_a_name_test() {
  let outcome = support.cli_main(["new"], command.plain("."))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "missing project name")
}

pub fn new_with_an_invalid_name_snapshot_test() {
  use directory <- support.with_directory("cli_new_invalid")
  support.cli_main(["new", "My-App"], command.plain(directory)).stderr
  |> birdie.snap(title: "cli: new with an invalid name")
}

// Follow creation with checking and test execution. A generated spec is
// useful only if a new user can actually run its arithmetic assertion.
pub fn a_new_project_checks_cleanly_test() {
  use directory <- support.with_directory("cli_new_check")
  let _ = support.cli_main(["new", "my_app"], command.plain(directory))
  cache_starter_stdlib(directory <> "/my_app")
  let outcome =
    support.cli_main(["check"], command.plain(directory <> "/my_app"))
  assert outcome.status == 0
  assert outcome.stdout == ""
  assert string.contains(outcome.stderr, "Checked 3 files in 0µs")
  assert support.diagnostics(outcome.stderr) == ""
  let tests = support.cli_main(["test"], command.plain(directory <> "/my_app"))
  assert tests.status == 0
  assert string.contains(tests.stdout, "one plus one is two")
  assert string.contains(tests.stdout, "1 test, 1 passed")
}

pub fn check_outside_a_project_test() {
  use directory <- support.with_directory("cli_check_outside")
  let outcome = support.cli_main(["check"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "not inside a Pooka project")
}

pub fn check_reports_errors_test() {
  use directory <- support.with_directory("cli_check_errors")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\n\nmain() {\n  let x =\n}\n",
  )
  let outcome = support.cli_main(["check"], command.plain(directory))
  assert outcome.status == 1
  assert outcome.stdout == ""
  assert string.contains(outcome.stderr, "src/main.pooka:5:1")
  assert string.contains(outcome.stderr, "Found 1 error.")
}

pub fn check_reports_mismatched_module_names_test() {
  use directory <- support.with_directory("cli_check_module_name")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/web/router.pooka", "module routes\n")
  let outcome = support.cli_main(["check"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "must declare `module router`")
}

pub fn check_rejects_unknown_arguments_test() {
  let outcome = support.cli_main(["check", "--fast"], command.plain("."))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "does not accept `--fast`")
}

pub fn run_executes_a_new_project_test() {
  use directory <- support.with_directory("cli_run")
  let _ = support.cli_main(["new", "my_app"], command.plain(directory))
  cache_starter_stdlib(directory <> "/my_app")
  let outcome =
    support.cli_main(
      ["run", "--", "ignored"],
      command.plain(directory <> "/my_app"),
    )
  assert outcome.status == 0
  assert outcome.stdout == "\"Hello from my_app!\"\n"
}

pub fn json_project_failure_test() {
  use directory <- support.with_directory("cli_json_outside")
  let outcome = support.cli_main(["check", "--json"], command.plain(directory))
  assert outcome.status == 1
  assert support.diagnostics(outcome.stderr) == ""
  assert string.contains(outcome.stdout, "\"errors\":1")
  assert string.contains(outcome.stdout, "\"labels\":[]")
}

pub fn json_invalid_arguments_test() {
  let outcome =
    support.cli_main(["check", "--json", "--fast"], command.plain("."))
  assert outcome.status == 1
  assert support.diagnostics(outcome.stderr) == ""
  assert string.contains(outcome.stdout, "does not accept")
}

pub fn check_reports_local_name_errors_as_json_test() {
  use directory <- support.with_directory("cli_resolve_json")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { missing() }\n",
  )
  let outcome = support.cli_main(["check", "--json"], command.plain(directory))
  assert outcome.status == 1
  assert support.diagnostics(outcome.stderr) == ""
  assert string.contains(outcome.stdout, "analysis.unknown_name")
}

pub fn unused_import_warnings_do_not_fail_check_test() {
  use directory <- support.with_directory("cli_unused_warning")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport unused\nmain() { Nil }\n",
  )
  support.write(directory <> "/src/unused.pooka", "module unused\n")
  let outcome = support.cli_main(["check", "--json"], command.plain(directory))
  assert outcome.status == 0
  assert support.diagnostics(outcome.stderr) == ""
  assert string.contains(outcome.stdout, "analysis.unused_import")
  assert string.contains(outcome.stdout, "\"warnings\":1")
  let fixed =
    support.cli_main(["check", "--fix", "--json"], command.plain(directory))
  assert fixed.status == 0
  assert string.contains(fixed.stdout, "\"warnings\":0")
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\n\nmain() { Nil }\n")
}

pub fn run_reports_warnings_while_executing_test() {
  use directory <- support.with_directory("cli_run_warning")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\n_unused() { Nil }\nmain() { Nil }\n",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 0
  assert outcome.stdout == ""
  assert string.contains(outcome.stderr, "warning: unused private declaration")
}

// Help is available before project discovery. A command must explain itself
// even when the current directory has no manifest to open.
pub fn every_command_has_individual_help_without_project_access_test() {
  let environment = command.plain("/does/not/exist")
  list.each(cli.commands(), fn(info) {
    case string.starts_with(info.name, "-") {
      True -> Nil
      False -> {
        let direct = support.cli_main([info.name, "--help"], environment)
        assert direct.status == 0
        assert direct.stderr == ""
        assert string.contains(direct.stdout, "Usage: pooka " <> info.name)
        assert direct == support.cli_main(["help", info.name], environment)
        assert direct == support.cli_main([info.name, "-h"], environment)
      }
    }
  })
  assert support.cli_main(["new", "app", "--help"], environment).status == 0
  assert cli.parse(["run", "--", "--help"]) == cli.Run(["--", "--help"])
  assert cli.parse(["fmt", "--check"]) == cli.Format(["--check"])
  assert cli.parse(["version"]) == cli.Version
}

pub fn nested_help_and_invalid_topics_test() {
  let env = command.plain("/does/not/exist")
  list.each(["download", "update", "list", "tree"], fn(subcommand) {
    let direct = support.cli_main(["deps", subcommand, "--help"], env)
    assert direct.status == 0
    assert direct == support.cli_main(["help", "deps", subcommand], env)
    assert string.contains(direct.stdout, "Usage: pooka deps " <> subcommand)
  })
  list.each(["escript", "shipment", "release"], fn(subcommand) {
    assert support.cli_main(["export", subcommand, "--help"], env).status == 0
  })
  assert support.cli_main(["help", "missing"], env).status == 1
  assert support.cli_main(["deps", "missing", "--help"], env).status == 1
  assert support.cli_main(["deps", "list", "extra"], env).status == 1
  assert support.cli_main(["deps"], env)
    == support.cli_main(["deps", "--help"], env)
}

pub fn dependency_help_snapshot_test() {
  support.cli_main(["deps", "--help"], command.plain(".")).stdout
  |> birdie.snap(title: "cli: dependency help")
}

pub fn command_help_snapshot_test() {
  support.cli_main(["test", "--help"], command.plain(".")).stdout
  |> birdie.snap(title: "cli: test help")
}

fn help_topics() -> List(List(String)) {
  let commands =
    cli.commands()
    |> list.filter(fn(info) { !string.starts_with(info.name, "-") })
    |> list.map(fn(info) { [info.name] })
  list.flatten([
    commands,
    [["version"], ["help"], ["fmt"]],
    list.map(["download", "update", "list", "tree"], fn(sub) { ["deps", sub] }),
    list.map(["escript", "shipment", "release"], fn(sub) { ["export", sub] }),
  ])
}

fn unstyled(text: String) -> String {
  case string.split(text, "\u{001b}[") {
    [] -> text
    [first, ..rest] ->
      list.fold(rest, first, fn(kept, piece) {
        case string.split_once(piece, "m") {
          Ok(#(_, after)) -> kept <> after
          Error(Nil) -> kept <> piece
        }
      })
  }
}

fn coloured_help(path: List(String)) -> String {
  help.for_command(cli.commands(), path, colour.Ansi).stdout
}

fn plain_help(path: List(String)) -> String {
  help.for_command(cli.commands(), path, colour.PlainText).stdout
}

pub fn coloured_command_help_has_the_same_text_test() {
  list.each(help_topics(), fn(path) {
    let coloured = coloured_help(path)
    assert coloured != plain_help(path)
    assert unstyled(coloured) == plain_help(path)
  })
}

pub fn plain_command_help_has_no_escapes_test() {
  list.each(help_topics(), fn(path) {
    assert !string.contains(plain_help(path), "\u{001b}")
  })
}

// One unclosed style can colour the rest of the user's terminal. Check the
// resets as well as the escape sequence that starts each style.
pub fn every_coloured_style_is_reset_test() {
  list.each(help_topics(), fn(path) {
    let coloured = coloured_help(path)
    let opened = list.length(string.split(coloured, "\u{001b}[")) - 1
    let resets = list.length(string.split(coloured, colour.reset)) - 1

    assert opened == resets * 2
  })
}

pub fn usage_lines_use_the_main_help_colours_test() {
  let coloured = coloured_help(["new"])
  assert string.contains(
    coloured,
    colour.bold_lantern_orange <> "Usage:" <> colour.reset <> " pooka ",
  )
  assert string.contains(
    coloured,
    colour.lantern_orange <> "new" <> colour.reset,
  )
  assert string.contains(
    coloured,
    colour.magic_violet <> "<name>" <> colour.reset,
  )
}

pub fn subcommands_in_usage_are_amber_test() {
  let coloured = coloured_help(["deps", "download"])
  assert string.contains(
    coloured,
    colour.lantern_orange
      <> "deps"
      <> colour.reset
      <> " "
      <> colour.lantern_orange
      <> "download"
      <> colour.reset,
  )
}

pub fn section_headings_are_bold_amber_test() {
  assert string.contains(
    coloured_help(["check"]),
    colour.bold_lantern_orange <> "Options:" <> colour.reset,
  )
  assert string.contains(
    coloured_help(["deps"]),
    colour.bold_lantern_orange <> "Commands:" <> colour.reset,
  )
  assert string.contains(
    coloured_help(["add"]),
    colour.bold_lantern_orange <> "Examples:" <> colour.reset,
  )
  assert string.contains(
    coloured_help(["run"]),
    colour.bold_lantern_orange <> "Example:" <> colour.reset,
  )
}

pub fn options_are_amber_with_sage_placeholders_test() {
  let coloured = coloured_help(["add"])
  assert string.contains(
    coloured,
    "  "
      <> colour.lantern_orange
      <> "--path"
      <> colour.reset
      <> " "
      <> colour.magic_violet
      <> "<path>"
      <> colour.reset
      <> "   Use a local package",
  )
  assert string.contains(
    coloured,
    colour.lantern_orange
      <> "--dev"
      <> colour.reset
      <> "           Add a development",
  )
}

pub fn the_help_option_is_coloured_everywhere_test() {
  list.each(help_topics(), fn(path) {
    case path {
      ["help"] | ["version"] -> Nil
      _ -> {
        assert string.contains(
          coloured_help(path),
          "  "
            <> colour.lantern_orange
            <> "-h,"
            <> colour.reset
            <> " "
            <> colour.lantern_orange
            <> "--help"
            <> colour.reset
            <> "  Print this help",
        )
      }
    }
  })
}

pub fn subcommand_rows_are_amber_test() {
  assert string.contains(
    coloured_help(["export"]),
    "  " <> colour.lantern_orange <> "escript" <> colour.reset <> "   Create",
  )
}

pub fn labels_are_bold_amber_test() {
  assert string.contains(
    coloured_help(["format"]),
    colour.bold_lantern_orange <> "Alias:" <> colour.reset <> " pooka fmt",
  )
  assert string.contains(
    coloured_help(["version"]),
    colour.bold_lantern_orange <> "Aliases:" <> colour.reset <> " -V, --version",
  )
  assert string.contains(
    coloured_help(["docs"]),
    colour.bold_lantern_orange <> "Output:" <> colour.reset <> " build/dev/docs",
  )
}

pub fn descriptions_and_examples_stay_unstyled_test() {
  let coloured = coloured_help(["add"])
  assert string.contains(
    coloured,
    "\nAdd a dependency to pooka.toml and resolve the package graph.\n",
  )
  assert string.contains(coloured, "\n  pooka add helper --path ../helper\n")
}

pub fn coloured_command_help_snapshot_test() {
  ["test", "add", "deps", "export", "format", "version"]
  |> list.map(fn(name) {
    let path = case name {
      "export" -> ["export", "release"]
      _ -> [name]
    }
    "$ pooka " <> string.join(path, " ") <> " --help\n" <> coloured_help(path)
  })
  |> string.join("\n")
  |> support.show_escapes
  |> birdie.snap(title: "cli: command help with colour")
}

pub fn the_cli_colours_help_on_a_terminal_test() {
  let environment =
    command.Environment(..command.plain("."), stdout: colour.Ansi)
  let outcome = cli.main(["check", "--help"], pooka.version, environment)
  assert outcome.stdout == coloured_help(["check"])
  let plain = cli.main(["check", "--help"], pooka.version, command.plain("."))
  assert plain.stdout == plain_help(["check"])
}

pub fn hexdocs_links_use_dns_package_names_test() {
  assert hexdocs.url("pooka_stdlib") == "https://pooka-stdlib.hexdocs.pm/"
  assert hexdocs.url("one_two_three") == "https://one-two-three.hexdocs.pm/"
  assert hexdocs.url("simple") == "https://simple.hexdocs.pm/"
}

@external(erlang, "shipment_test_ffi", "hex_archive")
fn starter_archive(
  directory: String,
  files: List(#(String, BitArray)),
) -> #(BitArray, String)

// Seed a small verified Hex fixture, leaving the generated manifest untouched.
// Starter-project CLI tests must not depend on registry availability.
fn cache_starter_stdlib(directory: String) {
  let #(bytes, checksum) =
    starter_archive(directory, [
      #(
        "pooka.toml",
        bit_array.from_string("name = \"pooka_stdlib\"\nversion = \"0.1.0\"\n"),
      ),
      #(
        "src/pooka/fixture.pooka",
        bit_array.from_string("module fixture\nanswer() { 42 }"),
      ),
    ])
  let assert Ok(root) = project.load(directory)
  let assert Ok(graph) =
    package.resolve_using(root, True, False, fn(url) {
      case string.ends_with(url, ".tar"), string.contains(url, "/releases/") {
        True, _ -> Ok(bytes)
        _, True ->
          Ok(bit_array.from_string(
            "{\"version\":\"0.1.0\",\"checksum\":\""
            <> checksum
            <> "\",\"requirements\":{},\"meta\":{\"app\":\"pooka_stdlib\",\"build_tools\":[\"pooka\",\"rebar3\"]}}",
          ))
        _, _ ->
          Ok(bit_array.from_string("{\"releases\":[{\"version\":\"0.1.0\"}]}"))
      }
    })
  let assert Ok(Nil) = lockfile.write(root, graph.packages)
  Nil
}

pub fn fresh_project_can_import_its_default_stdlib_dependency_test() {
  use directory <- support.with_directory("cli_new_stdlib")
  let created = support.cli_main(["new", "my_app"], command.plain(directory))
  assert created.status == 0
  let root = directory <> "/my_app"
  let assert Ok(before) = simplifile.read(root <> "/pooka.toml")
  cache_starter_stdlib(root)
  support.write(
    root <> "/src/main.pooka",
    "module main\nimport pooka/fixture\nmain() { echo fixture.answer() }",
  )
  let report = support.cli_main(["run"], command.plain(root))
  assert report.status == 0
  assert report.stdout == "42\n"
  assert simplifile.read(root <> "/pooka.toml") == Ok(before)
}
