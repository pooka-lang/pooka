//// Record where a package says its neighbours live.
////
//// Decode local, Git and Hex dependency declarations and normalize repository
//// identities. Source selection is configuration here; solving the package graph
//// happens later.
////
//// ```text
//// helper = { path = "../helper" }
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import project/project_error
import project/project_name
import project/semver
import tom

pub type Dependency {
  Local(name: String, path: String)
  Git(name: String, url: String, reference: String)
  Hex(name: String, requirement: String, optional: Bool)
}

pub fn parse(
  config: Dict(String, tom.Toml),
  key: String,
  manifest: String,
) -> Result(List(Dependency), project_error.ProjectError) {
  let invalid = fn(detail) { project_error.DependencyProblem(manifest, detail) }
  use values <- result.try(case dict.get(config, key) {
    Error(_) -> Ok(dict.new())
    Ok(tom.Table(values)) | Ok(tom.InlineTable(values)) -> Ok(values)
    Ok(_) -> Error(invalid("`" <> key <> "` must be a table."))
  })
  values
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.try_map(fn(entry) {
    let #(name, value) = entry
    use Nil <- result.try(
      project_name.validate(name)
      |> result.map_error(fn(_) {
        invalid("Invalid dependency name `" <> name <> "`.")
      }),
    )
    case value {
      tom.String(requirement) ->
        case semver.valid_requirement(requirement) {
          True -> Ok(Hex(name, requirement, False))
          False ->
            Error(invalid(
              "Invalid Hex version requirement for `" <> name <> "`.",
            ))
        }
      tom.Table(fields) | tom.InlineTable(fields) ->
        parse_source(name, fields, manifest)
      _ -> Error(invalid("Invalid dependency source for `" <> name <> "`."))
    }
  })
}

fn parse_source(
  name: String,
  fields: Dict(String, tom.Toml),
  manifest: String,
) -> Result(Dependency, project_error.ProjectError) {
  let invalid = fn() {
    project_error.DependencyProblem(
      manifest,
      "Dependency `"
        <> name
        <> "` must select a path, Git URL (optionally one branch/tag/rev), or Hex version requirement.",
    )
  }
  case dict.get(fields, "version") {
    Ok(tom.String(requirement)) if requirement != "" -> {
      use Nil <- result.try(case semver.valid_requirement(requirement) {
        True -> Ok(Nil)
        False -> Error(invalid())
      })
      use optional <- result.try(case dict.get(fields, "optional") {
        Error(_) -> Ok(False)
        Ok(tom.Bool(value)) -> Ok(value)
        _ -> Error(invalid())
      })
      case
        list.all(dict.keys(fields), fn(key) {
          list.contains(["version", "optional"], key)
        })
      {
        True -> Ok(Hex(name, requirement, optional))
        False -> Error(invalid())
      }
    }
    _ -> parse_path_or_git(name, fields, manifest)
  }
}

fn parse_path_or_git(
  name: String,
  fields: Dict(String, tom.Toml),
  manifest: String,
) -> Result(Dependency, project_error.ProjectError) {
  let invalid = fn() {
    project_error.DependencyProblem(
      manifest,
      "Invalid dependency source for `" <> name <> "`.",
    )
  }
  case dict.to_list(fields) {
    [#("path", tom.String(path))] if path != "" -> Ok(Local(name, path))
    _ -> {
      use url <- result.try(
        tom.get_string(fields, ["git"]) |> result.map_error(fn(_) { invalid() }),
      )
      use Nil <- result.try(
        case
          url != ""
          && list.all(dict.keys(fields), fn(key) {
            list.contains(["git", "branch", "tag", "rev"], key)
          })
        {
          True -> Ok(Nil)
          False -> Error(invalid())
        },
      )
      use refs <- result.try(
        list.try_fold(["branch", "tag", "rev"], [], fn(refs, key) {
          case dict.get(fields, key) {
            Error(_) -> Ok(refs)
            Ok(tom.String(value)) if value != "" ->
              Ok([key <> ":" <> value, ..refs])
            _ -> Error(invalid())
          }
        }),
      )
      case refs {
        [] -> Ok(Git(name, url, "head"))
        [reference] -> Ok(Git(name, url, reference))
        _ -> Error(invalid())
      }
    }
  }
}

pub type Origin {
  LocalOrigin
  GitOrigin(url: String, reference: String, revision: String)
  HexOrigin(checksum: String)
}

pub type Kind {
  Pooka
  Beam(application: String, tools: List(String))
}

@external(erlang, "pooka_package_ffi", "repository_identity")
pub fn repository_identity(url: String) -> String
