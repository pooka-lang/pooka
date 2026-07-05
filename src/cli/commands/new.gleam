//// Prepare a clean desk for the first program.
////
//// Validate a package name, create the template files and explain filesystem
//// failures without leaving an unlabelled exception.
////
//// ```sh
//// pooka new hello
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Environment, type Outcome, Info}
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/string
import project/project
import project/project_error.{type ProjectError}
import utilities/colour

pub const info =
  Info(name: "new", arguments: "<name>", summary: "Create a new Pooka project")

/// Validate the requested package name and create the shared project template,
/// including pooka.toml and a starter spec.
///
/// ```sh
/// pooka new hello
/// ```
pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments {
    [] -> failure(project_error.MissingProjectName, environment)
    [name] ->
      case project.create(environment.working_directory, name) {
        Ok(created) -> command.success(report(name, created, environment))
        Error(error) -> failure(error, environment)
      }
    [_, ..extra] ->
      failure(project_error.UnexpectedArguments("new", extra), environment)
  }
}

pub fn failure(error: ProjectError, environment: Environment) -> Outcome {
  project_error.to_diagnostic(error)
  |> render.render(dict.new(), environment.stderr)
  |> command.failure
}

fn report(
  name: String,
  created: project.Created,
  environment: Environment,
) -> String {
  let verb =
    colour.paint("create", colour.bold_lantern_orange, environment.stdout)
  let files =
    created.files
    |> list.map(fn(file) { "  " <> verb <> " " <> name <> "/" <> file })
    |> string.join("\n")
  files
  <> "\n\nYour Pooka project "
  <> colour.paint(name, colour.bold_lantern_orange, environment.stdout)
  <> " has been created.\nRun it with:\n\n    cd "
  <> name
  <> "\n    pooka run\n"
}
