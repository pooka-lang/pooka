//// Some statements need the right room around them.
////
//// Check where control flow, self, superclass access and actor operations are
//// permitted. These are placement rules, so malformed context can be explained
//// before inference starts.
////
//// ```text
//// continue outside a loop -> a context diagnostic
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import gleam/option.{type Option, None, Some}
import utilities/location.{type Span}

type Callable {
  Function
  Constructor
  Behaviour
  Initializer
  Test
}

type Region {
  Ordinary
  Guard
}

type LoopScope {
  OutsideLoop
  InsideLoop
}

type SuperScope {
  NoSuperclass
  HasSuperclass
}

type Context {
  Context(
    callable: Callable,
    region: Region,
    loop: LoopScope,
    superclass: SuperScope,
  )
}

fn scope(callable: Callable, superclass: SuperScope) -> Context {
  Context(callable, Ordinary, OutsideLoop, superclass)
}

pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  list.flat_map(module.declarations, fn(value) {
    case value {
      ast.FunctionDeclaration(value) ->
        block(value.body, scope(Function, NoSuperclass), path)
      ast.ClassDeclaration(value) ->
        members(
          value.members,
          case value.superclass {
            Some(_) -> HasSuperclass
            None -> NoSuperclass
          },
          path,
        )
      ast.ActorDeclaration(value) -> members(value.members, NoSuperclass, path)
      ast.TestDeclaration(value) ->
        block(value.body, scope(Test, NoSuperclass), path)
      ast.InterfaceDeclaration(_)
      | ast.ExternalDeclaration(_)
      | ast.EnumDeclaration(_) -> []
    }
  })
  |> diagnostic.sort
}

fn problem(
  path: String,
  span: Span,
  id: String,
  title: String,
  explanation: String,
) -> Diagnostic {
  diagnostic.error("analysis." <> id, title)
  |> diagnostic.primary(
    location.new(path, span),
    "this expression is not valid here",
  )
  |> diagnostic.conclusion(explanation)
}

fn members(
  values: List(ast.Member),
  superclass: SuperScope,
  path: String,
) -> List(Diagnostic) {
  list.flat_map(values, fn(value) {
    case value {
      ast.ConstructorMember(value) ->
        block(value.body, scope(Constructor, superclass), path)
      ast.MethodMember(value) ->
        block(value.body, scope(Function, superclass), path)
      ast.FieldMember(value) ->
        optional(value.value, scope(Initializer, superclass), path)
      ast.BehaviourMember(value) ->
        list.append(
          behaviour_annotation(value, path),
          block(value.body, scope(Behaviour, superclass), path),
        )
    }
  })
}

fn behaviour_annotation(value: ast.Function, path: String) -> List(Diagnostic) {
  case value.return_type {
    None | Some(ast.NamedType(None, "Nil", [], _)) -> []
    Some(_) -> [
      problem(
        path,
        value.name.span,
        "behaviour_result",
        "behaviour result must be Nil",
        "An asynchronous behaviour has no reply value. Its result annotation may only be `Nil`.",
      ),
    ]
  }
}

fn block(value: ast.Block, context: Context, path: String) -> List(Diagnostic) {
  list.flat_map(value.statements, fn(value) {
    case value {
      ast.LetStatement(pattern:, value:, ..) ->
        list.append(
          expressions(ast.pattern_expressions(pattern), context, path),
          expression(value, context, path),
        )
      ast.LetAssertStatement(pattern:, value:, message:, ..) ->
        list.flatten([
          expressions(ast.pattern_expressions(pattern), context, path),
          expression(value, context, path),
          optional(message, context, path),
        ])
      ast.ExpressionStatement(value) -> expression(value, context, path)
    }
  })
}

fn optional(
  value: Option(ast.Expression),
  context: Context,
  path: String,
) -> List(Diagnostic) {
  case value {
    Some(value) -> expression(value, context, path)
    None -> []
  }
}

fn expressions(
  values: List(ast.Expression),
  context: Context,
  path: String,
) -> List(Diagnostic) {
  list.flat_map(values, expression(_, context, path))
}

fn expression(
  value: ast.Expression,
  context: Context,
  path: String,
) -> List(Diagnostic) {
  case value {
    ast.SelfExpression(span) ->
      case context.callable {
        Constructor -> []
        Function | Behaviour | Initializer | Test -> [
          problem(
            path,
            span,
            "self_outside_constructor",
            "self outside a constructor",
            "Explicit `self` is only available during construction. Ordinary methods access fields and methods by name.",
          ),
        ]
      }
    ast.SuperExpression(span) ->
      case context.superclass {
        HasSuperclass -> []
        NoSuperclass -> [
          problem(
            path,
            span,
            "super_without_superclass",
            "super without a superclass",
            "`super` refers to the immediate superclass and is only available in a subclass implementation.",
          ),
        ]
      }
    ast.Propagate(operand, span) -> {
      let own = case context.region, context.callable {
        Ordinary, Function -> []
        Guard, _ -> [
          problem(
            path,
            span,
            "propagation_context",
            "result propagation in a match guard",
            "`?` cannot propagate from a match guard. Handle the Result before matching or inside the branch body.",
          ),
        ]
        Ordinary, Constructor
        | Ordinary, Behaviour
        | Ordinary, Initializer
        | Ordinary, Test
        -> [
          problem(
            path,
            span,
            "propagation_context",
            "result propagation outside a function",
            "`?` must be inside a function or ordinary method returning Result. Constructors, behaviours, field initializers and tests cannot propagate a Result.",
          ),
        ]
      }
      list.append(own, expression(operand, context, path))
    }
    ast.Break(value, span) ->
      list.append(
        loop_control(span, "break", context, path),
        optional(value, context, path),
      )
    ast.Continue(span) -> loop_control(span, "continue", context, path)
    ast.Loop(iteration, body, _) ->
      list.append(
        case iteration {
          Some(value) ->
            list.append(
              expressions(ast.pattern_expressions(value.pattern), context, path),
              expression(value.iterable, context, path),
            )
          None -> []
        },
        block(body, Context(..context, loop: InsideLoop), path),
      )
    ast.AnonymousFunction(_, _, body, _) ->
      block(body, scope(Function, context.superclass), path)
    ast.Match(subject, branches, _) ->
      list.append(
        expression(subject, context, path),
        list.flat_map(branches, fn(branch) {
          list.flatten([
            expressions(ast.pattern_expressions(branch.pattern), context, path),
            optional(branch.guard, Context(..context, region: Guard), path),
            expression(branch.body, context, path),
          ])
        }),
      )
    ast.BlockExpression(value) -> block(value, context, path)
    ast.ListExpression(elements:, ..) | ast.TupleExpression(elements:, ..) ->
      expressions(elements, context, path)
    ast.BitArrayExpression(segments:, ..) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          expression(segment.value, context, path),
          list.flat_map(segment.options, fn(value) {
            case value {
              ast.NamedOption(..) -> []
              ast.SizeOption(size, _) | ast.UnitOption(size, _) ->
                expression(size, context, path)
            }
          }),
        )
      })
    ast.Call(callee:, arguments:, ..) ->
      list.append(
        expression(callee, context, path),
        expressions(arguments, context, path),
      )
    ast.TupleAccess(subject:, ..) -> expression(subject, context, path)
    ast.FieldAccess(subject:, name:, span:) -> {
      let own = case subject, name.name, context.superclass, context.callable {
        ast.SuperExpression(_), "new", HasSuperclass, Function
        | ast.SuperExpression(_), "new", HasSuperclass, Behaviour
        | ast.SuperExpression(_), "new", HasSuperclass, Initializer
        | ast.SuperExpression(_), "new", HasSuperclass, Test
        -> [
          problem(
            path,
            span,
            "super_constructor_outside_constructor",
            "superclass initialization outside a constructor",
            "`super.new` initializes the current value and is only available inside the subclass constructor.",
          ),
        ]
        _, _, _, _ -> []
      }
      list.append(own, expression(subject, context, path))
    }
    ast.Unary(operand:, ..) -> expression(operand, context, path)
    ast.Binary(left:, right:, ..) -> expressions([left, right], context, path)
    ast.Assert(condition:, message:, ..) ->
      list.append(
        expression(condition, context, path),
        optional(message, context, path),
      )
    ast.Panic(message:, ..) | ast.Todo(message:, ..) ->
      optional(message, context, path)
    ast.Assignment(target:, value:, ..) ->
      list.append(
        case target {
          ast.AssignVariable(_) -> []
          ast.AssignField(subject:, ..) -> expression(subject, context, path)
        },
        expression(value, context, path),
      )
    ast.IntLiteral(..)
    | ast.FloatLiteral(..)
    | ast.StringLiteral(..)
    | ast.BoolLiteral(..)
    | ast.NilLiteral(..)
    | ast.Variable(..)
    | ast.TypeName(..) -> []
  }
}

fn loop_control(
  span: Span,
  keyword: String,
  context: Context,
  path: String,
) -> List(Diagnostic) {
  case context.loop {
    InsideLoop -> []
    OutsideLoop -> [
      problem(
        path,
        span,
        keyword <> "_outside_loop",
        keyword <> " outside a loop",
        "`"
          <> keyword
          <> "` needs an enclosing loop in the same callable. An anonymous function cannot control its caller's loop.",
      ),
    ]
  }
}
