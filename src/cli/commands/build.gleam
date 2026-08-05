//// Bring the package to the compiler workshop.
////
//// Build checked source and dependencies, then render compilation results and
//// warnings through the command environment.
////
//// ```sh
//// pooka build
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import builder/check
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/new
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/string
import project/project_error
import tools/logger
import utilities/text
import utilities/timer

pub const info =
  Info(
    name: "build",
    arguments: "[--target dev|prod]",
    summary: "Type check and compile the project to BEAM",
  )

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments {
    [] | ["--target", "dev"] | ["--target", "prod"] -> {
      let started = environment.clock()
      let result = case arguments {
        ["--target", "prod"] ->
          build.build_production(environment.working_directory)
        _ -> build.build(environment.working_directory)
      }
      case result {
        Error(error) -> failure(error, environment)
        Ok(report) ->
          Outcome(
            stdout: "",
            stderr: compiled(report, started, environment),
            status: 0,
          )
      }
    }
    _ ->
      new.failure(
        project_error.UnexpectedArguments("build", arguments),
        environment,
      )
  }
}

pub fn compiled(
  report: build.Report,
  started: Int,
  environment: Environment,
) -> String {
  let count =
    list.length(report.compiled) + list.length(report.compiled_foreign)
  report.compiled_packages
  |> list.map(fn(name) {
    logger.activity("Compiling", name, environment.stderr)
  })
  |> string.concat
  <> render.render_all(
    report.diagnostics,
    check.sources(report.checked),
    environment.stderr,
    diagnostic.Quiet,
  )
  <> logger.activity(
    "Compiled",
    case count {
      0 -> "in "
      _ -> text.counted(count, "module") <> " in "
    }
      <> timer.format(environment.clock() - started),
    environment.stderr,
  )
}

pub fn failure(error: build.Failure, environment: Environment) -> Outcome {
  let sources = case error.checked {
    Ok(checked) -> check.sources(checked)
    Error(Nil) -> dict.new()
  }
  command.failure(render.render_all(
    error.diagnostics,
    sources,
    environment.stderr,
    diagnostic.Quiet,
  ))
}
