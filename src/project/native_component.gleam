//// Give every native component a name the loader can recognize.
////
//// Decode native build configuration and validate component names and paths. The
//// module name used by generated wrappers must match the component declaration.
////
//// ```text
//// [native.fast] -> native/fast/ component metadata
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/project_error.{type ProjectError}
import tom

pub type NativeComponent {
  NativeComponent(name: String, build: String, artifact: Option(String))
}

pub fn module(component: String) -> String {
  "pooka_native_" <> component
}

pub fn valid_name(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      string.contains("abcdefghijklmnopqrstuvwxyz", first)
      && list.all(rest, fn(c) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", c)
      })
    [] -> False
  }
}

pub fn parse(
  config: Dict(String, tom.Toml),
  manifest: String,
) -> Result(List(NativeComponent), ProjectError) {
  let invalid = fn(name, problem) {
    project_error.InvalidNativeComponent(manifest, name, problem)
  }
  use tables <- result.try(case dict.get(config, "native") {
    Error(Nil) -> Ok(dict.new())
    Ok(tom.Table(tables)) | Ok(tom.InlineTable(tables)) -> Ok(tables)
    Ok(_) -> Error(invalid("", "`native` must be a table of components."))
  })
  tables
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.try_map(fn(entry) {
    let #(name, value) = entry
    use Nil <- result.try(case valid_name(name) {
      True -> Ok(Nil)
      False ->
        Error(invalid(
          name,
          "Component names are lowercase snake_case and start with a letter.",
        ))
    })
    use fields <- result.try(case value {
      tom.Table(fields) | tom.InlineTable(fields) -> Ok(fields)
      _ ->
        Error(invalid(name, "A component is a table with a `build` command."))
    })
    use build <- result.try(case dict.get(fields, "build") {
      Ok(tom.String(command)) ->
        case string.trim(command) {
          "" -> Error(invalid(name, "`build` must not be empty."))
          _ -> Ok(command)
        }
      Ok(_) -> Error(invalid(name, "`build` must be a string."))
      Error(Nil) ->
        Error(invalid(name, "`build` is required: the command that builds it."))
    })
    use artifact <- result.try(case dict.get(fields, "artifact") {
      Error(Nil) -> Ok(None)
      Ok(tom.String(path)) ->
        case path == "" || string.starts_with(path, "/") {
          True ->
            Error(invalid(
              name,
              "`artifact` must be a path relative to the component's directory.",
            ))
          False -> Ok(Some(path))
        }
      Ok(_) -> Error(invalid(name, "`artifact` must be a string."))
    })
    use Nil <- result.try(
      dict.keys(fields)
      |> list.find(fn(key) { key != "build" && key != "artifact" })
      |> result.map(fn(key) {
        Error(invalid(name, "Unknown field `" <> key <> "`."))
      })
      |> result.unwrap(Ok(Nil)),
    )
    Ok(NativeComponent(name:, build:, artifact:))
  })
}
