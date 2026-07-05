//// Add a neighbour to the manifest.
////
//// Parse the requested dependency source and development flag, edit pooka.toml
//// and resolve the resulting graph.
////
//// ```sh
//// pooka add helper --path ../helper
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/new
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/dependency as d
import project/edit
import project/project_error
import project/semver
import tools/logger

pub const info = Info("add", "<package[@version]> [options]", "Add a dependency")

pub fn run(arguments: List(String), env: Environment) -> Outcome {
  case parse(arguments) {
    Error(message) ->
      new.failure(project_error.DependencyProblem("pooka.toml", message), env)
    Ok(change) ->
      case edit.apply(env.working_directory, change) {
        Ok(name) -> Outcome("", logger.activity("Added", name, env.stderr), 0)
        Error(error) -> new.failure(error, env)
      }
  }
}

pub fn parse(arguments: List(String)) -> Result(edit.Change, String) {
  use #(first, rest) <- result.try(case arguments {
    [name, ..rest] if name != "" -> Ok(#(name, rest))
    _ -> Error("Supply a package name. Run `pooka add --help` for usage.")
  })
  let #(name, requirement) = case string.split_once(first, "@") {
    Ok(pair) -> pair
    Error(_) -> #(first, "*")
  }
  use options <- result.try(options(rest, False, None, None))
  let #(dev, source, reference) = options
  use dep <- result.try(case source, reference, requirement {
    Some(#("path", path)), None, "*" -> Ok(d.Local(name, path))
    Some(#("git", url)), reference, "*" ->
      Ok(
        d.Git(name, url, case reference {
          Some(ref) -> ref
          None -> "head"
        }),
      )
    None, None, requirement -> {
      let requirement = case string.split(requirement, ".") {
        [major] if requirement != "*" ->
          case gleam_int.parse(major) {
            Ok(n) ->
              ">= "
              <> major
              <> ".0.0 and < "
              <> gleam_int.to_string(n + 1)
              <> ".0.0"
            Error(_) -> requirement
          }
        _ ->
          case semver.parse(requirement) {
            Ok(_) -> "~> " <> requirement
            Error(_) -> requirement
          }
      }
      case semver.valid_requirement(requirement) {
        True -> Ok(d.Hex(name, requirement, False))
        False -> Error("Invalid Hex version requirement.")
      }
    }
    _, _, _ ->
      Error(
        "A version is for Hex; branch/tag/rev options require exactly one Git source.",
      )
  })
  Ok(edit.Add(dep, dev))
}

import gleam/int as gleam_int

fn options(
  args: List(String),
  dev: Bool,
  source: Option(#(String, String)),
  reference: Option(String),
) -> Result(#(Bool, Option(#(String, String)), Option(String)), String) {
  case args {
    [] -> Ok(#(dev, source, reference))
    ["--dev", ..rest] if !dev -> options(rest, True, source, reference)
    [key, value, ..rest] if value != "" ->
      case key, source, reference {
        "--path", None, _ ->
          options(rest, dev, Some(#("path", value)), reference)
        "--git", None, _ -> options(rest, dev, Some(#("git", value)), reference)
        "--branch", _, None ->
          options(rest, dev, source, Some("branch:" <> value))
        "--tag", _, None -> options(rest, dev, source, Some("tag:" <> value))
        "--rev", _, None -> options(rest, dev, source, Some("rev:" <> value))
        _, _, _ -> Error("Unknown or repeated dependency option.")
      }
    _ -> Error("Incomplete or repeated dependency option.")
  }
}
