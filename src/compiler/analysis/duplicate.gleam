//// Two declarations should not fight over the same name tag.
////
//// Find duplicate module and member declarations using their source spans. Retain
//// both locations so the diagnostic can show the first promise and its
//// replacement.
////
//// ```text
//// f() { 1 } followed by f() { 2 } -> duplicate name
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import utilities/location

pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  let names = list.filter_map(module.declarations, ast.declaration_name)
  list.append(
    duplicates(names, path, "declaration"),
    list.flat_map(module.declarations, declaration(_, path)),
  )
  |> diagnostic.sort
}

fn duplicates(
  names: List(ast.Name),
  path: String,
  kind: String,
) -> List(Diagnostic) {
  let #(_, diagnostics) =
    list.fold(names, #(dict.new(), []), fn(state, name) {
      let #(seen, diagnostics) = state
      case dict.get(seen, name.name) {
        Error(Nil) -> #(dict.insert(seen, name.name, name.span), diagnostics)
        Ok(first) -> {
          let value =
            diagnostic.error(
              "analysis.duplicate_" <> kind,
              "duplicate " <> string.replace(kind, "_", " "),
            )
            |> diagnostic.primary(
              location.new(path, name.span),
              "`" <> name.name <> "` is declared again here",
            )
            |> diagnostic.secondary(
              location.new(path, first),
              "first declared here",
            )
            |> diagnostic.conclusion(case kind {
              "enum_variant" ->
                "Each variant may appear only once in an enum, so `"
                <> name.name
                <> "` would name two values."
              _ ->
                "The name `"
                <> name.name
                <> "` may appear only once in this "
                <> string.replace(kind, "_", " ")
                <> " scope."
            })
          #(seen, [value, ..diagnostics])
        }
      }
    })
  list.reverse(diagnostics)
}

fn declaration(value: ast.Declaration, path: String) -> List(Diagnostic) {
  case value {
    ast.FunctionDeclaration(value) -> callable(value, path)

    ast.ExternalDeclaration(value) ->
      list.append(
        duplicates(
          list.map(value.functions, fn(function) { function.name }),
          path,
          "external_function",
        ),
        list.flat_map(value.functions, fn(function) {
          check_parameters(function.parameters, path)
        }),
      )
    ast.TestDeclaration(value) -> block(value.body, path)
    ast.ClassDeclaration(value) ->
      list.flatten([
        duplicates(value.type_parameters, path, "type_parameter"),
        members(value.members, path),
      ])
    ast.ActorDeclaration(value) ->
      list.flatten([
        duplicates(value.type_parameters, path, "type_parameter"),
        members(value.members, path),
      ])

    ast.EnumDeclaration(value) ->
      duplicates(
        list.map(value.variants, fn(variant) { variant.name }),
        path,
        "enum_variant",
      )
    ast.InterfaceDeclaration(value) ->
      list.flatten([
        duplicates(value.type_parameters, path, "type_parameter"),
        duplicates(
          list.map(value.requirements, fn(item) { item.name }),
          path,
          "member",
        ),
        list.flat_map(value.requirements, fn(item) {
          check_parameters(item.parameters, path)
        }),
      ])
  }
}

fn members(values: List(ast.Member), path: String) -> List(Diagnostic) {
  let names =
    list.map(values, fn(value) {
      case value {
        ast.FieldMember(field) -> field.name
        ast.MethodMember(method) | ast.BehaviourMember(method) -> method.name
        ast.ConstructorMember(value) -> ast.Name("new", value.span)
      }
    })
  list.append(
    duplicates(names, path, "member"),
    list.flat_map(values, fn(value) {
      case value {
        ast.FieldMember(value) -> optional(value.value, expression(_, path))
        ast.MethodMember(value) | ast.BehaviourMember(value) ->
          callable(value, path)
        ast.ConstructorMember(value) ->
          list.append(
            check_parameters(value.parameters, path),
            block(value.body, path),
          )
      }
    }),
  )
}

fn callable(value: ast.Function, path: String) -> List(Diagnostic) {
  list.append(check_parameters(value.parameters, path), block(value.body, path))
}

fn check_parameters(
  values: List(ast.Parameter),
  path: String,
) -> List(Diagnostic) {
  values
  |> list.filter_map(fn(value) {
    case value.name {
      ast.NamedParameter(name) -> Ok(ast.Name(name, value.span))
      ast.DiscardedParameter -> Error(Nil)
    }
  })
  |> duplicates(path, "parameter")
}

fn check_pattern(value: ast.Pattern, path: String) -> List(Diagnostic) {
  list.append(
    duplicates(ast.pattern_bindings(value), path, "pattern_binding"),
    list.flat_map(ast.pattern_expressions(value), expression(_, path)),
  )
}

fn block(value: ast.Block, path: String) -> List(Diagnostic) {
  list.flat_map(value.statements, fn(value) {
    case value {
      ast.LetStatement(pattern:, value:, ..) ->
        list.append(check_pattern(pattern, path), expression(value, path))
      ast.LetAssertStatement(pattern:, value:, message:, ..) ->
        list.flatten([
          check_pattern(pattern, path),
          expression(value, path),
          optional(message, expression(_, path)),
        ])
      ast.ExpressionStatement(value) -> expression(value, path)
    }
  })
}

fn optional(
  value: Option(a),
  check: fn(a) -> List(Diagnostic),
) -> List(Diagnostic) {
  case value {
    Some(value) -> check(value)
    None -> []
  }
}

fn expression(value: ast.Expression, path: String) -> List(Diagnostic) {
  case value {
    ast.IntLiteral(..)
    | ast.FloatLiteral(..)
    | ast.StringLiteral(..)
    | ast.BoolLiteral(..)
    | ast.NilLiteral(..)
    | ast.Variable(..)
    | ast.TypeName(..)
    | ast.SelfExpression(..)
    | ast.SuperExpression(..)
    | ast.Continue(..) -> []
    ast.ListExpression(elements:, ..) | ast.TupleExpression(elements:, ..) ->
      list.flat_map(elements, expression(_, path))
    ast.BitArrayExpression(segments:, ..) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          expression(segment.value, path),
          list.flat_map(segment.options, fn(value) {
            case value {
              ast.NamedOption(..) -> []
              ast.SizeOption(size, _) | ast.UnitOption(size, _) ->
                expression(size, path)
            }
          }),
        )
      })
    ast.BlockExpression(value) -> block(value, path)
    ast.AnonymousFunction(parameters:, body:, ..) ->
      list.append(check_parameters(parameters, path), block(body, path))
    ast.Call(callee:, arguments:, ..) ->
      list.append(
        expression(callee, path),
        list.flat_map(arguments, expression(_, path)),
      )
    ast.FieldAccess(subject:, ..) -> expression(subject, path)
    ast.Propagate(operand:, ..) | ast.Unary(operand:, ..) ->
      expression(operand, path)
    ast.Binary(left:, right:, ..) ->
      list.append(expression(left, path), expression(right, path))
    ast.Match(subject:, branches:, ..) ->
      list.append(
        expression(subject, path),
        list.flat_map(branches, fn(branch) {
          list.flatten([
            check_pattern(branch.pattern, path),
            optional(branch.guard, expression(_, path)),
            expression(branch.body, path),
          ])
        }),
      )
    ast.Loop(iteration:, body:, ..) ->
      list.append(
        optional(iteration, fn(iteration) {
          list.append(
            check_pattern(iteration.pattern, path),
            expression(iteration.iterable, path),
          )
        }),
        block(body, path),
      )
    ast.Break(value:, ..) -> optional(value, expression(_, path))
    ast.Panic(message:, ..) | ast.Todo(message:, ..) ->
      optional(message, expression(_, path))
    ast.Assert(condition:, message:, ..) ->
      list.append(
        expression(condition, path),
        optional(message, expression(_, path)),
      )
    ast.Assignment(target:, value:, ..) ->
      list.append(
        case target {
          ast.AssignVariable(_) -> []
          ast.AssignField(subject:, ..) -> expression(subject, path)
        },
        expression(value, path),
      )
  }
}
