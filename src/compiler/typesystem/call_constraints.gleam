//// Let a generic parameter meet the whole family before choosing a name.
////
//// Collect constraints from known call arguments before checking callback
//// bodies. Only fresh variables owned by this invocation may be seeded. Class
//// parameters and function inputs remain invariant; positive immutable views
//// may share the nearest compatible superclass.
////
//// ```pooka
//// pair(Circle(), Square()) // a becomes Shape, not the first subclass seen
//// post(Mailbox(Clock), Tick()) // the mailbox pins m to Clock
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/typesystem/monotype.{type Type}
import compiler/typesystem/unify
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import utilities/location.{type Span}

pub type Argument {
  Argument(parameter: Type, found: Type, span: Span)
}

type Bounds {
  Bounds(positive: List(#(Type, Span)), pinned: List(#(Type, Span)))
}

/// Seed compatible bounds, leaving impossible combinations to ordinary call
/// checking so its source-labelled constraint diagnostics remain authoritative.
pub fn seed(
  arguments: List(Argument),
  eligible: Set(Int),
  state: unify.State,
  path: String,
) -> unify.State {
  let bounds =
    list.fold(arguments, dict.new(), fn(bounds, argument) {
      collect(
        argument.parameter,
        argument.found,
        False,
        argument.span,
        eligible,
        state,
        bounds,
      )
    })
  dict.to_list(bounds)
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.fold(state, fn(state, pair) {
    let #(id, bounds) = pair
    case unify.apply(monotype.Variable(id), state) {
      monotype.Variable(_) -> {
        let candidates = case bounds.pinned {
          [] -> bounds.positive
          pinned -> pinned
        }
        case candidates {
          [] -> state
          [#(_, span), ..] -> {
            let candidate = case bounds.pinned {
              [#(first, _), ..] -> Ok(first)
              [] ->
                unify.join(state, list.map(candidates, fn(value) { value.0 }))
            }
            let origin =
              unify.Origin(
                location.new(path, span),
                location.new(path, span),
                "Call arguments share this generic parameter.",
              )
            candidate
            |> result.try(fn(candidate) {
              list.try_fold(bounds.pinned, state, fn(state, pin) {
                unify.unify(candidate, pin.0, origin, state)
              })
              |> result.try(fn(state) {
                unify.unify(monotype.Variable(id), candidate, origin, state)
              })
              |> result.map_error(fn(_) { Nil })
            })
            |> result.unwrap(state)
          }
        }
      }
      _ -> state
    }
  })
}

fn collect(
  parameter: Type,
  found: Type,
  pinned: Bool,
  span: Span,
  eligible: Set(Int),
  state: unify.State,
  bounds: Dict(Int, Bounds),
) -> Dict(Int, Bounds) {
  case parameter, unify.apply(found, state) {
    _, monotype.Variable(_) | _, monotype.ErrorType -> bounds
    monotype.Variable(id), found ->
      case set.contains(eligible, id) {
        False -> bounds
        True -> {
          let previous = dict.get(bounds, id) |> result.unwrap(Bounds([], []))
          let next = case pinned {
            True ->
              Bounds(
                ..previous,
                pinned: list.append(previous.pinned, [#(found, span)]),
              )
            False ->
              Bounds(
                ..previous,
                positive: list.append(previous.positive, [#(found, span)]),
              )
          }
          dict.insert(bounds, id, next)
        }
      }
    monotype.ListType(a), monotype.ListType(b)
    | monotype.OptionType(a), monotype.OptionType(b)
    -> collect(a, b, pinned, span, eligible, state, bounds)
    monotype.ResultType(a, e), monotype.ResultType(b, f) ->
      collect_pairs([a, e], [b, f], pinned, span, eligible, state, bounds)
    monotype.TupleType(a), monotype.TupleType(b) ->
      collect_pairs(a, b, pinned, span, eligible, state, bounds)
    monotype.FunctionType(a, result_a), monotype.FunctionType(b, result_b) -> {
      let bounds = collect_pairs(a, b, True, span, eligible, state, bounds)
      collect(result_a, result_b, pinned, span, eligible, state, bounds)
    }
    monotype.Nominal(module, name, kind, parameters),
      monotype.Nominal(other_module, other_name, other_kind, arguments) as found
    -> {
      case module == other_module && name == other_name && kind == other_kind {
        True ->
          collect_pairs(
            parameters,
            arguments,
            True,
            span,
            eligible,
            state,
            bounds,
          )
        False ->
          case kind {
            monotype.ClassKind ->
              case unify.upcast(state, found, #(module, name)) {
                Ok(monotype.Nominal(_, _, _, arguments)) ->
                  collect_pairs(
                    parameters,
                    arguments,
                    True,
                    span,
                    eligible,
                    state,
                    bounds,
                  )
                _ -> bounds
              }
            _ -> bounds
          }
      }
    }
    _, _ -> bounds
  }
}

fn collect_pairs(
  parameters: List(Type),
  found: List(Type),
  pinned: Bool,
  span: Span,
  eligible: Set(Int),
  state: unify.State,
  bounds: Dict(Int, Bounds),
) -> Dict(Int, Bounds) {
  case list.length(parameters) == list.length(found) {
    False -> bounds
    True ->
      list.fold(list.zip(parameters, found), bounds, fn(bounds, pair) {
        collect(pair.0, pair.1, pinned, span, eligible, state, bounds)
      })
  }
}
