//// Before a new object leaves home, every required field needs a value.
////
//// Track constructor initialization across branches and superclass calls. This
//// structural pass catches missing or repeated initialization without inventing
//// runtime defaults.
////
//// ```text
//// one branch initializes value; another does not -> initialization error
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/constructor as constructor_analysis
import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import utilities/location.{type Span}

type TargetKind {
  DirectField
  ParentConstructor(arity: Int)
}

type FieldContext {
  FieldContext(
    name: ast.Name,
    kind: TargetKind,
    path: String,
    locals: List(String),
    methods: List(String),
  )
}

type Parent {
  Parent(name: ast.Name, arity: Int, explicit: Bool)
}

type LoopKind {
  Infinite
  Iterable
}

type Flow {
  Flow(
    normal: List(Int),
    breaks: List(Int),
    continues: List(Int),
    diagnostics: List(Diagnostic),
  )
}

pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  let classes =
    module.declarations
    |> list.filter_map(fn(value) {
      case value {
        ast.ClassDeclaration(value) -> Ok(#(value.name.name, value))
        _ -> Error(Nil)
      }
    })
    |> dict.from_list
  module.declarations
  |> list.flat_map(fn(value) {
    case value {
      ast.ClassDeclaration(value) ->
        members(value.members, path, parent_constructor(value, classes))
      ast.ActorDeclaration(value) -> members(value.members, path, None)
      ast.FunctionDeclaration(_)
      | ast.InterfaceDeclaration(_)
      | ast.ExternalDeclaration(_)
      | ast.EnumDeclaration(_)
      | ast.TestDeclaration(_) -> []
    }
  })
  |> list.unique
  |> diagnostic.sort
}

fn members(
  values: List(ast.Member),
  path: String,
  parent: Option(Parent),
) -> List(Diagnostic) {
  let fields =
    list.filter_map(values, fn(value) {
      case value {
        ast.FieldMember(value) -> Ok(value)
        ast.ConstructorMember(_)
        | ast.MethodMember(_)
        | ast.BehaviourMember(_) -> Error(Nil)
      }
    })
  list.flat_map(values, fn(value) {
    case value {
      ast.ConstructorMember(constructor) -> {
        let direct =
          list.flat_map(fields, fn(field) {
            let initial = case field.value {
              Some(_) -> [1]
              None -> [0]
            }
            let context =
              FieldContext(
                field.name,
                DirectField,
                path,
                parameter_names(constructor.parameters),
                list.filter_map(values, fn(member) {
                  case member {
                    ast.MethodMember(method) -> Ok(method.name.name)
                    _ -> Error(Nil)
                  }
                }),
              )
            let result = block(constructor.body, initial, context)
            let missing = case list.contains(result.normal, 0) {
              False -> []
              True -> [
                diagnostic.error(
                  "analysis.uninitialized_field",
                  "field is not initialized on every constructor path",
                )
                |> diagnostic.primary(
                  location.new(path, location.point(constructor.body.span.end)),
                  "construction can complete without initializing `"
                    <> field.name.name
                    <> "`",
                )
                |> diagnostic.secondary(
                  location.new(path, field.name.span),
                  "field declared here",
                )
                |> diagnostic.conclusion(
                  "Initialize `"
                  <> field.name.name
                  <> "` exactly once on every path that completes construction.",
                ),
              ]
            }
            list.append(result.diagnostics, missing)
          })
        list.append(direct, check_parent(constructor, parent, path))
      }
      ast.FieldMember(_) | ast.MethodMember(_) | ast.BehaviourMember(_) -> []
    }
  })
}

fn normal(counts: List(Int)) -> Flow {
  Flow(counts, [], [], [])
}

fn counts(values: List(Int)) -> List(Int) {
  values |> list.unique |> list.sort(int.compare)
}

fn join(first: Flow, second: Flow) -> Flow {
  Flow(
    counts(list.append(first.normal, second.normal)),
    counts(list.append(first.breaks, second.breaks)),
    counts(list.append(first.continues, second.continues)),
    list.append(first.diagnostics, second.diagnostics),
  )
}

fn then(flow: Flow, next: fn(List(Int)) -> Flow) -> Flow {
  case flow.normal {
    [] -> flow
    incoming -> {
      let next = next(incoming)
      Flow(
        next.normal,
        counts(list.append(flow.breaks, next.breaks)),
        counts(list.append(flow.continues, next.continues)),
        list.append(flow.diagnostics, next.diagnostics),
      )
    }
  }
}

fn block(value: ast.Block, incoming: List(Int), context: FieldContext) -> Flow {
  let #(flow, _) =
    list.fold(value.statements, #(normal(incoming), context), fn(acc, value) {
      let #(flow, context) = acc
      let next =
        then(flow, fn(incoming) {
          case value {
            ast.ExpressionStatement(value) ->
              expression(value, incoming, context)
            ast.LetStatement(pattern:, value:, ..) ->
              expression(value, incoming, context)
              |> then(expressions(ast.pattern_expressions(pattern), _, context))
            ast.LetAssertStatement(pattern:, value:, message:, ..) ->
              expression(value, incoming, context)
              |> then(expressions(ast.pattern_expressions(pattern), _, context))
              |> then(fn(incoming) {
                case pattern {
                  ast.VariablePattern(..) | ast.DiscardPattern(..) ->
                    normal(incoming)
                  _ -> join(normal(incoming), abort(message, incoming, context))
                }
              })
          }
        })
      let context = case value {
        ast.LetStatement(pattern:, ..) | ast.LetAssertStatement(pattern:, ..) ->
          shadow(pattern, context)
        ast.ExpressionStatement(_) -> context
      }
      #(next, context)
    })
  flow
}

fn parameter_names(parameters: List(ast.Parameter)) -> List(String) {
  list.filter_map(parameters, fn(parameter) {
    case parameter.name {
      ast.NamedParameter(name) -> Ok(name)
      ast.DiscardedParameter -> Error(Nil)
    }
  })
}

fn shadow(pattern: ast.Pattern, context: FieldContext) -> FieldContext {
  FieldContext(
    ..context,
    locals: list.append(
      list.map(ast.pattern_bindings(pattern), fn(name) { name.name }),
      context.locals,
    ),
  )
}

fn expressions(
  values: List(ast.Expression),
  incoming: List(Int),
  context: FieldContext,
) -> Flow {
  list.fold(values, normal(incoming), fn(flow, value) {
    then(flow, expression(value, _, context))
  })
}

fn expression(
  value: ast.Expression,
  incoming: List(Int),
  context: FieldContext,
) -> Flow {
  case value {
    ast.IntLiteral(..)
    | ast.FloatLiteral(..)
    | ast.StringLiteral(..)
    | ast.BoolLiteral(..)
    | ast.NilLiteral(..)
    | ast.TypeName(..)
    | ast.SuperExpression(..) -> normal(incoming)

    ast.SelfExpression(span) ->
      case context.kind {
        DirectField ->
          expression(
            ast.FieldAccess(ast.SelfExpression(span), context.name, span),
            incoming,
            context,
          )
        ParentConstructor(_) -> normal(incoming)
      }
    ast.AnonymousFunction(parameters, _, body, _) -> {
      let captured =
        block(
          body,
          incoming,
          FieldContext(
            ..context,
            locals: list.append(parameter_names(parameters), context.locals),
          ),
        )
      Flow(incoming, [], [], captured.diagnostics)
    }
    ast.Variable(name, span) ->
      case
        context.kind == DirectField
        && { name == context.name.name || list.contains(context.methods, name) }
        && !list.contains(context.locals, name)
      {
        True ->
          expression(
            ast.FieldAccess(ast.SelfExpression(span), context.name, span),
            incoming,
            context,
          )
        False -> normal(incoming)
      }
    ast.BlockExpression(value) -> block(value, incoming, context)
    ast.ListExpression(elements:, ..) | ast.TupleExpression(elements:, ..) ->
      expressions(elements, incoming, context)
    ast.Call(callee:, arguments:, span:) ->
      expressions([callee, ..arguments], incoming, context)
      |> then(fn(incoming) {
        case callee, context.kind {
          ast.FieldAccess(ast.SuperExpression(_), name, _),
            ParentConstructor(arity)
            if name.name == "new"
          ->
            initialize_parent(
              incoming,
              arity,
              list.length(arguments),
              span,
              context,
            )
          _, _ -> normal(incoming)
        }
      })

    ast.FieldAccess(ast.SelfExpression(_), name, span)
      if name.name == context.name.name && context.kind == DirectField
    -> {
      let errors = case list.contains(incoming, 0) {
        False -> []
        True -> [
          diagnostic.error(
            "analysis.field_read_before_initialization",
            "field read before initialization",
          )
          |> diagnostic.primary(
            location.new(context.path, span),
            "`" <> name.name <> "` is not initialized on every path here",
          )
          |> diagnostic.secondary(
            location.new(context.path, context.name.span),
            "field declared here",
          ),
        ]
      }
      Flow(incoming, [], [], errors)
    }
    ast.FieldAccess(ast.SelfExpression(_), _, _) -> normal(incoming)
    ast.FieldAccess(subject:, ..) | ast.TupleAccess(subject:, ..) ->
      expression(subject, incoming, context)
    ast.Propagate(operand:, ..) | ast.Unary(operand:, ..) ->
      expression(operand, incoming, context)
    ast.Binary(operator: operator, left:, right:, ..)
      if operator == ast.And || operator == ast.Or
    ->
      expression(left, incoming, context)
      |> then(fn(incoming) {
        case left {
          ast.BoolLiteral(value, _) ->
            case value, operator {
              False, ast.And | True, ast.Or -> normal(incoming)
              _, _ -> expression(right, incoming, context)
            }
          _ -> join(normal(incoming), expression(right, incoming, context))
        }
      })
    ast.Binary(left:, right:, ..) ->
      expressions([left, right], incoming, context)
    ast.Match(subject:, branches: alternatives, ..) ->
      expression(subject, incoming, context)
      |> then(branches(alternatives, _, context))
    ast.Loop(iteration:, body:, ..) -> {
      let iterable = case iteration {
        Some(value) ->
          expressions(
            [value.iterable, ..ast.pattern_expressions(value.pattern)],
            incoming,
            context,
          )
        None -> normal(incoming)
      }
      iterable
      |> then(fn(incoming) {
        loop(
          body,
          incoming,
          incoming,
          case iteration {
            Some(_) -> Iterable
            None -> Infinite
          },
          case iteration {
            Some(value) -> shadow(value.pattern, context)
            None -> context
          },
        )
      })
    }
    ast.Break(value:, ..) -> {
      let flow = case value {
        Some(value) -> expression(value, incoming, context)
        None -> normal(incoming)
      }
      Flow(
        ..flow,
        normal: [],
        breaks: counts(list.append(flow.breaks, flow.normal)),
      )
    }
    ast.Continue(..) -> Flow([], [], incoming, [])
    ast.Panic(message:, ..) | ast.Todo(message:, ..) -> {
      let flow = case message {
        Some(value) -> expression(value, incoming, context)
        None -> normal(incoming)
      }
      Flow(..flow, normal: [])
    }
    ast.Assert(condition:, message:, ..) ->
      expression(condition, incoming, context)
      |> then(fn(incoming) {
        case condition {
          ast.BoolLiteral(True, _) -> normal(incoming)
          ast.BoolLiteral(False, _) -> abort(message, incoming, context)
          _ -> join(normal(incoming), abort(message, incoming, context))
        }
      })
    ast.Assignment(target:, operator:, value:, span:) -> {
      let subject = case target {
        ast.AssignVariable(_) -> []
        ast.AssignField(ast.SelfExpression(_), _, _) -> []
        ast.AssignField(subject:, ..) -> [subject]
      }
      expressions(list.append(subject, [value]), incoming, context)
      |> then(fn(incoming) {
        case target {
          ast.AssignField(ast.SelfExpression(_), name, _)
            if name.name == context.name.name && context.kind == DirectField
          -> {
            let repeated = list.any(incoming, fn(count) { count >= 1 })
            let errors = case repeated {
              False -> []
              True -> [
                diagnostic.error(
                  "analysis.field_initialized_twice",
                  "field initialized more than once",
                )
                |> diagnostic.primary(
                  location.new(context.path, span),
                  "`" <> name.name <> "` may already be initialized",
                )
                |> diagnostic.secondary(
                  location.new(context.path, context.name.span),
                  "field declared here",
                )
                |> diagnostic.conclusion(
                  "Constructor initialization must assign each field exactly once.",
                ),
              ]
            }
            case operator {
              ast.Assign ->
                Flow(
                  counts(
                    list.map(incoming, fn(count) { int.min(count + 1, 2) }),
                  ),
                  [],
                  [],
                  errors,
                )
              ast.AddAssign | ast.SubtractAssign | ast.MultiplyAssign ->
                Flow(incoming, [], [], [
                  diagnostic.error(
                    "analysis.compound_field_initialization",
                    "compound assignment during field initialization",
                  )
                  |> diagnostic.primary(
                    location.new(context.path, span),
                    "initialize this field with `=`",
                  )
                  |> diagnostic.conclusion(
                    "Constructor field assignment is initialization, not mutation.",
                  ),
                ])
            }
          }
          _ -> normal(incoming)
        }
      })
    }
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
        incoming,
        context,
      )
  }
}

fn loop(
  body: ast.Block,
  entry: List(Int),
  head: List(Int),
  iterable: LoopKind,
  context: FieldContext,
) -> Flow {
  let body_flow = block(body, head, context)
  let next =
    counts(list.flatten([entry, body_flow.normal, body_flow.continues]))
  case next == head {
    False -> loop(body, entry, next, iterable, context)
    True ->
      Flow(
        normal: case iterable {
          Iterable ->
            counts(
              list.flatten([
                entry,
                body_flow.breaks,
                body_flow.normal,
                body_flow.continues,
              ]),
            )
          Infinite -> body_flow.breaks
        },
        breaks: [],
        continues: [],
        diagnostics: body_flow.diagnostics,
      )
  }
}

fn branches(
  values: List(ast.Branch),
  incoming: List(Int),
  context: FieldContext,
) -> Flow {
  case values, incoming {
    [], _ | _, [] -> normal([])
    [branch, ..rest], _ -> {
      let evaluated =
        expressions(ast.pattern_expressions(branch.pattern), incoming, context)
      let branch_context = shadow(branch.pattern, context)
      let guarded = case branch.guard {
        Some(guard) -> evaluated |> then(expression(guard, _, branch_context))
        None -> evaluated
      }
      let selected = case branch.guard {
        Some(ast.BoolLiteral(False, _)) -> Flow(..guarded, normal: [])
        _ -> guarded |> then(expression(branch.body, _, branch_context))
      }
      let irrefutable = case branch.pattern {
        ast.VariablePattern(..) | ast.DiscardPattern(..) -> True
        _ -> False
      }
      let remaining = case irrefutable, branch.guard {
        True, None | True, Some(ast.BoolLiteral(True, _)) -> []
        True, Some(_) -> guarded.normal
        False, _ -> counts(list.append(incoming, guarded.normal))
      }
      join(selected, branches(rest, remaining, context))
    }
  }
}

fn abort(
  message: Option(ast.Expression),
  incoming: List(Int),
  context: FieldContext,
) -> Flow {
  let flow = case message {
    Some(value) -> expression(value, incoming, context)
    None -> normal(incoming)
  }
  Flow(..flow, normal: [])
}

fn parent_constructor(
  value: ast.Class,
  classes: Dict(String, ast.Class),
) -> Option(Parent) {
  case value.superclass {
    Some(ast.NamedType(None, name, _, _)) ->
      case dict.get(classes, name) {
        Ok(parent) ->
          case
            list.find_map(parent.members, fn(member) {
              case member {
                ast.ConstructorMember(value) -> Ok(value)
                _ -> Error(Nil)
              }
            })
          {
            Ok(constructor) ->
              Some(Parent(
                parent.name,
                list.length(constructor.parameters),
                True,
              ))
            Error(Nil) -> Some(Parent(parent.name, 0, False))
          }
        Error(Nil) -> None
      }
    _ -> None
  }
}

fn check_parent(
  constructor: ast.Constructor,
  parent: Option(Parent),
  path: String,
) -> List(Diagnostic) {
  case parent {
    None -> []
    Some(parent) -> {
      let context =
        FieldContext(parent.name, ParentConstructor(parent.arity), path, [], [])
      let initial = case
        parent.explicit || constructor_analysis.has_super_call(constructor.body)
      {
        True -> [0]
        False -> [1]
      }
      let result = block(constructor.body, initial, context)
      let missing = case list.contains(result.normal, 0) {
        False -> []
        True -> [
          diagnostic.error(
            "analysis.super_not_initialized",
            "superclass is not initialized on every constructor path",
          )
          |> diagnostic.primary(
            location.new(path, location.point(constructor.body.span.end)),
            "construction can complete without calling `super.new`",
          )
          |> diagnostic.secondary(
            location.new(path, parent.name.span),
            case parent.explicit {
              True -> "this superclass has an explicit constructor"
              False ->
                "this superclass has an implicit zero-argument constructor"
            },
          )
          |> diagnostic.conclusion(
            "Call `super.new` exactly once on every path that completes construction.",
          ),
        ]
      }
      list.append(result.diagnostics, missing)
    }
  }
}

fn initialize_parent(
  incoming: List(Int),
  expected: Int,
  found: Int,
  span: Span,
  context: FieldContext,
) -> Flow {
  let repeated = case list.any(incoming, fn(count) { count >= 1 }) {
    False -> []
    True -> [
      diagnostic.error(
        "analysis.super_initialized_twice",
        "superclass initialized more than once",
      )
      |> diagnostic.primary(
        location.new(context.path, span),
        "`super.new` may already have been called",
      )
      |> diagnostic.secondary(
        location.new(context.path, context.name.span),
        "superclass declared here",
      )
      |> diagnostic.conclusion(
        "The superclass constructor must run exactly once during construction.",
      ),
    ]
  }
  let arity = case expected == found {
    True -> []
    False -> [
      diagnostic.error(
        "analysis.super_constructor_arity",
        "wrong number of superclass constructor arguments",
      )
      |> diagnostic.primary(
        location.new(context.path, span),
        "found " <> int.to_string(found) <> " arguments",
      )
      |> diagnostic.secondary(
        location.new(context.path, context.name.span),
        "this superclass constructor requires "
          <> int.to_string(expected)
          <> " arguments",
      )
      |> diagnostic.conclusion(
        "Supply exactly the arguments declared by the superclass constructor.",
      ),
    ]
  }
  Flow(
    counts(list.map(incoming, fn(count) { int.min(count + 1, 2) })),
    [],
    [],
    list.append(repeated, arity),
  )
}
