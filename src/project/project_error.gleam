//// A configuration failure deserves an address and a useful sentence.
////
//// Represent project and filesystem problems independently of their rendered
//// output. Convert them into stable diagnostics with the manifest or path that
//// caused the failure.
////
//// ```text
//// missing name field -> project.manifest_missing_field
//// ```

// SPDX-License-Identifier: Apache-2.0

import diagnostics/diagnostic.{type Diagnostic}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/project_name.{type NameProblem}
import simplifile

pub type Action {
  CreatingDirectory
  WritingFile
  ReadingFile
  ReadingDirectory
  InspectingPath
  FindingWorkingDirectory
  RemovingBuildArtifacts
}

pub type ProjectError {
  DependencyProblem(manifest: String, detail: String)

  MissingProjectName

  UnexpectedArguments(command: String, arguments: List(String))

  InvalidProjectName(name: String, problem: NameProblem)

  ProjectPathExists(path: String)

  FileSystemFailed(action: Action, path: String, reason: simplifile.FileError)

  NotInProject(start: String)

  ManifestSyntax(path: String, detail: String)

  ManifestMissingField(path: String, field: String)

  ManifestFieldType(path: String, field: String, expected: String)
  ManifestInvalidField(path: String, field: String, detail: String)

  ManifestInvalidName(path: String, name: String, problem: NameProblem)

  CannotApplyFixes(path: String, reason: String)

  NoSourceDirectory(root: String)

  InvalidNativeComponent(path: String, component: String, problem: String)
}

pub fn id(error: ProjectError) -> String {
  case error {
    DependencyProblem(..) -> "project.dependency"
    MissingProjectName -> "project.missing_name"
    UnexpectedArguments(..) -> "project.unexpected_arguments"
    InvalidProjectName(..) -> "project.invalid_name"
    ProjectPathExists(..) -> "project.path_exists"
    FileSystemFailed(..) -> "project.file_system"
    NotInProject(..) -> "project.not_in_project"
    ManifestSyntax(..) -> "project.manifest_syntax"
    ManifestMissingField(..) -> "project.manifest_missing_field"
    ManifestFieldType(..) -> "project.manifest_field_type"
    ManifestInvalidName(..) -> "project.manifest_invalid_name"
    ManifestInvalidField(..) -> "project.manifest_invalid_field"
    NoSourceDirectory(..) -> "project.no_source_directory"
    CannotApplyFixes(..) -> "project.cannot_apply_fixes"
    InvalidNativeComponent(..) -> "project.native_component"
  }
}

pub fn to_diagnostic(error: ProjectError) -> Diagnostic {
  let base = fn(title) { diagnostic.error(id(error), title) }
  case error {
    DependencyProblem(manifest, detail) ->
      base("invalid dependency graph")
      |> diagnostic.conclusion(detail)
      |> diagnostic.note("Declared in `" <> manifest <> "`.")
    MissingProjectName ->
      base("missing project name")
      |> diagnostic.conclusion("`pooka new` needs a name for the project.")
      |> diagnostic.help(
        "Run `pooka new my_app` to create a project named `my_app`.",
      )

    UnexpectedArguments(command:, arguments:) ->
      base("unexpected arguments")
      |> diagnostic.conclusion(
        "`pooka "
        <> command
        <> "` does not accept "
        <> string.join(
          list.map(arguments, fn(argument) { "`" <> argument <> "`" }),
          ", ",
        )
        <> ".",
      )
      |> diagnostic.help("Run `pooka --help` to see how commands are used.")

    InvalidProjectName(name:, problem:) -> {
      let described =
        base("invalid project name")
        |> diagnostic.conclusion(describe_name_problem(name, problem))
        |> diagnostic.note(
          "Project names use `snake_case`: lower-case letters, digits and underscores, starting with a letter.",
        )
      case project_name.suggest(name) {
        Some(suggestion) ->
          diagnostic.help(described, "Try `pooka new " <> suggestion <> "`.")
        None -> described
      }
    }

    ProjectPathExists(path:) ->
      base("project already exists")
      |> diagnostic.conclusion("`" <> path <> "` already exists.")
      |> diagnostic.help(
        "Choose another name, or remove the existing entry first.",
      )

    FileSystemFailed(action:, path:, reason:) ->
      base("file system error")
      |> diagnostic.conclusion(
        "Pooka could not " <> describe_action(action) <> " `" <> path <> "`.",
      )
      |> diagnostic.note(
        "The operating system reported: "
        <> simplifile.describe_error(reason)
        <> ".",
      )

    NotInProject(start:) ->
      base("not inside a Pooka project")
      |> diagnostic.conclusion(
        "No `pooka.toml` was found in `"
        <> start
        <> "` or any of its parent directories.",
      )
      |> diagnostic.help("Create a project with `pooka new my_app`.")

    ManifestSyntax(path:, detail:) ->
      base("invalid pooka.toml")
      |> diagnostic.conclusion(
        "`" <> path <> "` is not valid TOML: " <> detail <> ".",
      )

    ManifestMissingField(path:, field:) ->
      base("incomplete pooka.toml")
      |> diagnostic.conclusion(
        "`" <> path <> "` has no `" <> field <> "` field.",
      )
      |> diagnostic.help("Add a line such as `" <> field <> " = \"...\"`.")

    InvalidNativeComponent(path:, component:, problem:) ->
      base("invalid native component")
      |> diagnostic.conclusion(case component {
        "" -> problem
        _ -> "Native component `" <> component <> "`: " <> problem
      })
      |> diagnostic.note("Declared in `" <> path <> "`.")

    ManifestFieldType(path:, field:, expected:) ->
      base("invalid pooka.toml")
      |> diagnostic.conclusion(
        "The `"
        <> field
        <> "` field of `"
        <> path
        <> "` must be a "
        <> expected
        <> ".",
      )

    ManifestInvalidField(path:, field:, detail:) ->
      base("invalid pooka.toml")
      |> diagnostic.conclusion("`" <> field <> "` " <> detail <> ".")
      |> diagnostic.note("Declared in `" <> path <> "`.")

    ManifestInvalidName(path:, name:, problem:) ->
      base("invalid project name")
      |> diagnostic.conclusion(
        "The `name` in `"
        <> path
        <> "` is invalid: "
        <> describe_name_problem(name, problem),
      )

    CannotApplyFixes(path:, reason:) ->
      base("could not apply automatic fixes")
      |> diagnostic.conclusion("`" <> path <> "`: " <> reason <> ".")
      |> diagnostic.help("Review the source and run `pooka check --fix` again.")

    NoSourceDirectory(root:) ->
      base("missing source directory")
      |> diagnostic.conclusion(
        "The project in `" <> root <> "` has no `src` directory.",
      )
      |> diagnostic.help(
        "Production source belongs in `src/`, for example `src/main.pooka`.",
      )
  }
}

fn describe_action(action: Action) -> String {
  case action {
    CreatingDirectory -> "create the directory"
    WritingFile -> "write the file"
    ReadingFile -> "read the file"
    ReadingDirectory -> "read the directory"
    InspectingPath -> "inspect"
    FindingWorkingDirectory -> "find the working directory"
    RemovingBuildArtifacts -> "remove build artifacts from"
  }
}

pub fn describe_name_problem(name: String, problem: NameProblem) -> String {
  case problem {
    project_name.EmptyName -> "The project name is empty."
    project_name.BadFirstCharacter(character) ->
      "`"
      <> name
      <> "` starts with `"
      <> character
      <> "`, but a project name must start with a lower-case letter."
    project_name.BadCharacter(character, index) ->
      "`"
      <> name
      <> "` contains `"
      <> character
      <> "` at position "
      <> int.to_string(index + 1)
      <> "."
    project_name.TooLong(length) ->
      "`"
      <> name
      <> "` is "
      <> int.to_string(length)
      <> " characters long; the limit is "
      <> int.to_string(project_name.max_length)
      <> "."
    project_name.Reserved(word) -> "`" <> word <> "` is a reserved word."
  }
}
