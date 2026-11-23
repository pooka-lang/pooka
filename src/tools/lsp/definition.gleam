//// Follow imports using the same module identities that project checking uses.

// SPDX-License-Identifier: Apache-2.0

import builder/check
import compiler/analysis/resolve
import compiler/compiler
import filepath
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
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
    Ok(span) -> Ok(#(path, span.start.byte_offset, span.end.byte_offset))
    Error(_) -> import_target(file, path, offset, overlays)
  }
}

fn import_target(
  current: compiler.Checked,
  path: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(#(String, Int, Int), Nil) {
  use _ <- result.try(find_import(current, offset))
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
      filepath.join(root, check.display_path(report, file.path)) == path
      || check.display_path(report, file.path) == path
    }),
  )
  use imported <- result.try(find_import(file, offset))
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
      let span = case target.parsed.module.header {
        Some(header) -> header.name.span
        None -> location.Span(location.start(), location.start())
      }
      Ok(#(
        absolute_path(report, target.path),
        span.start.byte_offset,
        span.end.byte_offset,
      ))
    }
    _, _ -> Error(Nil)
  }
}

fn find_import(file: compiler.Checked, offset: Int) {
  list.find(file.parsed.module.imports, fn(imported) {
    contains(imported.module.span, offset)
    || case imported.alias {
      Some(alias) -> contains(alias.span, offset)
      None -> False
    }
  })
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
