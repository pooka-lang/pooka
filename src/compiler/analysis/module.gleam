//// Work out which books depend on which shelves.
////
//// Validate module names and imports, then order modules for checking. Missing
//// imports and cycles need source-level explanations rather than filesystem
//// exceptions.
////
//// ```text
//// main imports helper -> check helper before main
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option
import gleam/set.{type Set}
import gleam/string
import utilities/location.{type Location}
import utilities/text

pub type SourceModule {
  SourceModule(identity: String, path: String, syntax: ast.Module)
}

type Edge {
  Edge(target: String, location: Location)
}

type Walk {
  Walk(completed: Set(String), diagnostics: List(Diagnostic))
}

pub fn check(sources: List(SourceModule)) -> List(Diagnostic) {
  let identities =
    sources |> list.map(fn(source) { source.identity }) |> set.from_list
  let graph =
    sources
    |> list.map(fn(source) {
      let edges =
        source.syntax.imports
        |> list.filter_map(fn(imported) {
          let target = string.join(imported.module.segments, "/")
          case set.contains(identities, target) {
            True ->
              Ok(Edge(target, location.new(source.path, imported.module.span)))
            False -> Error(Nil)
          }
        })
      #(source.identity, edges)
    })
    |> dict.from_list
  let walked =
    list.fold(sources, Walk(set.new(), []), fn(state, source) {
      visit(source.identity, graph, [], state)
    })
  diagnostic.sort(walked.diagnostics)
}

fn visit(
  name: String,
  graph: Dict(String, List(Edge)),
  trail: List(#(String, Edge)),
  state: Walk,
) -> Walk {
  case cycle_edges(name, trail) {
    Ok(edges) ->
      Walk(..state, diagnostics: [cycle_diagnostic(edges), ..state.diagnostics])
    Error(Nil) ->
      case set.contains(state.completed, name) {
        True -> state
        False -> {
          let edges = case dict.get(graph, name) {
            Ok(edges) -> edges
            Error(Nil) -> []
          }
          let state =
            list.fold(edges, state, fn(state, edge) {
              visit(edge.target, graph, [#(name, edge), ..trail], state)
            })
          Walk(..state, completed: set.insert(state.completed, name))
        }
      }
  }
}

fn cycle_edges(
  name: String,
  trail: List(#(String, Edge)),
) -> Result(List(#(String, Edge)), Nil) {
  case trail {
    [] -> Error(Nil)
    [entry, ..rest] ->
      case entry.0 == name {
        True -> Ok([entry])
        False ->
          case cycle_edges(name, rest) {
            Ok(edges) -> Ok([entry, ..edges])
            Error(Nil) -> Error(Nil)
          }
      }
  }
}

fn cycle_diagnostic(reversed: List(#(String, Edge))) -> Diagnostic {
  let names = reversed |> list.reverse |> list.map(fn(entry) { entry.0 })
  let closing = case names {
    [first, ..] -> [first]
    [] -> []
  }
  let base =
    diagnostic.error("analysis.module_cycle", "circular module dependency")
    |> diagnostic.conclusion(
      "Module imports form a cycle: "
      <> string.join(list.append(names, closing), " -> ")
      <> ".",
    )
    |> diagnostic.help(
      "Move shared declarations into a module that neither side depends on, or remove an import from this cycle.",
    )
  list.index_fold(reversed, base, fn(value, entry, index) {
    let #(from, edge) = entry
    let message = "`" <> from <> "` imports `" <> edge.target <> "`"
    case index {
      0 -> diagnostic.primary(value, edge.location, message)
      _ -> diagnostic.secondary(value, edge.location, message)
    }
  })
}

pub fn check_imports(
  clients: List(SourceModule),
  targets: List(SourceModule),
) -> List(Diagnostic) {
  let exports =
    targets
    |> list.map(fn(source) {
      #(
        source.identity,
        list.filter_map(source.syntax.declarations, ast.declaration_name),
      )
    })
    |> dict.from_list
  clients
  |> list.flat_map(fn(client) {
    client.syntax.imports
    |> list.flat_map(fn(imported) {
      let identity = string.join(imported.module.segments, "/")
      case dict.get(exports, identity) {
        Error(Nil) -> [
          unknown_module(imported, identity, dict.keys(exports), client.path),
        ]
        Ok(names) ->
          imported.items
          |> list.filter_map(fn(item) {
            case
              string.starts_with(item.name.name, "_")
              || list.any(names, fn(name) { name.name == item.name.name })
            {
              True -> Error(Nil)
              False ->
                Ok(
                  diagnostic.error(
                    "analysis.unknown_imported_name",
                    "unknown imported declaration",
                  )
                  |> diagnostic.primary(
                    location.new(client.path, item.name.span),
                    "`"
                      <> item.name.name
                      <> "` is not declared in `"
                      <> identity
                      <> "`",
                  )
                  |> diagnostic.conclusion(
                    "Module `"
                    <> identity
                    <> "` has no declaration named `"
                    <> item.name.name
                    <> "`.",
                  )
                  |> diagnostic.help(
                    "Check the declaration name or import it from the module that defines it.",
                  ),
                )
            }
          })
      }
    })
  })
  |> diagnostic.sort
}

pub fn order(
  sources: List(SourceModule),
) -> Result(List(SourceModule), List(Diagnostic)) {
  case check(sources) {
    [_, ..] as diagnostics -> Error(diagnostics)
    [] -> {
      let indexed =
        sources
        |> list.map(fn(source) { #(source.identity, source) })
        |> dict.from_list
      let #(_, reversed) =
        list.fold(sources, #(set.new(), []), fn(acc, source) {
          order_visit(source.identity, indexed, acc.0, acc.1)
        })
      Ok(list.reverse(reversed))
    }
  }
}

fn order_visit(
  identity: String,
  indexed: Dict(String, SourceModule),
  visited: Set(String),
  ordered: List(SourceModule),
) -> #(Set(String), List(SourceModule)) {
  case set.contains(visited, identity), dict.get(indexed, identity) {
    True, _ | _, Error(Nil) -> #(visited, ordered)
    False, Ok(source) -> {
      let visited = set.insert(visited, identity)
      let #(visited, ordered) =
        list.fold(source.syntax.imports, #(visited, ordered), fn(acc, imported) {
          order_visit(
            string.join(imported.module.segments, "/"),
            indexed,
            acc.0,
            acc.1,
          )
        })
      #(visited, [source, ..ordered])
    }
  }
}

fn unknown_module(
  imported: ast.Import,
  identity: String,
  known: List(String),
  path: String,
) -> Diagnostic {
  let base =
    diagnostic.error("module.unknown", "unknown module")
    |> diagnostic.primary(
      location.new(path, imported.module.span),
      "no module with this name was found",
    )
    |> diagnostic.conclusion("Could not find module `" <> identity <> "`.")
  case text.closest(identity, list.sort(list.unique(known), string.compare)) {
    option.Some(suggestion) ->
      base
      |> diagnostic.help("Did you mean `" <> suggestion <> "`?")
      |> diagnostic.fix(
        location.new(path, imported.module.span),
        suggestion,
        "Import `" <> suggestion <> "`",
        diagnostic.Suggested,
      )
    option.None -> base
  }
}
