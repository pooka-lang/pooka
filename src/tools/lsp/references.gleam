//// Index uses by the path and span of their resolved declaration.

// SPDX-License-Identifier: Apache-2.0

import builder/check
import builder/infer
import compiler/analysis/resolve
import compiler/compiler
import compiler/typesystem/unify
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/package
import tools/lsp/definition
import utilities/location.{type Span}

pub type Site {
  Site(path: String, span: Span)
}

pub type Occurrence {
  // With selective aliases, a reference still points to the export, but its
  // spelling belongs to the importing file.
  Occurrence(site: Site, target: Site, alias: Option(Site))
}

pub type Lookup {
  Lookup(target: Site, occurrences: List(Occurrence))
}

pub fn lookup(
  path: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(Lookup, Nil) {
  use #(graph, checked) <- result.try(definition.project_report(path, overlays))
  let typed =
    definition.typed_report(checked)
    |> result.map(fn(report) { report.modules })
    |> result.unwrap([])
  let uses =
    checked.files
    |> list.filter(fn(file) {
      package.owner(file.path, graph.root.name) == graph.root.name
    })
    |> list.flat_map(fn(file) { file_references(graph, checked, file, typed) })
  use target <- result.try(
    list.find(uses, fn(use_) { at(use_.site, path, offset) })
    |> result.map(fn(use_) { use_.target })
    |> result.lazy_or(fn() {
      list.find(uses, fn(use_) {
        at(use_.target, path, offset)
        || case use_.alias {
          Some(alias) -> at(alias, path, offset)
          None -> False
        }
      })
      |> result.map(fn(use_) { use_.target })
    }),
  )
  Ok(Lookup(
    target,
    uses
      |> list.filter(fn(use_) { use_.target == target && use_.site != target })
      |> list.unique,
  ))
}

pub fn locations(
  path: String,
  offset: Int,
  overlays: List(#(String, String)),
  include_declaration: Bool,
) -> List(#(String, Int, Int)) {
  case lookup(path, offset, overlays) {
    Error(_) -> []
    Ok(lookup) -> {
      let sites = list.map(lookup.occurrences, fn(use_) { use_.site })
      case include_declaration {
        True -> [lookup.target, ..sites]
        False -> sites
      }
      |> list.unique
      |> list.sort(fn(a, b) {
        case a.path == b.path {
          True ->
            int.compare(a.span.start.byte_offset, b.span.start.byte_offset)
          False -> string.compare(a.path, b.path)
        }
      })
      |> list.map(fn(site) {
        #(site.path, site.span.start.byte_offset, site.span.end.byte_offset)
      })
    }
  }
}

fn file_references(
  graph: package.Graph,
  checked: check.Report,
  file: compiler.Checked,
  typed: List(infer.TypedModule),
) -> List(Occurrence) {
  let path = definition.absolute_path(checked, file.path)
  let lexical =
    resolve.editor_references(file.parsed.module, file.path)
    |> list.filter_map(fn(pair) {
      let #(span, resolved) = pair
      let site = Site(path, span)
      case resolved {
        resolve.LocalTarget(target) ->
          Ok(Occurrence(site, Site(path, target), None))
        resolve.ImportTarget(reference) ->
          definition.resolve_import_reference(
            graph,
            checked,
            file,
            path,
            reference,
          )
          |> result.map(fn(target) {
            let alias = case reference {
              resolve.SelectiveImport(binding, _) ->
                file.parsed.module.imports
                |> list.flat_map(fn(imported) { imported.items })
                |> list.find_map(fn(item) {
                  case item.alias {
                    Some(alias) if alias.name == binding ->
                      Ok(Site(path, alias.span))
                    _ -> Error(Nil)
                  }
                })
                |> option.from_result
              _ -> None
            }
            Occurrence(site, Site(target.0, target.1), alias)
          })
      }
    })
  let imports =
    list.flat_map(file.parsed.module.imports, fn(imported) {
      case definition.imported_file(graph, checked, path, imported.span) {
        Error(_) -> []
        Ok(target) ->
          list.filter_map(imported.items, fn(item) {
            use span <- result.try(definition.target_span(
              target,
              Some(#(item.name.name, False)),
            ))
            Ok(Occurrence(
              Site(path, item.name.span),
              Site(definition.absolute_path(checked, target.path), span),
              None,
            ))
          })
      }
    })
  let members =
    list.find(typed, fn(module) { module.path == file.path })
    |> result.map(fn(module) { unify.member_definitions(module.inferred.state) })
    |> result.unwrap([])
    |> list.map(fn(pair) {
      Occurrence(
        Site(path, pair.0),
        Site(definition.absolute_path(checked, pair.1.path), pair.1.span),
        None,
      )
    })
  list.append(lexical, list.append(imports, members))
}

fn at(site: Site, path: String, offset: Int) -> Bool {
  site.path == path
  && site.span.start.byte_offset <= offset
  && offset < site.span.end.byte_offset
}
