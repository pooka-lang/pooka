//// Clear the generated workbench.
////
//// Remove project build artifacts and return a short command outcome. Source
//// discovery and deletion policy live in the builder.
////
//// ```sh
//// pooka clean
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/clean
import cli/command.{type Environment, type Outcome, Info}
import cli/commands/new
import project/project_error
import utilities/colour

pub const info =
  Info(name: "clean", arguments: "", summary: "Remove build artifacts")

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments {
    [] ->
      case clean.clean_project(environment.working_directory) {
        Ok(Nil) ->
          command.success(
            colour.paint(
              "Cleaned build artifacts.",
              colour.bold_lantern_orange,
              environment.stdout,
            )
            <> "\n",
          )
        Error(error) -> new.failure(error, environment)
      }
    unexpected ->
      new.failure(
        project_error.UnexpectedArguments("clean", unexpected),
        environment,
      )
  }
}
