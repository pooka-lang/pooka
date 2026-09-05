//// Straighten the source pages gently.
////
//// Format selected source files or check their canonical layout. A token-changing
//// result is refused rather than silently written.
////
//// ```sh
//// pooka format --check
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/new
import compiler/analysis/test_location
import compiler/lexer/lex_error
import compiler/lexer/lexer
import compiler/parser/parse_error
import compiler/parser/parser
import diagnostics/diagnostic.{type Diagnostic}
import diagnostics/render
import filepath
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import project/project
import project/project_error.{type ProjectError}
import simplifile
import tools/formatter
import tools/logger
import utilities/text
import utilities/timer

pub const info =
  Info(
    name: "format",
    arguments: "[--check] [<file.pooka>...]",
    summary: "Format Pooka source code",
  )

type Mode {
  Write
  Check
}

type Target {
  Target(path: String, shown: String)
}

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  let mode = case list.contains(arguments, "--check") {
    True -> Check
    False -> Write
  }
  let files = list.filter(arguments, fn(argument) { argument != "--check" })
  case list.filter(files, fn(file) { !string.ends_with(file, ".pooka") }) {
    [_, ..] as unexpected ->
      new.failure(
        project_error.UnexpectedArguments("format", unexpected),
        environment,
      )
    [] ->
      case targets(files, environment) {
        Error(error) -> new.failure(error, environment)
        Ok(targets) ->
          format_all(targets, mode, environment, environment.clock())
      }
  }
}

fn targets(
  files: List(String),
  environment: Environment,
) -> Result(List(Target), ProjectError) {
  case files {
    [_, ..] ->
      Ok(
        list.map(files, fn(file) {
          Target(filepath.join(environment.working_directory, file), file)
        }),
      )
    [] -> {
      use root <- result.try(project.find_root(environment.working_directory))
      use loaded <- result.try(project.load(root))
      use sources <- result.try(project.source_files(loaded))
      Ok(
        list.map(sources, fn(source) {
          Target(filepath.join(root, source.path), source.path)
        }),
      )
    }
  }
}

type FileOutcome {
  Unchanged
  Changed(target: Target, formatted: String)
  Invalid(target: Target, source: String, diagnostics: List(Diagnostic))
}

fn format_all(
  targets: List(Target),
  mode: Mode,
  environment: Environment,
  started: Int,
) -> Outcome {
  let results = list.map(targets, format_one)
  let invalid =
    list.filter_map(results, fn(result) {
      case result {
        Invalid(target:, source:, diagnostics:) ->
          Ok(#(target, source, diagnostics))
        _ -> Error(Nil)
      }
    })
  let changed =
    list.filter_map(results, fn(result) {
      case result {
        Changed(target:, formatted:) -> Ok(#(target, formatted))
        _ -> Error(Nil)
      }
    })
  let problems = case invalid {
    [] -> ""
    _ ->
      render.render_all(
        list.flat_map(invalid, fn(entry) { entry.2 }),
        dict.from_list(
          list.map(invalid, fn(entry) { #({ entry.0 }.shown, entry.1) }),
        ),
        environment.stderr,
        diagnostic.Quiet,
      )
  }
  case mode {
    Check ->
      case changed, invalid {
        [], [] -> command.success("")
        _, _ -> command.failure(problems <> unformatted(changed, environment))
      }
    Write -> {
      let written =
        list.try_each(changed, fn(entry) {
          simplifile.write({ entry.0 }.path, entry.1)
          |> result.map_error(project_error.FileSystemFailed(
            project_error.WritingFile,
            { entry.0 }.path,
            _,
          ))
        })
      case written, invalid {
        Error(error), _ -> new.failure(error, environment)
        Ok(Nil), [] ->
          Outcome(
            stdout: "",
            stderr: summary(list.length(changed), environment, started),
            status: 0,
          )
        Ok(Nil), [_, ..] ->
          Outcome(
            stdout: "",
            stderr: problems
              <> summary(list.length(changed), environment, started),
            status: 1,
          )
      }
    }
  }
}

fn format_one(target: Target) -> FileOutcome {
  case simplifile.read(target.path) {
    Error(error) ->
      Invalid(target, "", [
        project_error.to_diagnostic(project_error.FileSystemFailed(
          project_error.ReadingFile,
          target.shown,
          error,
        )),
      ])
    Ok(source) ->
      case formatter.format(source) {
        Ok(formatted) -> {
          let parsed = parser.parse(lexer.lex(source).tokens)
          case test_location.check(parsed.module, target.shown) {
            [_, ..] as diagnostics -> Invalid(target, source, diagnostics)
            [] if formatted == source -> Unchanged
            [] -> Changed(target, formatted)
          }
        }
        Error(formatter.LexErrors(errors)) ->
          Invalid(
            target,
            source,
            list.map(errors, lex_error.to_diagnostic(_, target.shown)),
          )
        Error(formatter.SyntaxErrors(errors)) ->
          Invalid(
            target,
            source,
            list.map(errors, parse_error.to_diagnostic(_, target.shown)),
          )
        Error(formatter.ChangedMeaning) ->
          Invalid(target, source, [
            diagnostic.error(
              "format.internal_error",
              "internal formatter error",
            )
            |> diagnostic.conclusion(
              "Formatting `"
              <> target.shown
              <> "` would have changed its meaning, so the file was left unchanged.",
            )
            |> diagnostic.note(
              "This is a bug in the Pooka formatter, not in your program. Please report it.",
            ),
          ])
      }
  }
}

fn summary(count: Int, environment: Environment, started: Int) -> String {
  logger.success(
    "Formatted",
    text.counted(count, "file")
      <> " in "
      <> timer.format(environment.clock() - started),
    environment.stderr,
  )
}

fn unformatted(
  changed: List(#(Target, String)),
  environment: Environment,
) -> String {
  case changed {
    [] -> ""
    _ ->
      diagnostic.error("format.unformatted", "files are not formatted")
      |> diagnostic.conclusion(
        "These files are not in the canonical format:\n\n"
        <> string.join(
          list.map(changed, fn(entry) { "    " <> { entry.0 }.shown }),
          "\n",
        ),
      )
      |> diagnostic.help("Run `pooka format` to format them.")
      |> render.render(dict.new(), environment.stderr)
  }
}
