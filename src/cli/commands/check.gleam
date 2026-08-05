//// Read the program without firing the BEAM kiln.
////
//// Run project analysis and inference, optionally emitting JSON or applying safe
//// fixes. Keep checking failures separate from compilation output.
////
//// ```sh
//// pooka check --json
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/check
import builder/fix
import builder/infer
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/new
import diagnostics/diagnostic
import diagnostics/json
import diagnostics/render
import gleam/list
import project/project_error
import tools/logger
import utilities/text
import utilities/timer

pub const info =
  Info(
    name: "check",
    arguments: "[--verbose] [--json] [--fix]",
    summary: "Check the project for errors",
  )

type OutputFormat {
  Terminal
  Json
}

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  let verbosity = case list.contains(arguments, "--verbose") {
    True -> diagnostic.Verbose
    False -> diagnostic.Quiet
  }

  let unexpected =
    list.filter(arguments, fn(argument) {
      argument != "--verbose" && argument != "--json" && argument != "--fix"
    })
  let format = case list.contains(arguments, "--json") {
    True -> Json
    False -> Terminal
  }
  case unexpected {
    [] -> {
      let started = environment.clock()
      let checked = check.check_project(environment.working_directory)
      let checked = case checked, list.contains(arguments, "--fix") {
        Ok(report), True -> fix.apply(report)
        _, _ -> checked
      }
      report(checked, environment, verbosity, format, started)
    }
    _ ->
      failure(
        project_error.UnexpectedArguments("check", unexpected),
        environment,
        format,
        verbosity,
      )
  }
}

fn failure(
  error: project_error.ProjectError,
  environment: Environment,
  format: OutputFormat,
  verbosity: diagnostic.Verbosity,
) -> Outcome {
  case format {
    Json ->
      Outcome(
        stdout: json.render([project_error.to_diagnostic(error)], verbosity)
          <> "\n",
        stderr: "",
        status: 1,
      )
    Terminal -> new.failure(error, environment)
  }
}

fn report(
  checked: Result(check.Report, project_error.ProjectError),
  environment: Environment,
  verbosity: diagnostic.Verbosity,
  format: OutputFormat,
  started: Int,
) -> Outcome {
  case checked {
    Error(error) -> failure(error, environment, format, verbosity)
    Ok(report) -> {
      let diagnostics = infer.check_diagnostics(report)
      case format {
        Json ->
          Outcome(
            stdout: json.render(diagnostics, verbosity) <> "\n",
            stderr: "",
            status: case diagnostic.has_errors(diagnostics) {
              True -> 1
              False -> 0
            },
          )
        Terminal -> {
          let rendered =
            render.render_all(
              diagnostics,
              check.sources(report),
              environment.stderr,
              verbosity,
            )
          let checking =
            logger.activity("Checking", report.project.name, environment.stderr)
          case diagnostic.has_errors(diagnostics) {
            True -> command.failure(checking <> rendered)
            False ->
              Outcome(
                stdout: "",
                stderr: checking
                  <> rendered
                  <> logger.activity(
                  "Checked",
                  text.counted(list.length(report.files), "file")
                    <> " in "
                    <> timer.format(environment.clock() - started),
                  environment.stderr,
                ),
                status: 0,
              )
          }
        }
      }
    }
  }
}
