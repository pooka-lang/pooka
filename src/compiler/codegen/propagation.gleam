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

import compiler/parser/ast
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
    ast.ListExpression(values, _) | ast.TupleExpression(values, _) ->
      list.any(values, expression)
    ast.BlockExpression(body) -> block(body)
    ast.Call(callee, arguments, _) ->
      expression(callee) || list.any(arguments, expression)
    ast.FieldAccess(subject, _, _) | ast.Unary(_, subject, _) ->
      expression(subject)
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
