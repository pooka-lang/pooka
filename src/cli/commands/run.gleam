//// Start the checked program after the workshop announcement.
////
//// Build the entry module and execute it in a separate VM. Real runs inherit
//// standard streams; captured command environments remain deterministic for
//// tests.
////
//// ```sh
//// pooka run -- argument
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/build as build_command
import cli/commands/new
import compiler/codegen/beam
import gleam/io
import gleam/list
import project/project_error
import tools/logger
import utilities/colour

pub const info =
  Info(
    name: "run",
    arguments: "[-- <arguments>]",
    summary: "Build and execute main()",
  )

/// Build and execute main in a fresh VM, announcing build results before the
/// program speaks. Real runs inherit streams; captured test environments keep
/// returned text.
///
/// ```sh
/// pooka run -- one two
/// ```
pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  let #(own, program) =
    list.split_while(arguments, fn(argument) { argument != "--" })
  case own {
    [] -> {
      let started = environment.clock()
      case build.build(environment.working_directory) {
        Error(error) -> build_command.failure(error, environment)
        Ok(report) -> {
          let compiled = build_command.compiled(report, started, environment)
          let warnings =
            compiled
            <> logger.activity(
              "Running",
              report.checked.project.name <> ".main",
              environment.stderr,
            )
          case report.entry {
            Error(Nil) ->
              command.failure(
                warnings
                <> "error: running requires src/main.pooka to define main().\n",
              )
            Ok(entry) if environment.inherit_stdio -> {
              io.print_error(warnings)
              case
                beam.execute_inherited(
                  report.directory,
                  entry,
                  list.drop(program, 1),
                  environment.stderr == colour.Ansi,
                )
              {
                Ok(status) -> Outcome("", "", status)
                Error(error) -> Outcome("", error, 1)
              }
            }
            Ok(entry) ->
              case
                beam.execute(
                  report.directory,
                  entry,
                  list.drop(program, 1),
                  environment.stderr == colour.Ansi,
                )
              {
                Ok(output) -> Outcome(output, warnings, 0)
                Error(error) -> Outcome("", warnings <> error, 1)
              }
          }
        }
      }
    }
    _ -> new.failure(project_error.UnexpectedArguments("run", own), environment)
  }
}
