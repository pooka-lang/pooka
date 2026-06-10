//// Change the manifest with a small, steady hand.
////
//// Rewrite dependency declarations while preserving unrelated TOML content.
//// Validate the edited configuration before replacing the original file.
////
//// ```text
//// pooka add helper --path ../helper -> updated [dependencies]
//// ```

// SPDX-License-Identifier: Apache-2.0

import filepath
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/dependency as d
import project/hex
import project/lockfile
import project/package
import project/project
import project/project_error.{type ProjectError, DependencyProblem}
import project/project_name
import simplifile
import tom

pub type Change {
  Add(dependency: d.Dependency, development: Bool)
  Remove(name: String)
}

pub fn apply(
  directory: String,
  change: Change,
) -> Result(String, ProjectError) {
  use root <- result.try(project.find_root(directory))
  let path = filepath.join(root, "pooka.toml")
  use old <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(e) {
      DependencyProblem(path, simplifile.describe_error(e))
    }),
  )
  use loaded <- result.try(project.parse_manifest(old, path, root))
  let name = case change {
    Add(dep, _) -> dep.name
    Remove(name) -> name
  }
  use Nil <- result.try(
    project_name.validate(name)
    |> result.map_error(fn(_) {
      DependencyProblem(path, "Invalid dependency name `" <> name <> "`.")
    }),
  )
  use Nil <- result.try(case change {
    Remove(_) ->
      case
        list.any(
          list.append(loaded.dependencies, loaded.dev_dependencies),
          fn(dep) { dep.name == name },
        )
      {
        True -> Ok(Nil)
        False ->
          Error(DependencyProblem(
            path,
            "No dependency named `" <> name <> "` is declared.",
          ))
      }
    _ -> Ok(Nil)
  })
  let text =
    rewrite(old, name, case change {
      Add(dep, dev) -> Some(#(dep, dev))
      Remove(_) -> None
    })
  use config <- result.try(project.parse_manifest(text, path, root))
  use graph <- result.try(
    package.resolve_selecting(config, True, False, hex.fetch, [name]),
  )

  let text = case change {
    Add(d.Hex(_, "*", _), dev) ->
      case list.find(graph.packages, fn(p) { p.name == name }) {
        Ok(selected) ->
          rewrite(
            old,
            name,
            Some(#(d.Hex(name, "~> " <> selected.version, False), dev)),
          )
        Error(_) -> text
      }
    _ -> text
  }
  use config <- result.try(project.parse_manifest(text, path, root))
  use Nil <- result.try(
    atomic(path, text) |> result.map_error(DependencyProblem(path, _)),
  )
  case lockfile.write(config, graph.packages) {
    Ok(Nil) -> Ok(name)
    Error(error) -> {
      let _ = atomic(path, old)
      Error(error)
    }
  }
}

/// Produce edited manifest text while preserving unrelated tables and comments.
///
/// ```text
/// add [dependencies].helper; retain [tools.example] exactly
/// ```
pub fn rewrite(
  text: String,
  name: String,
  value: Option(#(d.Dependency, Bool)),
) -> String {
  let lines = strip(string.split(text, "\n"), [], name, [])
  case value {
    None -> string.join(lines, "\n")
    Some(#(dep, dev)) -> {
      let section = case dev {
        True ->
          case
            list.any(lines, fn(line) {
              case header(line) {
                Some(["dev_dependencies", ..]) -> True
                _ -> False
              }
            })
          {
            True -> "dev_dependencies"
            False -> "dev-dependencies"
          }
        False -> "dependencies"
      }
      insert(lines, section, dep.name <> " = " <> declaration(dep), False, [])
      |> string.join("\n")
    }
  }
}

fn strip(
  lines: List(String),
  section: List(String),
  name: String,
  found: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(found)
    [line, ..rest] ->
      case header(line) {
        Some(next) ->
          case next {
            ["dependencies", key]
              | ["dev-dependencies", key]
              | ["dev_dependencies", key]
              if key == name
            -> strip(rest, next, name, found)
            _ -> strip(rest, next, name, [line, ..found])
          }
        None ->
          case section {
            ["dependencies", key]
              | ["dev-dependencies", key]
              | ["dev_dependencies", key]
              if key == name
            -> strip(rest, section, name, found)
            ["dependencies"] | ["dev-dependencies"] | ["dev_dependencies"] -> {
              case string.split_once(line, "=") {
                Ok(#(key, _)) -> {
                  let #(assignment, rest) = assignment(rest, line, section)
                  case unquote(string.trim(key)) == name {
                    True -> strip(rest, section, name, found)
                    False ->
                      strip(
                        rest,
                        section,
                        name,
                        list.append(list.reverse(assignment), found),
                      )
                  }
                }
                Error(_) -> strip(rest, section, name, [line, ..found])
              }
            }
            _ -> strip(rest, section, name, [line, ..found])
          }
      }
  }
}

fn assignment(
  rest: List(String),
  first: String,
  section: List(String),
) -> #(List(String), List(String)) {
  case tom.parse("[" <> string.join(section, ".") <> "]\n" <> first) {
    Ok(_) -> #(string.split(first, "\n"), rest)
    Error(_) ->
      case rest {
        [] -> #(string.split(first, "\n"), [])
        [line, ..rest] -> assignment(rest, first <> "\n" <> line, section)
      }
  }
}

fn insert(
  lines: List(String),
  section: String,
  entry: String,
  done: Bool,
  found: List(String),
) -> List(String) {
  case lines {
    [] ->
      case done {
        True -> list.reverse(found)
        False ->
          list.append(list.reverse(found), [
            "",
            "[" <> section <> "]",
            entry,
            "",
          ])
      }
    [line, ..rest] ->
      case header(line), done {
        Some([key]), False if key == section ->
          insert(rest, section, entry, True, [entry, line, ..found])
        _, _ -> insert(rest, section, entry, done, [line, ..found])
      }
  }
}

fn header(line: String) -> Option(List(String)) {
  case string.trim(line) {
    "[" <> rest ->
      case string.split_once(rest, "]") {
        Ok(#(name, _)) ->
          Some(
            string.split(name, ".")
            |> list.map(fn(p) { string.trim(p) |> unquote }),
          )
        Error(_) -> None
      }
    _ -> None
  }
}

fn unquote(s: String) -> String {
  case s {
    "\"" <> rest | "'" <> rest -> string.drop_end(rest, 1)
    _ -> s
  }
}

fn quote(s: String) {
  json.string(s) |> json.to_string
}

pub fn declaration(dep: d.Dependency) -> String {
  case dep {
    d.Local(_, path) -> "{ path = " <> quote(path) <> " }"
    d.Hex(_, req, False) -> quote(req)
    d.Hex(_, req, True) -> "{ version = " <> quote(req) <> ", optional = true }"
    d.Git(_, url, reference) ->
      "{ git = "
      <> quote(url)
      <> case string.split_once(reference, ":") {
        Ok(#(key, value)) -> ", " <> key <> " = " <> quote(value)
        Error(_) -> ""
      }
      <> " }"
  }
}

@external(erlang, "pooka_package_ffi", "write_atomic")
fn atomic(path: String, text: String) -> Result(Nil, String)
