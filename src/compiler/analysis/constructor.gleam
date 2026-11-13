//// Look for the parent's greeting before construction moves on.
////
//// Recognize superclass constructor calls inside constructor syntax. Keep this
//// structural question separate from checking the types of the supplied
//// arguments.
////
//// ```pooka
//// super.new(name)
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import gleam/list
import gleam/option.{type Option, None, Some}

pub fn has_super_call(block: ast.Block) -> Bool {
  list.any(block.statements, fn(statement) {
    case statement {
      ast.ExpressionStatement(value) -> expression(value)
      ast.LetStatement(pattern:, value:, ..) ->
        expression(value)
        || list.any(ast.pattern_expressions(pattern), expression)
      ast.LetAssertStatement(pattern:, value:, message:, ..) ->
        expression(value)
        || optional(message)
        || list.any(ast.pattern_expressions(pattern), expression)
    }
  })
}

fn optional(value: Option(ast.Expression)) -> Bool {
  case value {
    None -> False
    Some(value) -> expression(value)
  }
}

fn expression(value: ast.Expression) -> Bool {
  case value {
    ast.Call(ast.FieldAccess(ast.SuperExpression(_), ast.Name("new", _), _), ..) ->
      True
    ast.Call(callee, arguments, _) ->
      list.any([callee, ..arguments], expression)
    ast.BlockExpression(block) -> has_super_call(block)
    ast.ListSpread(elements, tail, _) ->
      list.any(list.append(elements, [tail]), expression)
    ast.ListExpression(elements:, ..) | ast.TupleExpression(elements:, ..) ->
      list.any(elements, expression)
    ast.Match(subject, branches, _) ->
      expression(subject)
      || list.any(branches, fn(branch) {
        list.any(ast.pattern_expressions(branch.pattern), expression)
        || optional(branch.guard)
        || expression(branch.body)
      })
    ast.Loop(iteration, body, _) ->
      has_super_call(body)
      || case iteration {
        None -> False
        Some(iteration) -> expression(iteration.iterable)
      }
    ast.Binary(left:, right:, ..) -> expression(left) || expression(right)
    ast.Unary(operand:, ..)
    | ast.Propagate(operand:, ..)
    | ast.FieldAccess(subject: operand, ..)
    | ast.TupleAccess(subject: operand, ..) -> expression(operand)
    ast.Assert(condition, message, _) ->
      expression(condition) || optional(message)
    ast.Panic(message, _) | ast.Todo(message, _) | ast.Break(message, _) ->
      optional(message)
    ast.Assignment(target, _, value, _) ->
      expression(value)
      || case target {
        ast.AssignVariable(_) -> False
        ast.AssignField(subject, _, _) -> expression(subject)
      }
    ast.BitArrayExpression(segments, _) ->
      list.any(segments, fn(segment) {
        expression(segment.value)
        || list.any(segment.options, fn(option) {
          case option {
            ast.SizeOption(value, _) | ast.UnitOption(value, _) ->
              expression(value)
            ast.NamedOption(..) -> False
          }
        })
      })
    ast.AnonymousFunction(..)
    | ast.Continue(_)
    | ast.IntLiteral(..)
    | ast.FloatLiteral(..)
    | ast.StringLiteral(..)
    | ast.BoolLiteral(..)
    | ast.NilLiteral(_)
    | ast.Variable(..)
    | ast.TypeName(..)
    | ast.SelfExpression(_)
    | ast.SuperExpression(_) -> False
  }
}
