//// Find every little room in a module, including the ones inside expressions.
////
//// Semantic lint passes need the original blocks after inference has settled.
//// Walk values without revisiting names or changing their scopes. The caller
//// decides which statements matter; this module only carries their addresses.
////
//// ```text
//// function -> match arm -> closure -> all three block bodies
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import gleam/list
import gleam/option.{type Option, None, Some}

pub fn in_module(module: ast.Module) -> List(ast.Block) {
  list.flat_map(module.declarations, fn(declaration) {
    case declaration {
      ast.FunctionDeclaration(value) -> in_block(value.body)
      ast.TestDeclaration(value) -> in_block(value.body)
      ast.ClassDeclaration(value) -> in_members(value.members)
      ast.ActorDeclaration(value) -> in_members(value.members)
      ast.InterfaceDeclaration(_)
      | ast.ExternalDeclaration(_)
      | ast.EnumDeclaration(_) -> []
    }
  })
}

fn in_members(members: List(ast.Member)) -> List(ast.Block) {
  list.flat_map(members, fn(member) {
    case member {
      ast.ConstructorMember(value) -> in_block(value.body)
      ast.MethodMember(value) | ast.BehaviourMember(value) ->
        in_block(value.body)
      ast.FieldMember(value) -> optional(value.value)
    }
  })
}

fn in_block(block: ast.Block) -> List(ast.Block) {
  [
    block,
    ..list.flat_map(block.statements, fn(statement) {
      case statement {
        ast.ExpressionStatement(value) -> in_expression(value)
        ast.LetStatement(pattern:, value:, ..) ->
          many([value, ..ast.pattern_expressions(pattern)])
        ast.LetAssertStatement(pattern:, value:, message:, ..) ->
          list.append(
            many([value, ..ast.pattern_expressions(pattern)]),
            optional(message),
          )
      }
    })
  ]
}

fn optional(value: Option(ast.Expression)) -> List(ast.Block) {
  case value {
    Some(value) -> in_expression(value)
    None -> []
  }
}

fn many(values: List(ast.Expression)) -> List(ast.Block) {
  list.flat_map(values, in_expression)
}

fn in_expression(value: ast.Expression) -> List(ast.Block) {
  case value {
    ast.BlockExpression(block) -> in_block(block)
    ast.AnonymousFunction(_, _, body, _) -> in_block(body)
    ast.Loop(iteration, body, _) ->
      list.append(in_block(body), case iteration {
        Some(iteration) ->
          many([
            iteration.iterable,
            ..ast.pattern_expressions(iteration.pattern)
          ])
        None -> []
      })
    ast.Match(subject, branches, _) ->
      list.append(
        in_expression(subject),
        list.flat_map(branches, fn(branch) {
          list.flatten([
            in_expression(branch.body),
            optional(branch.guard),
            many(ast.pattern_expressions(branch.pattern)),
          ])
        }),
      )
    ast.ListExpression(elements, _) | ast.TupleExpression(elements, _) ->
      many(elements)
    ast.ListSpread(elements, tail, _) -> many([tail, ..elements])
    ast.Call(callee, arguments, _) -> many([callee, ..arguments])
    ast.BitArrayExpression(segments, _) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          in_expression(segment.value),
          list.flat_map(segment.options, fn(option) {
            case option {
              ast.NamedOption(..) -> []
              ast.SizeOption(value, _) | ast.UnitOption(value, _) ->
                in_expression(value)
            }
          }),
        )
      })
    ast.FieldAccess(subject, _, _) | ast.TupleAccess(subject, _, _, _) ->
      in_expression(subject)
    ast.Propagate(value, _) | ast.Unary(_, value, _) -> in_expression(value)
    ast.Binary(_, left, right, _) -> many([left, right])
    ast.Assert(condition, message, _) ->
      list.append(in_expression(condition), optional(message))
    ast.Panic(message, _) | ast.Todo(message, _) | ast.Break(message, _) ->
      optional(message)
    ast.Assignment(target, _, value, _) ->
      list.append(in_expression(value), case target {
        ast.AssignVariable(_) -> []
        ast.AssignField(subject:, ..) -> in_expression(subject)
      })
    ast.IntLiteral(..)
    | ast.FloatLiteral(..)
    | ast.StringLiteral(..)
    | ast.BoolLiteral(..)
    | ast.NilLiteral(_)
    | ast.Variable(..)
    | ast.TypeName(..)
    | ast.SelfExpression(_)
    | ast.SuperExpression(_)
    | ast.Continue(_) -> []
  }
}
