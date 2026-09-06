//// The terminal is the compiler's front porch.
////
//// Parse commands, dispatch their handlers and print the returned outcome to the
//// correct streams. Keep exit status in the outcome until the outermost
//// executable boundary.
////
//// ```text
//// pooka check -> command outcome -> stdout, stderr, exit status
//// ```

// SPDX-License-Identifier: Apache-2.0

import argv
import cli/command.{type Environment, type Info, type Outcome}
import cli/commands/add
import cli/commands/build
import cli/commands/check
import cli/commands/clean
import cli/commands/deps
import cli/commands/docs
import cli/commands/export
import cli/commands/format
import cli/commands/help
import cli/commands/new
import cli/commands/publish
import cli/commands/remove
import cli/commands/run
import cli/commands/tests
import cli/commands/version
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tools/progress
import utilities/colour
import utilities/process
import utilities/text
import utilities/timer

pub type Command {
  Help
  Version
  CommandHelp(path: List(String))
  New(arguments: List(String))
  Check(arguments: List(String))
  Build(arguments: List(String))
  Run(arguments: List(String))
  Test(arguments: List(String))
  Format(arguments: List(String))
  Docs(arguments: List(String))
  Add(arguments: List(String))
  Remove(arguments: List(String))
  Deps(arguments: List(String))
  Export(arguments: List(String))
  Publish(arguments: List(String))
  Clean(arguments: List(String))

  Unknown(name: String)
}

pub fn commands() -> List(Info) {
  [
    new.info,
    check.info,
    build.info,
    run.info,
    tests.info,
    format.info,
    docs.info,
    add.info,
    remove.info,
    deps.info,
    export.info,
    publish.info,
    clean.info,
    help.info,
    version.info,
  ]
}

pub fn parse(arguments: List(String)) -> Command {
  case arguments {
    [] | ["help"] | ["-h"] | ["--help"] -> Help
    ["help", "--help"] | ["help", "-h"] -> CommandHelp(["help"])
    ["help", ..path] -> CommandHelp(path)
    ["version"] | ["-V"] | ["--version"] -> Version
    [name, ..rest] -> {
      let #(own, _) = list.split_while(rest, fn(arg) { arg != "--" })
      case list.any(own, fn(arg) { arg == "-h" || arg == "--help" }) {
        True ->
          CommandHelp(case name, own {
            "deps", [subcommand, ..]
            | "export", [subcommand, ..]
              if subcommand != "--help" && subcommand != "-h"
            -> [name, subcommand]
            _, _ -> [name]
          })
        False -> command(name, rest)
      }
    }
  }
}

fn command(name: String, rest: List(String)) -> Command {
  case name {
    "new" -> New(rest)
    "check" -> Check(rest)
    "build" -> Build(rest)
    "run" -> Run(rest)
    "test" -> Test(rest)
    "format" | "fmt" -> Format(rest)
    "docs" -> Docs(rest)
    "add" -> Add(rest)
    "remove" -> Remove(rest)
    "deps" -> Deps(rest)
    "export" -> Export(rest)
    "publish" -> Publish(rest)
    "clean" -> Clean(rest)
    other -> Unknown(other)
  }
}

pub fn execute(
  command: Command,
  toolchain: String,
  environment: Environment,
) -> Outcome {
  case command {
    Help -> help.run(commands(), toolchain, environment.stdout)
    CommandHelp(path) -> help.for_command(commands(), path, environment.stdout)
    Version -> version.run(toolchain)
    New(arguments) -> new.run(arguments, environment)
    Check(arguments) -> check.run(arguments, environment)
    Build(arguments) -> build.run(arguments, environment)
    Run(arguments) -> run.run(arguments, environment)
    Test(arguments) -> tests.run(arguments, environment)
    Format(arguments) -> format.run(arguments, environment)
    Docs(arguments) -> docs.run(arguments, environment)
    Add(arguments) -> add.run(arguments, environment)
    Remove(arguments) -> remove.run(arguments, environment)
    Deps(arguments) -> deps.run(arguments, environment)
    Export(arguments) -> export.run(arguments, environment)
    Publish(arguments) -> publish.run(arguments, environment)
    Clean(arguments) -> clean.run(arguments, environment)
    Unknown(name) -> unknown(name, environment)
  }
}

/// Read executable arguments, enable scoped progress reporting, print the command
/// outcome and apply its final exit status.
///
/// ```text
/// library outcome -> outer executable boundary
/// ```
pub fn cli(toolchain: String) -> Nil {
  let outcome = case command.from_system() {
    Ok(environment) -> {
      let arguments = argv.load().arguments
      progress.with_reporting(environment.stderr == colour.Ansi, fn() {
        main(arguments, toolchain, environment)
      })
    }
    Error(error) ->
      new.failure(
        error,
        command.Environment(
          working_directory: ".",
          stdout: colour.PlainText,
          stderr: colour.detect(colour.Stderr),
          clock: timer.now,
          inherit_stdio: True,
        ),
      )
  }
  print(outcome)
}

fn print(outcome: Outcome) -> Nil {
  io.print_error(outcome.stderr)
  io.print(outcome.stdout)
  case outcome.status {
    0 -> Nil
    status -> process.exit(status)
  }
}

/// Run command dispatch with an explicit environment and return its outcome
/// without printing it at this boundary.
///
/// ```text
/// arguments + environment -> Outcome(stdout, stderr, status)
/// ```
pub fn main(
  arguments: List(String),
  toolchain: String,
  environment: Environment,
) -> Outcome {
  execute(parse(arguments), toolchain, environment)
}

fn unknown(name: String, environment: Environment) -> Outcome {
  let #(title, kind) = case string.starts_with(name, "-") {
    True -> #("unknown option", "an option")
    False -> #("unknown command", "a command")
  }
  let names =
    commands()
    |> list.map(fn(info) { info.name })
    |> list.filter(fn(candidate) { !string.starts_with(candidate, "-") })
  let base =
    diagnostic.error("cli.unknown_command", title)
    |> diagnostic.conclusion(
      "`pooka " <> name <> "` is not " <> kind <> " that Pooka understands.",
    )
  let with_help = case text.closest(name, names) {
    Some(suggestion) ->
      diagnostic.help(base, "Did you mean `pooka " <> suggestion <> "`?")
    None ->
      diagnostic.help(base, "Run `pooka --help` to see the available commands.")
  }
  with_help
  |> render.render(dict.new(), environment.stderr)
  |> command.failure
}
