//// Find the return door belonging to this callable.
////
//// Detect Result propagation in a block without crossing into a nested function.
//// The emitter needs a catch boundary only for propagation that can leave the
//// current callable.
////
//// ```text
//// fn() { read()? } owns its return boundary; its outer function does not
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/codegen/forms as f
import compiler/parser/ast
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// Look for propagation that can escape this block's callable. A nested anonymous
/// function owns its own return door.
///
/// ```text
/// outer { fn() { read()? } } -> no outer propagation boundary
/// ```
pub fn block(value: ast.Block) -> Bool {
  list.any(value.statements, fn(statement) {
    case statement {
      ast.ExpressionStatement(value) -> expression(value)
      ast.LetStatement(pattern, _, value, _) ->
        expression(value)
        || list.any(ast.pattern_expressions(pattern), expression)
      ast.LetAssertStatement(pattern, _, value, message, _) ->
        expression(value)
        || optional(message)
        || list.any(ast.pattern_expressions(pattern), expression)
    }
  })
}

/// Inspect an optional child expression without manufacturing one when it is
/// absent.
///
/// ```text
/// None -> False; Some(expression) -> inspect expression
/// ```
fn optional(value: Option(ast.Expression)) -> Bool {
  case value {
    Some(value) -> expression(value)
    None -> False
  }
}

/// Walk children for postfix ? and stop at anonymous-function boundaries. This
/// mirrors lexical ownership of the runtime return tag.
///
/// ```text
/// parse()? -> True; fn() { parse()? } -> False for the outer scan
/// ```
fn expression(value: ast.Expression) -> Bool {
  case value {
    ast.Propagate(..) -> True
    ast.AnonymousFunction(..) -> False
    ast.ListSpread(values, tail, _) ->
      list.any(values, expression) || expression(tail)
    ast.ListExpression(values, _) | ast.TupleExpression(values, _) ->
      list.any(values, expression)
    ast.BlockExpression(body) -> block(body)
    ast.Call(callee, arguments, _) ->
      expression(callee) || list.any(arguments, expression)
    ast.TupleAccess(subject, _, _, _)
    | ast.FieldAccess(subject, _, _)
    | ast.Unary(_, subject, _) -> expression(subject)
    ast.Binary(_, left, right, _) -> expression(left) || expression(right)
    ast.Match(subject, branches, _) ->
      expression(subject)
      || list.any(branches, fn(branch) {
        optional(branch.guard) || expression(branch.body)
      })
    ast.Loop(iteration, body, _) ->
      block(body)
      || case iteration {
        Some(value) -> expression(value.iterable)
        None -> False
      }
    ast.Break(value, _) | ast.Panic(value, _) | ast.Todo(value, _) ->
      optional(value)
    ast.Assert(condition, message, _) ->
      expression(condition) || optional(message)
    ast.Assignment(target, _, value, _) ->
      expression(value)
      || case target {
        ast.AssignField(subject, _, _) -> expression(subject)
        ast.AssignVariable(_) -> False
      }
    ast.BitArrayExpression(segments, _) ->
      list.any(segments, fn(segment) {
        expression(segment.value)
        || list.any(segment.options, fn(option) {
          case option {
            ast.SizeOption(value, _) | ast.UnitOption(value, _) ->
              expression(value)
            ast.NamedOption(_, _) -> False
          }
        })
      })
    _ -> False
  }
}

/// Rewrite direct propagation in the callable's return position. An early
/// error returns as a case arm, while the remaining success body stays in
/// tail position. Embedded propagation keeps the existing throw boundary.
///
/// https://www.erlang.org/doc/apps/erts/absform.html#expressions
pub fn lower(body: List(f.Term)) -> Option(List(f.Term)) {
  let #(lowered, _) = lower_body(body, 0)
  case list.any(lowered, unhandled) {
    True -> None
    False -> Some(lowered)
  }
}

fn lower_body(body: List(f.Term), next: Int) -> #(List(f.Term), Int) {
  case body {
    [] -> #([], next)
    [term, ..rest] ->
      case site(term) {
        Some(#(bindings, operand, line, binding)) -> {
          let suffix = int.to_string(next)
          let #(continuation, next) = lower_body(rest, next + 1)
          let value = f.variable("PropagationOk" <> suffix, line)
          let error = f.variable("PropagationError" <> suffix, line)
          let success = case binding, continuation {
            Some(#(match_line, pattern)), _ -> [
              f.node("match", match_line, [pattern, value]),
              ..continuation
            ]
            None, [] -> [value]
            None, _ -> continuation
          }
          let error_pattern =
            f.node("match", line, [
              tagged("error", f.variable("_", line), line),
              error,
            ])
          let dispatch =
            f.node("case", line, [
              operand,
              f.Sequence([
                f.clause([tagged("ok", value, line)], success, line),
                f.clause([error_pattern], [error], line),
              ]),
            ])
          #(list.append(bindings, [dispatch]), next)
        }
        None ->
          case rest {
            [] -> {
              let #(term, next) = lower_tail(term, next)
              #([term], next)
            }
            _ -> {
              let #(rest, next) = lower_body(rest, next)
              #([term, ..rest], next)
            }
          }
      }
  }
}

fn tagged(tag: String, value: f.Term, line: Int) -> f.Term {
  f.node("tuple", line, [f.Sequence([f.atom(tag, line), value])])
}

fn site(
  term: f.Term,
) -> Option(#(List(f.Term), f.Term, Int, Option(#(Int, f.Term)))) {
  let #(operand, binding) = case term {
    f.Tuple([f.Atom("match"), f.Integer(line), pattern, operand]) -> #(
      operand,
      Some(#(line, pattern)),
    )
    _ -> #(term, None)
  }
  use #(bindings, value, line) <- option.then(unwrap(operand))
  Some(#(bindings, value, line, binding))
}

fn unwrap(term: f.Term) -> Option(#(List(f.Term), f.Term, Int)) {
  case term {
    f.Tuple([f.Atom("block"), _, f.Sequence(body)]) ->
      case list.reverse(body) {
        [last, ..before] -> {
          use #(bindings, operand, line) <- option.then(unwrap(last))
          Some(#(list.append(list.reverse(before), bindings), operand, line))
        }
        [] -> None
      }
    f.Tuple([
      f.Atom("call"),
      f.Integer(line),
      f.Tuple([
        f.Atom("remote"),
        _,
        f.Tuple([f.Atom("atom"), _, f.Atom("pooka_runtime_ffi")]),
        f.Tuple([f.Atom("atom"), _, f.Atom("propagate")]),
      ]),
      f.Sequence([operand]),
    ]) -> Some(#([], operand, line))
    _ -> None
  }
}

fn lower_tail(term: f.Term, next: Int) -> #(f.Term, Int) {
  case term {
    f.Tuple([f.Atom("block"), f.Integer(line), f.Sequence(body)]) -> {
      let #(body, next) = lower_body(body, next)
      #(f.node("block", line, [f.Sequence(body)]), next)
    }
    f.Tuple([f.Atom("case"), f.Integer(line), subject, f.Sequence(clauses)]) -> {
      let #(next, clauses) = list.map_fold(clauses, next, lower_clause)
      #(f.node("case", line, [subject, f.Sequence(clauses)]), next)
    }
    _ -> #(term, next)
  }
}

fn lower_clause(next: Int, term: f.Term) -> #(Int, f.Term) {
  case term {
    f.Tuple([
      f.Atom("clause"),
      f.Integer(line),
      pattern,
      guards,
      f.Sequence(body),
    ]) -> {
      let #(body, next) = lower_body(body, next)
      #(next, f.node("clause", line, [pattern, guards, f.Sequence(body)]))
    }
    _ -> #(next, term)
  }
}

fn unhandled(term: f.Term) -> Bool {
  case term {
    f.Tuple([f.Atom("try"), _, body, then, f.Sequence(catches), after]) ->
      // An existing callable boundary handles its own returns. Loop catches
      // own different tags and must remain visible to this scan.
      case list.any(catches, catches_return) {
        True -> False
        False ->
          unhandled(body)
          || unhandled(then)
          || list.any(catches, unhandled)
          || unhandled(after)
      }
    f.Tuple([f.Atom("call"), _, ..] as fields) ->
      option.is_some(unwrap(term)) || list.any(fields, unhandled)
    f.Tuple(fields) | f.Sequence(fields) -> list.any(fields, unhandled)
    _ -> False
  }
}

fn catches_return(term: f.Term) -> Bool {
  case term {
    f.Tuple([f.Atom("clause"), _, f.Sequence([pattern]), _, _]) ->
      case pattern {
        f.Tuple([
          f.Atom("tuple"),
          _,
          f.Sequence([
            _,
            f.Tuple([
              f.Atom("tuple"),
              _,
              f.Sequence([
                f.Tuple([f.Atom("atom"), _, f.Atom("pooka_return")]),
                _,
              ]),
            ]),
            _,
          ]),
        ]) -> True
        _ -> False
      }
    _ -> False
  }
}
