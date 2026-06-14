//// A family tree should not fold back into its own roots.
////
//// Validate the structural rules of class hierarchies and their module
//// boundaries. Diagnose cycles and invalid inheritance arrangements before field
//// and method inference needs the chain.
////
//// ```text
//// Child is Parent -> a directed superclass edge
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import utilities/location.{type Span}
import utilities/text

pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  let classes =
    list.filter_map(module.declarations, fn(value) {
      case value {
        ast.ClassDeclaration(value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  let local =
    classes
    |> list.map(fn(value) { #(value.name.name, value) })
    |> dict.from_list
  let diagnostics = list.flat_map(classes, parent(_, module, local, path))
  list.append(diagnostics, cycles(classes, local, path)) |> diagnostic.sort
}

fn parent(
  value: ast.Class,
  module: ast.Module,
  local: Dict(String, ast.Class),
  path: String,
) -> List(Diagnostic) {
  case value.superclass {
    None -> []
    Some(ast.NamedType(Some(qualifier), name, _, span)) ->
      case
        list.find(module.imports, fn(imported) {
          module_alias(imported) == qualifier
        })
      {
        Ok(imported) -> [external_parent(imported, name, span, path)]
        Error(Nil) -> [
          diagnostic.error(
            "analysis.unknown_module_qualifier",
            "unknown module qualifier",
          )
          |> diagnostic.primary(
            location.new(path, span),
            "no module is imported as `" <> qualifier <> "`",
          )
          |> diagnostic.conclusion(
            "Import the module before using its qualifier in a type annotation.",
          ),
        ]
      }
    Some(ast.NamedType(None, name, arguments, span)) ->
      case dict.get(local, name) {
        Ok(parent) ->
          case list.length(parent.type_parameters) == list.length(arguments) {
            True -> []
            False -> [
              diagnostic.error(
                "analysis.superclass_arity",
                "wrong number of superclass type arguments",
              )
              |> diagnostic.primary(
                location.new(path, span),
                "found "
                  <> int.to_string(list.length(arguments))
                  <> " type arguments",
              )
              |> diagnostic.secondary(
                location.new(path, parent.name.span),
                "this class declares "
                  <> int.to_string(list.length(parent.type_parameters))
                  <> " type parameters",
              )
              |> diagnostic.conclusion(
                "Supply exactly the type arguments declared by the superclass.",
              ),
            ]
          }
        Error(Nil) ->
          case
            list.find(module.imports, fn(imported) {
              list.any(imported.items, fn(item) {
                case item.alias {
                  Some(alias) -> alias.name == name
                  None -> item.name.name == name
                }
              })
            })
          {
            Ok(imported) -> [external_parent(imported, name, span, path)]
            Error(Nil) -> {
              let declared =
                module.declarations
                |> list.filter_map(fn(declaration) {
                  use declared <- result.try(ast.declaration_name(declaration))
                  case declared.name == name, declaration {
                    True, ast.EnumDeclaration(_) -> Ok(#(declared, "an enum"))
                    True, _ -> Ok(#(declared, "not a class"))
                    False, _ -> Error(Nil)
                  }
                })
                |> list.first
              let builtin =
                list.contains(
                  [
                    "Int", "Float", "String", "UtfCodepoint", "Bool", "Nil",
                    "BitArray", "Pid", "List", "Option", "Result",
                  ],
                  name,
                )
              case declared, builtin {
                Ok(#(declared, kind)), _ -> [
                  invalid_parent(span, path)
                  |> diagnostic.secondary(
                    location.new(path, declared.span),
                    "`" <> name <> "` is " <> kind,
                  ),
                ]
                Error(Nil), True -> [invalid_parent(span, path)]
                Error(Nil), False -> {
                  let base =
                    diagnostic.error(
                      "analysis.unknown_superclass",
                      "unknown superclass",
                    )
                    |> diagnostic.primary(
                      location.new(path, span),
                      "no local class named `" <> name <> "` is declared",
                    )
                    |> diagnostic.conclusion(
                      "A superclass must be a class declared in this module.",
                    )
                  [
                    case
                      text.closest(
                        name,
                        dict.keys(local) |> list.sort(string.compare),
                      )
                    {
                      Some(suggestion) ->
                        diagnostic.help(
                          base,
                          "Did you mean `" <> suggestion <> "`?",
                        )
                      None -> base
                    },
                  ]
                }
              }
            }
          }
      }
    Some(annotation) -> [invalid_parent(ast.type_span(annotation), path)]
  }
}

fn invalid_parent(span: Span, path: String) -> Diagnostic {
  diagnostic.error("analysis.invalid_superclass", "superclass is not a class")
  |> diagnostic.primary(
    location.new(path, span),
    "only a local class can be inherited",
  )
  |> diagnostic.conclusion(
    "Actors, enums, interfaces, external namespaces, primitive types, tuples, functions and generic variables cannot be superclasses.",
  )
}

fn external_parent(
  imported: ast.Import,
  name: String,
  span: Span,
  path: String,
) -> Diagnostic {
  diagnostic.error(
    "analysis.external_superclass",
    "class inheritance crosses a module boundary",
  )
  |> diagnostic.primary(
    location.new(path, span),
    "`" <> name <> "` is imported from another module",
  )
  |> diagnostic.secondary(location.new(path, imported.span), "imported here")
  |> diagnostic.conclusion(
    "A class may only inherit from a class declared in the same module.",
  )
  |> diagnostic.help(
    "Declare subclasses alongside their parent, or use an interface with `with` for an open extension point.",
  )
}

fn module_alias(imported: ast.Import) -> String {
  case imported.alias {
    Some(alias) -> alias.name
    None ->
      case list.last(imported.module.segments) {
        Ok(name) -> name
        Error(Nil) -> ""
      }
  }
}

type Edge {
  Edge(from: String, target: String, span: Span)
}

type Walk {
  Walk(completed: Set(String), diagnostics: List(Diagnostic))
}

fn cycles(
  classes: List(ast.Class),
  local: Dict(String, ast.Class),
  path: String,
) -> List(Diagnostic) {
  let graph =
    classes
    |> list.filter_map(fn(value) {
      case value.superclass {
        Some(ast.NamedType(None, name, _, span)) ->
          case dict.has_key(local, name) {
            True -> Ok(#(value.name.name, Edge(value.name.name, name, span)))
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
    |> dict.from_list
  let walked =
    list.fold(classes, Walk(set.new(), []), fn(state, value) {
      walk(value.name.name, graph, [], state, path)
    })
  walked.diagnostics
}

fn walk(
  name: String,
  graph: Dict(String, Edge),
  trail: List(Edge),
  state: Walk,
  path: String,
) -> Walk {
  case list.any(trail, fn(edge) { edge.from == name }) {
    True -> {
      let cycle = cycle_edges(trail, name)
      let names = list.reverse(cycle) |> list.map(fn(edge) { edge.from })
      let names =
        list.append(names, case names {
          [first, ..] -> [first]
          [] -> []
        })
      let base =
        diagnostic.error(
          "analysis.inheritance_cycle",
          "circular class inheritance",
        )
        |> diagnostic.conclusion(
          "Classes form an inheritance cycle: "
          <> string.join(names, " -> ")
          <> ".",
        )
      let value =
        list.index_fold(cycle, base, fn(value, edge, index) {
          let at = location.new(path, edge.span)
          let message =
            "`" <> edge.from <> "` inherits from `" <> edge.target <> "`"
          case index {
            0 -> diagnostic.primary(value, at, message)
            _ -> diagnostic.secondary(value, at, message)
          }
        })
      Walk(..state, diagnostics: [value, ..state.diagnostics])
    }
    False ->
      case set.contains(state.completed, name) {
        True -> state
        False -> {
          let state = case dict.get(graph, name) {
            Ok(edge) -> walk(edge.target, graph, [edge, ..trail], state, path)
            Error(Nil) -> state
          }
          Walk(..state, completed: set.insert(state.completed, name))
        }
      }
  }
}

fn cycle_edges(trail: List(Edge), name: String) -> List(Edge) {
  case trail {
    [] -> []
    [first, ..rest] ->
      case first.from == name {
        True -> [first]
        False -> [first, ..cycle_edges(rest, name)]
      }
  }
}
