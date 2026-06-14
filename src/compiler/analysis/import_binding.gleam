//// Imports are introductions, not guesses.
////
//// Validate imported names and aliases against declaration rules. This pass
//// checks how imports bind names; module availability and exported type
//// information are checked elsewhere.
////
//// ```pooka
//// import pooka/list
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import utilities/location

pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  let imported = list.flat_map(module.imports, bindings)
  let declared = list.filter_map(module.declarations, ast.declaration_name)
  let #(_, collisions) =
    list.fold(
      list.append(imported, declared),
      #(dict.new(), []),
      fn(state, name) {
        let #(seen, diagnostics) = state
        case dict.get(seen, name.name) {
          Error(Nil) -> #(dict.insert(seen, name.name, name), diagnostics)
          Ok(first) -> {
            let is_import = list.any(imported, fn(value) { value == first })
            case is_import {
              False -> #(seen, diagnostics)
              True -> {
                let value =
                  diagnostic.error(
                    "analysis.import_collision",
                    "import name collision",
                  )
                  |> diagnostic.primary(
                    location.new(path, name.span),
                    "`" <> name.name <> "` is introduced again here",
                  )
                  |> diagnostic.secondary(
                    location.new(path, first.span),
                    "first imported here",
                  )
                  |> diagnostic.conclusion(
                    "The local name `"
                    <> name.name
                    <> "` is ambiguous in this module.",
                  )
                  |> diagnostic.help(
                    "Give the import a distinct alias with `as`, or remove the conflicting import.",
                  )
                #(seen, [value, ..diagnostics])
              }
            }
          }
        }
      },
    )
  let private =
    list.flat_map(module.imports, fn(imported) {
      imported.items
      |> list.filter_map(fn(item) {
        case string.starts_with(item.name.name, "_") {
          False -> Error(Nil)
          True ->
            Ok(
              diagnostic.error(
                "analysis.private_import",
                "private declaration imported",
              )
              |> diagnostic.primary(
                location.new(path, item.name.span),
                "`" <> item.name.name <> "` is private to its defining module",
              )
              |> diagnostic.conclusion(
                "Declarations beginning with `_` cannot be imported, including under a public alias.",
              ),
            )
        }
      })
    })
  list.append(list.reverse(collisions), private) |> diagnostic.sort
}

fn bindings(imported: ast.Import) -> List(ast.Name) {
  let qualifier = case imported.alias {
    Some(name) -> [name]
    None ->
      case list.last(imported.module.segments) {
        Ok(name) -> [ast.Name(name, imported.module.span)]
        Error(Nil) -> []
      }
  }
  list.append(
    qualifier,
    list.map(imported.items, fn(item) {
      case item.alias {
        Some(name) -> name
        None -> item.name
      }
    }),
  )
}
