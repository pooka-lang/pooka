//// Leave a clear sign beside every door.
////
//// Render global and command-specific usage with the same options accepted by
//// command parsing. Colour only the terminal presentation.
////
//// ```sh
//// pooka deps --help
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Info, type Outcome}
import gleam/int
import gleam/list
import gleam/string
import utilities/colour.{type Output}

pub const info =
  command.Info(name: "-h, --help", arguments: "", summary: "Print this help")

pub const tagline = "Objects belong on the BEAM too."

pub fn run(commands: List(Info), version: String, output: Output) -> Outcome {
  command.success(text(commands, version, output))
}

pub fn text(commands: List(Info), version: String, output: Output) -> String {
  let width =
    list.fold(commands, 0, fn(widest, command) {
      int.max(widest, string.length(label(command)))
    })
  let rows =
    commands
    |> list.map(fn(command) { "  " <> row(command, width, output) })
    |> string.join("\n")
  colour.paint("Pooka", colour.bold_lantern_orange, output)
  <> " programming language "
  <> colour.paint(version, colour.magic_violet, output)
  <> "\n"
  <> colour.paint(tagline, colour.magic_violet, output)
  <> "\n\n"
  <> colour.paint("Usage:", colour.bold_lantern_orange, output)
  <> " pooka "
  <> colour.paint("<command>", colour.magic_violet, output)
  <> " "
  <> colour.paint("[arguments]", colour.magic_violet, output)
  <> "\n\n"
  <> colour.paint("Commands:", colour.bold_lantern_orange, output)
  <> "\n"
  <> rows
  <> "\n\nRun `pooka <command> --help` for command-specific usage.\n"
}

fn row(command: Info, width: Int, output: Output) -> String {
  let name = colour.paint(command.name, colour.lantern_orange, output)
  let arguments = case command.arguments {
    "" -> ""
    arguments -> " " <> colour.paint(arguments, colour.magic_violet, output)
  }
  let padding = string.repeat(" ", width - string.length(label(command)))
  name <> arguments <> padding <> "  " <> command.summary
}

fn label(command: Info) -> String {
  case command.arguments {
    "" -> command.name
    arguments -> command.name <> " " <> arguments
  }
}

/// Render the command's own help instead of making the reader search a global
/// option list.
///
/// ```sh
/// pooka deps --help
/// ```
pub fn for_command(
  commands: List(Info),
  path: List(String),
  output: Output,
) -> Outcome {
  case path {
    ["version"] ->
      command.success(
        colour.paint(
          "Print the compiler version.",
          colour.bold_lantern_orange,
          output,
        )
        <> "\n\n"
        <> usage("version", "", output)
        <> "\n"
        <> styled_body("Aliases: -V, --version\n", output),
      )
    ["help"] ->
      command.success(
        usage("help", " [<command> [<subcommand>]]", output) <> "\n",
      )
    [name, ..rest] -> {
      let name = case name {
        "fmt" -> "format"
        _ -> name
      }
      case
        list.find(commands, fn(info) { info.name == name }),
        details(name, rest)
      {
        Ok(info), Ok(#(suffix, body)) ->
          command.success(
            colour.paint(info.summary, colour.bold_lantern_orange, output)
            <> "\n\n"
            <> usage(name, suffix, output)
            <> "\n\n"
            <> styled_body(with_help_option(body), output),
          )
        _, _ ->
          command.failure(
            "error: unknown help topic `"
            <> string.join(path, " ")
            <> "`\nRun `pooka --help` to see available commands.\n",
          )
      }
    }
    [] -> command.failure("error: missing help topic\n")
  }
}

fn usage(name: String, suffix: String, output: Output) -> String {
  colour.paint("Usage:", colour.bold_lantern_orange, output)
  <> " pooka "
  <> colour.paint(name, colour.lantern_orange, output)
  <> {
    suffix
    |> string.split(" ")
    |> list.map(fn(word) { argument(word, output) })
    |> string.join(" ")
  }
}

fn argument(word: String, output: Output) -> String {
  case word {
    "" -> ""
    "<" <> _ | "[" <> _ -> colour.paint(word, colour.magic_violet, output)
    _ -> colour.paint(word, colour.lantern_orange, output)
  }
}

type Section {
  Prose
  Options
  Commands
  Examples
}

fn styled_body(body: String, output: Output) -> String {
  let #(_, lines) =
    body
    |> string.split("\n")
    |> list.map_fold(Prose, fn(section, line) {
      case line {
        "" -> #(Prose, line)
        "  " <> content ->
          case section {
            Options -> #(section, "  " <> option_row(content, output))
            Commands -> #(section, "  " <> command_row(content, output))
            Prose | Examples -> #(section, line)
          }
        _ ->
          case heading(line) {
            Ok(next) -> #(
              next,
              colour.paint(line, colour.bold_lantern_orange, output),
            )
            Error(Nil) -> #(section, labelled(line, output))
          }
      }
    })
  string.join(lines, "\n")
}

fn heading(line: String) -> Result(Section, Nil) {
  case line {
    "Options:" -> Ok(Options)
    "Commands:" -> Ok(Commands)
    "Example:" | "Examples:" -> Ok(Examples)
    _ -> Error(Nil)
  }
}

fn labelled(line: String, output: Output) -> String {
  case string.split_once(line, ": ") {
    Ok(#(label, rest))
      if label == "Alias" || label == "Aliases" || label == "Output"
    ->
      colour.paint(label <> ":", colour.bold_lantern_orange, output)
      <> " "
      <> rest
    _ -> line
  }
}

fn option_row(content: String, output: Output) -> String {
  let #(term, description) =
    split_term(string.split(content, " "), [], fn(word) {
      case word {
        "-" <> _ | "<" <> _ | "[" <> _ -> True
        _ -> False
      }
    })
  join_row(list.map(term, argument(_, output)), description)
}

fn command_row(content: String, output: Output) -> String {
  case string.split_once(content, " ") {
    Ok(#(name, rest)) ->
      colour.paint(name, colour.lantern_orange, output) <> " " <> rest
    Error(Nil) -> colour.paint(content, colour.lantern_orange, output)
  }
}

fn split_term(
  words: List(String),
  term: List(String),
  in_term: fn(String) -> Bool,
) -> #(List(String), List(String)) {
  case words {
    [word, ..rest] if word != "" ->
      case in_term(word) {
        True -> split_term(rest, [word, ..term], in_term)
        False -> #(list.reverse(term), words)
      }
    _ -> #(list.reverse(term), words)
  }
}

fn join_row(term: List(String), description: List(String)) -> String {
  case description {
    [] -> string.join(term, " ")
    _ -> string.join(term, " ") <> " " <> string.join(description, " ")
  }
}

fn with_help_option(body: String) -> String {
  let common = "  -h, --help  Print this help"
  let #(has_options, sections) =
    body
    |> string.split("\n\n")
    |> list.map_fold(False, fn(found, section) {
      case string.starts_with(section, "  --") {
        True -> #(True, "Options:\n" <> section <> "\n" <> common)
        False -> #(found, section)
      }
    })
  string.join(sections, "\n\n")
  <> case has_options {
    True -> ""
    False -> "Options:\n" <> common <> "\n"
  }
}

fn details(name: String, rest: List(String)) -> Result(#(String, String), Nil) {
  case name, rest {
    "new", [] ->
      Ok(#(
        " <name>",
        "Create a project directory with source, tests and a pooka.toml.\n\n",
      ))
    "check", [] ->
      Ok(#(
        " [--verbose] [--json] [--fix]",
        "Type-check the project without building executable code.\n\n  --verbose  Include detailed diagnostics\n  --json     Emit machine-readable diagnostics\n  --fix      Apply supported automatic fixes\n\n",
      ))
    "build", [] ->
      Ok(#(
        " [--target dev|prod]",
        "Compile the project and its dependencies to BEAM.\n\n  --target dev   Development build, including tests (default)\n  --target prod  Production library or application, excluding tests and dev dependencies\n\n",
      ))
    "run", [] ->
      Ok(#(
        " [-- <arguments>...]",
        "Build and execute main(). Arguments after -- go to the program.\n\nExample:\n  pooka run -- --help\n\n",
      ))
    "test", [] ->
      Ok(#(
        " [--verbose|--compact]",
        "Compile and run project tests. Skipped tests are checked but not run.\n\n  --verbose  Show timings, captured output and failure stack traces\n  --compact  Show failures and totals only\n\n",
      ))
    "format", [] ->
      Ok(#(
        " [--check] [<file.pooka>...]",
        "Format source files, or all project sources when no files are given.\n\n  --check  Report formatting differences without writing files\n\nAlias: pooka fmt\n\n",
      ))
    "docs", [] ->
      Ok(#(
        "",
        "Generate public API documentation and configured Markdown pages.\nOutput: build/dev/docs/<package>/index.html\n\n",
      ))
    "add", [] ->
      Ok(#(
        " <package[@version]> [options]",
        "Add a dependency to pooka.toml and resolve the package graph.\n\n  --dev           Add a development dependency\n  --path <path>   Use a local package\n  --git <url>     Use a Git repository\n  --branch <name> Select a Git branch\n  --tag <tag>     Select a Git tag\n  --rev <commit>  Pin a Git revision\n\nExamples:\n  pooka add helper --path ../helper\n  pooka add helper --git https://example.com/helper.git --tag v1.0.0\n\n",
      ))
    "remove", [] ->
      Ok(#(
        " <package>",
        "Remove a dependency from pooka.toml and update the lockfile.\n\n",
      ))
    "deps", [] ->
      Ok(#(
        " <command>",
        "Manage dependencies.\n\nCommands:\n  download  Resolve and download dependencies using existing pins\n  update    Re-resolve dependencies and update pooka.lock\n  list      List locked packages without fetching\n  tree      Show locked dependency edges without fetching\n\nRun pooka deps <command> --help for individual help.\n\n",
      ))
    "deps", ["download"] ->
      Ok(#(
        " download",
        "Resolve and download dependencies, preserving compatible locked pins.\n\n",
      ))
    "deps", ["update"] ->
      Ok(#(
        " update",
        "Re-resolve the full dependency graph and write pooka.lock.\nExplicit Git revision pins remain pinned.\n\n",
      ))
    "deps", ["list"] ->
      Ok(#(
        " list",
        "List all locked packages with versions and local, Git or Hex sources.\nThis command does not fetch packages or rewrite pooka.lock.\n\n",
      ))
    "deps", ["tree"] ->
      Ok(#(
        " tree",
        "Show regular and development dependency edges from pooka.lock.\nRepeated packages are marked (*); missing entries are marked (not locked).\nThis command does not fetch packages or rewrite pooka.lock.\n\n",
      ))
    "export", [] ->
      Ok(#(
        " <escript|shipment|release>",
        "Export a production build.\n\nCommands:\n  escript   Create a standalone executable in build/<package>\n  shipment  Create a production shipment in build/shipment\n  release   Create an OTP release in build/release\n\n",
      ))
    "export", ["escript"] ->
      Ok(#(" escript", "Create a standalone executable in build/<package>.\n\n"))
    "export", ["shipment"] ->
      Ok(#(" shipment", "Package a production shipment in build/shipment.\n\n"))
    "export", ["release"] ->
      Ok(#(
        " release [--include-erts|--no-erts]",
        "Create an OTP release in build/release.\n\n  --include-erts  Bundle the Erlang runtime\n  --no-erts       Use the target system runtime (default)\n\n",
      ))
    "publish", [] ->
      Ok(#(
        " [options]",
        "Prepare and publish a portable package and its documentation to Hex.\n\n  --dry-run    Build archives and preview files without uploading\n  --yes        Confirm publication without a prompt\n  --replace    Replace a release within Hex's replacement window\n  --docs-only  Upload documentation without publishing the package again\n\nCredentials: HEX_API_KEY or HEXPM_API_KEY; set HEX_OTP if Hex requests 2FA.\n\n",
      ))
    "clean", [] -> Ok(#("", "Remove project build artifacts.\n\n"))
    _, _ -> Error(Nil)
  }
}
