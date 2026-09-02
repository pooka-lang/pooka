//// Choose a travelling case for the compiled program.
////
//// Dispatch escript, shipment and release exports, keeping their package layouts
//// in the corresponding builders.
////
//// ```sh
//// pooka export escript
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/check
import builder/escript
import builder/release
import builder/shipment
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/build as build_command
import cli/commands/new
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import project/project_error

pub const info =
  Info(
    name: "export",
    arguments: "<escript|shipment|release>",
    summary: "Export an escript, production shipment or OTP release",
  )

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments {
    ["shipment"] ->
      case shipment.export(environment.working_directory) {
        Error(error) -> build_command.failure(error, environment)
        Ok(report) ->
          Outcome(
            "Exported shipment to build/shipment.\n",
            render.render_all(
              report.build.diagnostics,
              check.sources(report.build.checked),
              environment.stderr,
              diagnostic.Quiet,
            ),
            0,
          )
      }
    ["escript"] ->
      case escript.export(environment.working_directory) {
        Error(error) -> build_command.failure(error, environment)
        Ok(report) ->
          Outcome(
            "Exported escript to build/"
              <> report.build.checked.project.name
              <> ".\n",
            render.render_all(
              report.build.diagnostics,
              check.sources(report.build.checked),
              environment.stderr,
              diagnostic.Quiet,
            ),
            0,
          )
      }
    ["release"] | ["release", "--no-erts"] -> release_export(False, environment)
    ["release", "--include-erts"] -> release_export(True, environment)
    [] -> format_failure("missing export format", environment)
    [_] -> format_failure("unknown export format", environment)
    _ ->
      new.failure(
        project_error.UnexpectedArguments("export", arguments),
        environment,
      )
  }
}

fn format_failure(title: String, environment: Environment) -> Outcome {
  diagnostic.error("cli.export_format", title)
  |> diagnostic.conclusion(
    "Use `pooka export escript` or `pooka export shipment` to package a production build.",
  )
  |> render.render(dict.new(), environment.stderr)
  |> command.failure
}

fn release_export(include_erts: Bool, environment: Environment) -> Outcome {
  case release.export(environment.working_directory, include_erts) {
    Error(error) -> build_command.failure(error, environment)
    Ok(report) ->
      Outcome(
        "Exported OTP release to build/release.\n",
        render.render_all(
          report.build.diagnostics,
          check.sources(report.build.checked),
          environment.stderr,
          diagnostic.Quiet,
        ),
        0,
      )
  }
}
