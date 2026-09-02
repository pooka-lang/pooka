//// Open the reading room.
////
//// Generate public API pages and report their destination. Documentation failures
//// use the same project diagnostic channel as other commands.
////
//// ```sh
//// pooka docs
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/check
import builder/docs
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/build as build_command
import cli/commands/new
import diagnostics/diagnostic
import diagnostics/render
import project/project_error
import tools/logger
import utilities/text
import utilities/timer

pub const info =
  Info(
    name: "docs",
    arguments: "",
    summary: "Generate documentation for the project",
  )

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments {
    [] -> {
      let started = environment.clock()
      case docs.generate(environment.working_directory) {
        Error(error) -> build_command.failure(error, environment)
        Ok(report) ->
          Outcome(
            "Documentation written to build/dev/docs/"
              <> report.checked.project.name
              <> "/index.html\n",
            logger.activity(
              "Generating",
              report.checked.project.name <> " documentation",
              environment.stderr,
            )
              <> render.render_all(
              report.diagnostics,
              check.sources(report.checked),
              environment.stderr,
              diagnostic.Quiet,
            )
              <> logger.activity(
              "Generated",
              text.counted(report.modules, "module")
                <> " in "
                <> timer.format(environment.clock() - started),
              environment.stderr,
            ),
            0,
          )
      }
    }
    _ ->
      new.failure(
        project_error.UnexpectedArguments("docs", arguments),
        environment,
      )
  }
}
