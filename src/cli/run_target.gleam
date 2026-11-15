//// A tool can bring its own front door without borrowing the application's.
////
//// Select checked Pooka entry points by module or package name. Package-qualified
//// selectors make an ambiguous shorthand explicit; no module is executed merely
//// because its filename happens to match.
////
//// ```sh
//// pooka run -m tool -- init
//// pooka run -m tool:main -- init
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import compiler/codegen/erlang
import compiler/compiler
import compiler/parser/ast
import filepath
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/package

pub type Target {
  Target(module: String, directory: String, label: String)
}

type Candidate {
  Candidate(owner: String, identity: String, syntax: ast.Module)
}

/// A missing main or an ambiguous selector is a command error, not an undef
/// exception from the new VM. Inspect signatures after the build has checked them.
pub fn select(
  report: build.Report,
  selector: Option(String),
) -> Result(Target, String) {
  let root = report.checked.project.name
  let candidates =
    report.checked.files
    |> list.filter_map(fn(file) {
      use identity <- result.try(compiler.expected_module_path(file.path))
      let #(owner, identity) = package.module_owner(identity, root)
      Ok(Candidate(owner, identity, file.parsed.module))
    })
  let matching =
    list.filter(candidates, fn(candidate) {
      case selector {
        None -> candidate.owner == root && candidate.identity == "main"
        Some(name) -> {
          let qualified = candidate.owner <> ":" <> candidate.identity
          case string.contains(name, ":") {
            True -> name == qualified
            False ->
              name == candidate.owner <> "/" <> candidate.identity
              || {
                name == candidate.identity
                && { name != "main" || candidate.owner == root }
              }
              || { name == candidate.owner && candidate.identity == "main" }
          }
        }
      }
    })
  // A library module may share the package's name without being a front door.
  // Keep it out of the choices before deciding whether the shorthand is ambiguous.
  let runnable = list.filter(matching, has_main)
  let package_entry = case selector {
    Some(name) ->
      list.filter(runnable, fn(candidate) {
        candidate.owner == name && candidate.identity == "main"
      })
    None -> []
  }
  // The documented bare package name means that package's main. Exact owner
  // selectors still allow a caller to choose its same-named executable module.
  let found = case package_entry {
    [] -> runnable
    _ -> package_entry
  }
  case found {
    [] ->
      Error(case selector {
        None -> "running requires src/main.pooka to define main()."
        Some(name) ->
          case matching {
            [] ->
              "No entry module or package matches `"
              <> name
              <> "`. Use -m <module|package>; package:module selects an exact owner."
            _ ->
              "The entry selected by `"
              <> name
              <> "` must define a zero-argument main() function."
          }
      })
    [candidate] ->
      Ok(Target(
        erlang.module_name(candidate.owner, candidate.identity),
        filepath.join(report.layout.target, candidate.owner <> "/ebin"),
        candidate.owner <> "." <> string.replace(candidate.identity, "/", "."),
      ))
    many ->
      Error(
        "The entry-point selector is ambiguous. Choose "
        <> string.join(
          list.map(many, fn(candidate) {
            "`-m " <> candidate.owner <> ":" <> candidate.identity <> "`"
          }),
          " or ",
        )
        <> ".",
      )
  }
}

/// Only a module function with no arguments is an executable entry point.
fn has_main(candidate: Candidate) -> Bool {
  list.any(candidate.syntax.declarations, fn(value) {
    case value {
      ast.FunctionDeclaration(function) ->
        function.name.name == "main" && function.parameters == []
      _ -> False
    }
  })
}
