//// Follow imports using the same module identities that project checking uses.

// SPDX-License-Identifier: Apache-2.0

import builder/check
import compiler/analysis/resolve
import compiler/compiler
import compiler/parser/ast
import filepath
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/package
import project/project
import tools/lsp/analysis
import utilities/location.{type Span}

pub fn target(
  path: String,
  source: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(#(String, Int, Int), Nil) {
  let file = compiler.check_editor_source(path, source)
  case resolve.editor_definition(file.parsed.module, path, offset) {
    Ok(resolve.LocalTarget(span)) ->
      Ok(#(path, span.start.byte_offset, span.end.byte_offset))
    Ok(resolve.ImportTarget(reference)) ->
      cross_file_target(file, path, FromReference(reference), overlays)
    Error(_) -> cross_file_target(file, path, AtImport(offset), overlays)
  }
}

type ImportQuery {
  FromReference(resolve.ImportReference)
  AtImport(Int)
}

fn cross_file_target(
  current: compiler.Checked,
  path: String,
  query: ImportQuery,
  overlays: List(#(String, String)),
) -> Result(#(String, Int, Int), Nil) {
  use #(original, member) <- result.try(find_import(current, query))
  use root <- result.try(analysis.workspace(path))
  use loaded <- result.try(project.load(root) |> result.replace_error(Nil))
  use graph <- result.try(
    package.resolve_offline(loaded) |> result.replace_error(Nil),
  )
  use report <- result.try(
    check.check_graph_with_overlays(graph, True, dict.from_list(overlays), True)
    |> result.replace_error(Nil),
  )
  use file <- result.try(
    list.find(report.files, fn(file) {
      absolute_path(report, file.path) == path
    }),
  )
  use imported <- result.try(
    list.find(file.parsed.module.imports, fn(imported) {
      imported.span == original.span
    }),
  )
  let owner_name = package.owner(file.path, loaded.name)
  use owner <- result.try(
    list.find(graph.packages, fn(p) { p.name == owner_name }),
  )
  let dependencies = case owner_name == loaded.name {
    True -> list.append(owner.dependencies, owner.dev_dependencies)
    False -> owner.dependencies
  }
  let visible = [owner_name, ..list.map(dependencies, fn(dep) { dep.name })]
  let identity = string.join(imported.module.segments, "/")
  let targets =
    list.filter(report.files, fn(file) {
      case compiler.expected_module_path(file.path) {
        Ok(candidate) -> {
          let name = package.module_owner(identity, loaded.name).1
          case name {
            "main" -> candidate == identity
            _ -> package.module_owner(candidate, loaded.name).1 == name
          }
        }
        Error(_) -> False
      }
    })
  let visible_targets =
    list.filter(targets, fn(target) {
      list.contains(visible, package.owner(target.path, loaded.name))
    })
  case targets, visible_targets {
    [_], [target] -> {
      use span <- result.try(target_span(target, member))
      Ok(#(
        absolute_path(report, target.path),
        span.start.byte_offset,
        span.end.byte_offset,
      ))
    }
    _, _ -> Error(Nil)
  }
}

fn find_import(file: compiler.Checked, query: ImportQuery) {
  let candidates =
    list.flat_map(file.parsed.module.imports, fn(imported) {
      case query {
        FromReference(resolve.QualifiedImport(alias, member, constructor)) ->
          case module_alias(imported) == Ok(alias) {
            True -> [#(imported, Some(#(member, constructor)))]
            False -> []
          }
        FromReference(resolve.SelectiveImport(binding, constructor)) ->
          list.filter_map(imported.items, fn(item) {
            let local = case item.alias {
              Some(alias) -> alias.name
              None -> item.name.name
            }
            case local == binding {
              True -> Ok(#(imported, Some(#(item.name.name, constructor))))
              False -> Error(Nil)
            }
          })
        AtImport(offset) -> {
          let on_module =
            contains(imported.module.span, offset)
            || case imported.alias {
              Some(alias) -> contains(alias.span, offset)
              None -> False
            }
          case on_module {
            True -> [#(imported, None)]
            False ->
              list.filter_map(imported.items, fn(item) {
                case contains(item.span, offset) {
                  True -> Ok(#(imported, Some(#(item.name.name, False))))
                  False -> Error(Nil)
                }
              })
          }
        }
      }
    })
  case candidates {
    [target] -> Ok(target)
    _ -> Error(Nil)
  }
}

fn module_alias(imported: ast.Import) -> Result(String, Nil) {
  case imported.alias {
    Some(alias) -> Ok(alias.name)
    None -> list.last(imported.module.segments)
  }
}

fn target_span(
  target: compiler.Checked,
  member: Option(#(String, Bool)),
) -> Result(Span, Nil) {
  case member {
    None ->
      Ok(case target.parsed.module.header {
        Some(header) -> header.name.span
        None -> location.Span(location.start(), location.start())
      })
    Some(#(member, constructor)) -> {
      let constructor = case constructor && !string.starts_with(member, "_") {
        True -> resolve.constructor_span(target.parsed.module, member)
        False -> Error(Nil)
      }
      use <- result.lazy_unwrap(constructor |> result.map(Ok))

      let names =
        list.filter_map(target.parsed.module.declarations, ast.declaration_name)
      case
        list.filter(names, fn(name) {
          name.name == member && !string.starts_with(member, "_")
        })
      {
        [name] -> Ok(name.span)
        _ -> Error(Nil)
      }
    }
  }
}

fn contains(span: Span, offset: Int) -> Bool {
  span.start.byte_offset <= offset && offset < span.end.byte_offset
}

fn absolute_path(report: check.Report, path: String) -> String {
  let displayed = check.display_path(report, path)
  case filepath.is_absolute(displayed) {
    True -> displayed
    False -> filepath.join(report.project.root, displayed)
  }
}
