//// The librarian must shelve a class before opening its field patterns.
////
//// Collect declaration dependencies and order strongly connected components.
//// Pattern constructor names count as references, including those hidden inside
//// closures, so recursive groups see prepared class metadata.
////
//// ```text
//// caller -> unwrap -> Box; infer Box before unwrap
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import gleam/string

/// Order strongly connected declaration components with dependencies first. Local
/// variables shadow callable names, while constructor names in patterns still
/// contribute nominal dependencies.
///
/// ```text
/// caller -> unwrap -> Box -> prepare Box before checking unwrap
/// ```
pub fn groups(functions: List(ast.Function)) -> List(List(ast.Function)) {
  let indexed =
    functions
    |> list.index_map(fn(value, index) { #(value.name.name, #(index, value)) })
    |> dict.from_list
  let names = list.map(functions, fn(value) { value.name.name })
  let known = set.from_list(names)
  let graph =
    functions
    |> list.map(fn(value) {
      let bound = parameter_names(value.parameters)
      #(
        value.name.name,
        set.intersection(block(value.body, bound), known)
          |> set.to_list
          |> list.sort(string.compare),
      )
    })
    |> dict.from_list
  let #(_, finished) =
    list.fold(names, #(set.new(), []), fn(acc, name) {
      finish(name, graph, acc.0, acc.1)
    })
  let reversed =
    list.fold(names, dict.new(), fn(graph, name) {
      dict.insert(graph, name, [])
    })
  let reversed =
    list.fold(names, reversed, fn(reversed, name) {
      list.fold(edges(graph, name), reversed, fn(reversed, dependency) {
        dict.insert(reversed, dependency, [name, ..edges(reversed, dependency)])
      })
    })
  let #(_, components) =
    list.fold(finished, #(set.new(), []), fn(acc, name) {
      let #(visited, components) = acc
      case set.contains(visited, name) {
        True -> acc
        False -> {
          let #(visited, component) =
            collect(name, reversed, visited, set.new())

          let members =
            component
            |> set.to_list
            |> list.map(fn(name) {
              let assert Ok(entry) = dict.get(indexed, name)
              entry
            })
            |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
            |> list.map(fn(entry) { entry.1 })
          #(visited, [members, ..components])
        }
      }
    })
  components
}

fn edges(graph: Dict(String, List(String)), name: String) -> List(String) {
  case dict.get(graph, name) {
    Ok(values) -> values
    Error(Nil) -> []
  }
}

fn finish(
  name: String,
  graph: Dict(String, List(String)),
  visited: Set(String),
  finished: List(String),
) -> #(Set(String), List(String)) {
  case set.contains(visited, name) {
    True -> #(visited, finished)
    False -> {
      let visited = set.insert(visited, name)
      let #(visited, finished) =
        list.fold(edges(graph, name), #(visited, finished), fn(acc, child) {
          finish(child, graph, acc.0, acc.1)
        })
      #(visited, [name, ..finished])
    }
  }
}

fn collect(
  name: String,
  graph: Dict(String, List(String)),
  visited: Set(String),
  component: Set(String),
) -> #(Set(String), Set(String)) {
  case set.contains(visited, name) {
    True -> #(visited, component)
    False ->
      list.fold(
        edges(graph, name),
        #(set.insert(visited, name), set.insert(component, name)),
        fn(acc, child) { collect(child, graph, acc.0, acc.1) },
      )
  }
}

fn parameter_names(parameters: List(ast.Parameter)) -> Set(String) {
  parameters
  |> list.filter_map(fn(value) {
    case value.name {
      ast.NamedParameter(name) -> Ok(name)
      ast.DiscardedParameter -> Error(Nil)
    }
  })
  |> set.from_list
}

fn pattern_names(pattern: ast.Pattern) -> Set(String) {
  ast.pattern_bindings(pattern)
  |> list.map(fn(value) { value.name })
  |> set.from_list
}

fn pattern_dependencies(value: ast.Pattern, bound: Set(String)) -> Set(String) {
  set.union(
    pattern_types(value),
    expressions(ast.pattern_expressions(value), bound),
  )
}

fn pattern_types(value: ast.Pattern) -> Set(String) {
  case value {
    ast.ConstructorPattern(module, name, arguments, _) -> {
      let nested =
        list.fold(arguments, set.new(), fn(found, argument) {
          set.union(found, pattern_types(argument))
        })
      case module {
        None -> set.insert(nested, name)
        Some(_) -> nested
      }
    }
    ast.TuplePattern(elements, _) | ast.ListPattern(elements, _, _) ->
      list.fold(elements, set.new(), fn(found, element) {
        set.union(found, pattern_types(element))
      })
    ast.BitArrayPattern(segments, _) ->
      list.fold(segments, set.new(), fn(found, segment) {
        set.union(found, pattern_types(segment.value))
      })
    ast.EnumPattern(None, name, _, _) -> set.from_list([name])
    _ -> set.new()
  }
}

fn block(value: ast.Block, bound: Set(String)) -> Set(String) {
  let #(found, _) =
    list.fold(value.statements, #(set.new(), bound), fn(acc, value) {
      let #(found, bound) = acc
      case value {
        ast.ExpressionStatement(value) -> #(
          set.union(found, expression(value, bound)),
          bound,
        )
        ast.LetStatement(pattern:, value:, ..) -> {
          let refs =
            set.union(
              expression(value, bound),
              pattern_dependencies(pattern, bound),
            )
          #(set.union(found, refs), set.union(bound, pattern_names(pattern)))
        }
        ast.LetAssertStatement(pattern:, value:, message:, ..) -> {
          let refs =
            set.union(expression(value, bound), optional(message, bound))
          let refs = set.union(refs, pattern_dependencies(pattern, bound))
          #(set.union(found, refs), set.union(bound, pattern_names(pattern)))
        }
      }
    })
  found
}

fn optional(
  value: option.Option(ast.Expression),
  bound: Set(String),
) -> Set(String) {
  case value {
    Some(value) -> expression(value, bound)
    None -> set.new()
  }
}

fn expressions(
  values: List(ast.Expression),
  bound: Set(String),
) -> Set(String) {
  list.fold(values, set.new(), fn(found, value) {
    set.union(found, expression(value, bound))
  })
}

fn expression(value: ast.Expression, bound: Set(String)) -> Set(String) {
  case value {
    ast.Variable(name, _) | ast.TypeName(name, _) ->
      case set.contains(bound, name) {
        True -> set.new()
        False -> set.from_list([name])
      }
    ast.IntLiteral(..)
    | ast.FloatLiteral(..)
    | ast.StringLiteral(..)
    | ast.BoolLiteral(..)
    | ast.NilLiteral(..)
    | ast.SelfExpression(..)
    | ast.SuperExpression(..)
    | ast.Continue(..) -> set.new()
    ast.ListSpread(elements, tail, _) ->
      expressions(list.append(elements, [tail]), bound)
    ast.ListExpression(elements:, ..) | ast.TupleExpression(elements:, ..) ->
      expressions(elements, bound)
    ast.BlockExpression(value) -> block(value, bound)
    ast.AnonymousFunction(parameters, _, body, _) ->
      block(body, set.union(bound, parameter_names(parameters)))
    ast.Call(callee, arguments, _) -> expressions([callee, ..arguments], bound)
    ast.FieldAccess(subject:, ..) | ast.TupleAccess(subject:, ..) ->
      expression(subject, bound)
    ast.Unary(operand:, ..) | ast.Propagate(operand:, ..) ->
      expression(operand, bound)
    ast.Binary(left:, right:, ..) -> expressions([left, right], bound)
    ast.Match(subject, branches, _) ->
      list.fold(branches, expression(subject, bound), fn(found, branch) {
        let inner = set.union(bound, pattern_names(branch.pattern))
        set.union(
          found,
          set.union(
            set.union(
              expression(branch.body, inner),
              pattern_dependencies(branch.pattern, inner),
            ),
            optional(branch.guard, inner),
          ),
        )
      })
    ast.Loop(iteration, body, _) ->
      case iteration {
        None -> block(body, bound)
        Some(value) ->
          set.union(
            expression(value.iterable, bound),
            set.union(
              pattern_dependencies(value.pattern, bound),
              block(body, set.union(bound, pattern_names(value.pattern))),
            ),
          )
      }
    ast.Break(value:, ..) -> optional(value, bound)
    ast.Panic(message:, ..) | ast.Todo(message:, ..) -> optional(message, bound)
    ast.Assert(condition:, message:, ..) ->
      set.union(expression(condition, bound), optional(message, bound))
    ast.Assignment(target:, value:, ..) ->
      set.union(
        case target {
          ast.AssignVariable(name) ->
            case set.contains(bound, name.name) {
              True -> set.new()
              False -> set.from_list([name.name])
            }
          ast.AssignField(subject:, ..) -> expression(subject, bound)
        },
        expression(value, bound),
      )
    ast.BitArrayExpression(segments:, ..) ->
      expressions(
        list.flat_map(segments, fn(segment) {
          [
            segment.value,
            ..list.filter_map(segment.options, fn(option) {
              case option {
                ast.NamedOption(..) -> Error(Nil)
                ast.SizeOption(value, _) | ast.UnitOption(value, _) -> Ok(value)
              }
            })
          ]
        }),
        bound,
      )
  }
}
