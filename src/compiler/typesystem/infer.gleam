//// Walk the expression and let each small promise constrain the next.
////
//// Infer expressions under lexical and control-flow contexts, recording types by
//// source span. Expected callback parameters arrive before their bodies are
//// checked; rigid annotations prevent a universal promise from becoming one
//// convenient concrete type.
////
//// ```text
//// apply(User("Ada"), fn(user) { user.name }) gives user the User type
//// ```
////
//// There are four useful rooms to visit before changing an inference rule:
////
//// - expression_type records each expression result for later code generation.
//// - require checks directional compatibility and retains diagnostic evidence.
//// - callable_expected establishes parameters, universal promises and a return.
//// - binding_statement generalizes only variables that are not captured outside.
////
//// Environment is lexical scope. Context carries return, loop, generic and actor
//// constraints; neither should accidentally leak out of a nested callable.
//// State carries substitutions and nominal metadata shared by the inference work.
//// Diagnostics travel beside a recoverable result so one mistake can be reported
//// without making every subsequent name look unknown.
////
//// For example, a callback reading user.name needs User before its body is
//// checked. A generic identity annotation needs the opposite caution: its a must
//// stay rigid until the implementation has proved it did not secretly mean Int.

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import compiler/typesystem/bit_array
import compiler/typesystem/bit_array_layout
import compiler/typesystem/exhaustiveness
import compiler/typesystem/monotype.{type Type}
import compiler/typesystem/nominal
import compiler/typesystem/scheme.{type Scheme}
import compiler/typesystem/unify
import diagnostics/diagnostic.{type Diagnostic}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import utilities/location.{type Span}
import utilities/text

pub type Binding {
  Binding(scheme: Scheme, span: Span)

  ModuleBinding(
    identity: String,
    declarations: Dict(String, Scheme),
    namespaces: Dict(String, Dict(String, Scheme)),
  )

  NamespaceBinding(name: String, functions: Dict(String, Scheme))
  ClassBinding(identity: nominal.Identity)
  InterfaceBinding(identity: nominal.Identity)

  EnumBinding(identity: nominal.Identity)
}

pub type Environment =
  Dict(String, Binding)

pub type Unsupported {
  Unsupported(span: Span, feature: String)
}

type Region {
  Ordinary
  Guard
}

type Context {
  Context(
    returns: Option(Type),
    loop: Option(Type),
    region: Region,
    generics: Dict(String, Type),
    constructing: Option(nominal.Identity),
    actor_writes: Bool,
  )
}

pub type Inferred {
  Inferred(type_: Type, state: unify.State, diagnostics: List(Diagnostic))
}

/// Infer one expression under the supplied bindings and settle its finalized
/// primitive constraints. Return diagnostics together with the inferred state.
///
/// ```text
/// fn(x) { x } -> fn(a) -> a; [1, "oak"] -> element mismatch
/// ```
pub fn infer(
  expression: ast.Expression,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  let context = Context(None, None, Ordinary, dict.new(), None, False)
  let #(core, state) = core_environment(state)
  expression_type(
    expression,
    dict.merge(core, environment),
    state,
    path,
    context,
  )
  |> result.map(fn(value) {
    let #(state, errors) =
      unify.settle_primitives(value.state, unify.pending_variables(value.state))
    let type_ = case diagnostic.has_errors(errors) {
      True -> monotype.ErrorType
      False -> unify.apply(value.type_, state)
    }
    Inferred(type_, state, list.append(value.diagnostics, errors))
  })
}

fn inferred(type_: Type, state: unify.State) -> Inferred {
  Inferred(type_, state, [])
}

/// Check a found value against an expected type through directional subsumption.
/// Failure preserves the original state and adds labelled evidence.
///
/// ```text
/// expected Ref, found Tmp -> accepted; expected Tmp, found Ref -> rejected
/// ```
fn require(
  value: Inferred,
  expected: Type,
  expected_span: Span,
  found_span: Span,
  path: String,
  reason: String,
) -> Inferred {
  let origin =
    unify.Origin(
      location.new(path, expected_span),
      location.new(path, found_span),
      reason,
    )

  case unify.subsume(expected, value.type_, origin, value.state) {
    Ok(state) -> Inferred(..value, state:)
    Error(error) ->
      Inferred(
        monotype.ErrorType,
        value.state,
        list.append(value.diagnostics, [unify.to_diagnostic(error)]),
      )
  }
}

/// Instantiate ordinary bound schemes at a name use, while preserving the special
/// identities of classes, modules and interfaces.
///
/// ```text
/// two uses of generalized identity receive fresh argument variables
/// ```
fn lookup(
  name: String,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Inferred {
  case dict.get(environment, name) {
    Ok(Binding(scheme, _)) -> {
      let #(type_, state) = scheme.instantiate(scheme, state)
      inferred(type_, state)
    }
    Ok(ClassBinding(identity)) -> class_constructor(identity, span, state, path)
    Ok(InterfaceBinding(_)) ->
      Inferred(monotype.ErrorType, state, [
        diagnostic.error("type.interface_as_value", "interface used as a value")
        |> diagnostic.primary(
          location.new(path, span),
          "An interface describes behavior and has no constructor.",
        ),
      ])
    Ok(NamespaceBinding(..)) ->
      Inferred(monotype.ErrorType, state, [namespace_as_value(name, span, path)])
    Ok(EnumBinding(identity)) ->
      Inferred(monotype.ErrorType, state, [
        enum_as_value(identity, span, state, path),
      ])
    Ok(ModuleBinding(identity, _, _)) ->
      Inferred(monotype.ErrorType, state, [
        diagnostic.error("type.module_as_value", "module used as a value")
        |> diagnostic.primary(
          location.new(path, span),
          "`" <> name <> "` names module `" <> identity <> "`",
        )
        |> diagnostic.conclusion(
          "Select a public declaration with module qualification.",
        ),
      ])
    Error(Nil) ->
      Inferred(monotype.ErrorType, state, [
        diagnostic.error("type.unknown_name", "unknown name")
        |> diagnostic.primary(
          location.new(path, span),
          "`" <> name <> "` is not in scope",
        )
        |> diagnostic.conclusion(
          "No lexical binding named `" <> name <> "` is available here.",
        ),
      ])
  }
}

/// Infer and remember an expression's type by source span. The remembered result
/// is the bridge from inference to typed lowering.
///
/// ```text
/// source span for 5 / 2 -> Int metadata
/// ```
fn expression_type(
  value: ast.Expression,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  expression_inner(value, environment, state, path, context)
  |> result.map(fn(report) {
    Inferred(
      ..report,
      state: unify.remember_expression(
        report.state,
        path,
        ast.expression_span(value),
        report.type_,
      ),
    )
  })
}

/// Dispatch inference by expression shape and lexical context. Compound
/// expressions carry both substitutions and diagnostics from their children.
///
/// ```text
/// #(1, True) -> #(Int, Bool)
/// ```
fn expression_inner(
  value: ast.Expression,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  case value {
    ast.IntLiteral(..) -> Ok(inferred(monotype.IntType, state))
    ast.FloatLiteral(..) -> Ok(inferred(monotype.FloatType, state))
    ast.StringLiteral(..) -> Ok(inferred(monotype.StringType, state))
    ast.BoolLiteral(..) -> Ok(inferred(monotype.BoolType, state))
    ast.NilLiteral(..) -> Ok(inferred(monotype.NilType, state))
    ast.Variable(name, span) | ast.TypeName(name, span) ->
      Ok(lookup(name, span, environment, state, path))
    ast.TupleExpression(elements, _) -> {
      use #(elements, state, diagnostics) <- result.try(infer_many(
        elements,
        environment,
        state,
        path,
        context,
      ))
      Ok(Inferred(monotype.TupleType(elements), state, diagnostics))
    }
    ast.ListExpression(elements, span) -> {
      let #(element, state) = unify.fresh(state)

      use #(found, state, diagnostics) <- result.try(infer_many(
        elements,
        environment,
        state,
        path,
        context,
      ))
      let state = join_into(element, found, span, path, state)
      let report =
        list.zip(elements, found)
        |> list.fold(Inferred(element, state, diagnostics), fn(report, pair) {
          let #(value, found) = pair
          let checked =
            require(
              Inferred(found, report.state, []),
              element,
              span,
              ast.expression_span(value),
              path,
              "All elements of a list must have the same type.",
            )
          Inferred(
            element,
            checked.state,
            list.append(report.diagnostics, checked.diagnostics),
          )
        })
      Ok(
        Inferred(
          ..report,
          type_: monotype.ListType(unify.apply(element, report.state)),
        ),
      )
    }
    ast.BlockExpression(block) ->
      block_type(block, environment, state, path, context)
    ast.AnonymousFunction(parameters, return_type, body, span) ->
      callable(
        parameters,
        return_type,
        body,
        span,
        environment,
        state,
        path,
        Context(..context, actor_writes: False),
      )
    ast.Call(callee, arguments, span) -> {
      use <- result.lazy_unwrap(
        enum_subject_of(callee, environment, state, path)
        |> result.map(fn(found) {
          Ok(enum_call(found.0, found.1, callee, arguments, span, state, path))
        }),
      )
      use callee_report <- result.try(expression_type(
        callee,
        environment,
        state,
        path,
        context,
      ))
      use #(argument_types, state, diagnostics) <- result.try(infer_arguments(
        arguments,
        callee_report.type_,
        environment,
        callee_report.state,
        path,
        context,
      ))
      use <- known_function_call(
        callee_report,
        ast.expression_span(callee),
        arguments,
        argument_types,
        Inferred(callee_report.type_, state, diagnostics),
        path,
      )
      let #(result_type, state) = unify.fresh(state)
      let checked =
        require(
          Inferred(
            monotype.FunctionType(argument_types, result_type),
            state,
            list.append(callee_report.diagnostics, diagnostics),
          ),
          callee_report.type_,
          ast.expression_span(callee),
          span,
          path,
          "A call must supply the parameters required by its function.",
        )
      Ok(
        Inferred(..checked, type_: case callee_report.type_, checked.type_ {
          monotype.ErrorType, _ | _, monotype.ErrorType -> monotype.ErrorType
          _, _ -> unify.apply(result_type, checked.state)
        }),
      )
    }
    ast.Unary(ast.Not, operand, span) -> {
      use found <- result.try(expression_type(
        operand,
        environment,
        state,
        path,
        context,
      ))
      Ok(require(
        found,
        monotype.BoolType,
        span,
        ast.expression_span(operand),
        path,
        "Boolean negation requires Bool.",
      ))
    }
    ast.Binary(operator, left, right, span)
      if operator == ast.And || operator == ast.Or
    -> {
      use left_report <- result.try(expression_type(
        left,
        environment,
        state,
        path,
        context,
      ))
      let left_report =
        require(
          left_report,
          monotype.BoolType,
          span,
          ast.expression_span(left),
          path,
          "Boolean operators require Bool operands.",
        )
      use right_report <- result.try(expression_type(
        right,
        environment,
        left_report.state,
        path,
        context,
      ))
      let right_report =
        require(
          right_report,
          monotype.BoolType,
          span,
          ast.expression_span(right),
          path,
          "Boolean operators require Bool operands.",
        )
      Ok(Inferred(
        monotype.BoolType,
        right_report.state,
        list.append(left_report.diagnostics, right_report.diagnostics),
      ))
    }

    ast.Binary(operator, left, right, span)
      if operator == ast.BitAnd || operator == ast.BitOr
    -> {
      let reason = "Bitwise operators require Int operands."
      use left_report <- result.try(expression_type(
        left,
        environment,
        state,
        path,
        context,
      ))
      let left_found = left_report.type_
      let left_report =
        require(
          left_report,
          monotype.IntType,
          span,
          ast.expression_span(left),
          path,
          reason,
        )
      use right_report <- result.try(expression_type(
        right,
        environment,
        left_report.state,
        path,
        context,
      ))
      let right_found = right_report.type_
      let right_report =
        require(
          right_report,
          monotype.IntType,
          span,
          ast.expression_span(right),
          path,
          reason,
        )

      let boolean =
        unify.apply(left_found, right_report.state) == monotype.BoolType
        || unify.apply(right_found, right_report.state) == monotype.BoolType
      let diagnostics =
        list.append(left_report.diagnostics, right_report.diagnostics)
      let diagnostics = case boolean, diagnostics {
        True, [first, ..rest] -> [
          diagnostic.help(first, case operator {
            ast.BitAnd -> "Boolean conjunction is written `&&`."
            _ -> "Boolean disjunction is written `||`."
          }),
          ..rest
        ]
        _, _ -> diagnostics
      }
      Ok(Inferred(monotype.IntType, right_report.state, diagnostics))
    }
    ast.Binary(operator, left, right, _span)
      if operator == ast.Equal || operator == ast.NotEqual
    -> {
      use left_report <- result.try(expression_type(
        left,
        environment,
        state,
        path,
        context,
      ))
      use right_report <- result.try(expression_type(
        right,
        environment,
        left_report.state,
        path,
        context,
      ))
      let expected = case
        unify.join(right_report.state, [left_report.type_, right_report.type_])
      {
        Ok(joined) -> joined
        Error(Nil) -> left_report.type_
      }
      let left_report =
        require(
          Inferred(..left_report, state: right_report.state),
          expected,
          ast.expression_span(left),
          ast.expression_span(left),
          path,
          "Equality operands must have compatible types.",
        )
      let right_report =
        require(
          Inferred(..right_report, state: left_report.state),
          expected,
          ast.expression_span(left),
          ast.expression_span(right),
          path,
          "Equality operands must have the same type.",
        )
      Ok(Inferred(
        monotype.BoolType,
        right_report.state,
        list.append(left_report.diagnostics, right_report.diagnostics),
      ))
    }
    ast.Unary(ast.Negate, operand, span) -> {
      use found <- result.try(expression_type(
        operand,
        environment,
        state,
        path,
        context,
      ))
      Ok(check_primitive(found, found.type_, unify.Numeric, span, path))
    }
    ast.Binary(ast.PipeOperator, left, right, span) -> {
      let call = case right {
        ast.Call(callee, arguments, _) ->
          ast.Call(callee, [left, ..arguments], span)
        _ -> ast.Call(right, [left], span)
      }
      expression_type(call, environment, state, path, context)
    }
    ast.Binary(operator, left, right, span) ->
      primitive_operator(
        operator,
        left,
        right,
        span,
        environment,
        state,
        path,
        context,
      )
    ast.TupleAccess(subject:, index:, index_span:, ..) -> {
      use found <- result.try(expression_type(
        subject,
        environment,
        state,
        path,
        context,
      ))
      let subject_type = unify.apply(found.type_, found.state)
      case subject_type {
        monotype.ErrorType -> Ok(found)
        monotype.TupleType(elements) -> {
          case list.first(list.drop(elements, index)) {
            Ok(type_) -> Ok(Inferred(type_, found.state, found.diagnostics))
            Error(_) ->
              Ok(
                Inferred(monotype.ErrorType, found.state, [
                  diagnostic.error(
                    "type.tuple_index_out_of_bounds",
                    "tuple index is out of bounds",
                  )
                    |> diagnostic.primary(
                      location.new(path, index_span),
                      "This tuple has "
                        <> int.to_string(list.length(elements))
                        <> " elements; indices start at zero.",
                    ),
                  ..found.diagnostics
                ]),
              )
          }
        }
        _ ->
          Ok(
            Inferred(monotype.ErrorType, found.state, [
              diagnostic.error(
                "type.invalid_tuple_subject",
                "tuple projection requires a tuple",
              )
                |> diagnostic.primary(
                  location.new(path, ast.expression_span(subject)),
                  "The receiver must have a known tuple type.",
                )
                |> diagnostic.help(
                  "If its type cannot be inferred, annotate the parameter with its tuple type.",
                ),
              ..found.diagnostics
            ]),
          )
      }
    }
    ast.FieldAccess(ast.SuperExpression(_), name, span) ->
      super_member(name, span, state, path, context)

    ast.FieldAccess(subject, name, span) -> {
      use <- result.lazy_unwrap(
        enum_subject(subject, environment, state, path)
        |> result.map(fn(enum) { Ok(enum_variant(enum, name, state, path)) }),
      )

      use <- result.lazy_unwrap(
        enum_through_module(subject, name, environment, state, path)
        |> result.map(fn(identity) {
          Ok(
            Inferred(monotype.ErrorType, state, [
              enum_as_value(identity, span, state, path),
            ]),
          )
        }),
      )
      let class = case subject, name.name {
        ast.TypeName(class, _), "new" ->
          unify.named_class(state, path, "", class)
        ast.FieldAccess(ast.Variable(alias, _), class, _), "new" ->
          case dict.get(environment, alias) {
            Ok(ModuleBinding(..)) ->
              unify.named_class(state, path, alias, class.name)
            _ -> Error(Nil)
          }
        ast.Variable(alias, _), _ ->
          case dict.get(environment, alias) {
            Ok(ModuleBinding(..)) ->
              unify.named_class(state, path, alias, name.name)
            _ -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
      case class {
        Ok(class) ->
          Ok(class_constructor(nominal.identity(class), span, state, path))
        Error(Nil) ->
          field_access(subject, name, span, environment, state, path, context)
      }
    }
    ast.SelfExpression(span) ->
      case context.constructing {
        Some(identity) ->
          case unify.class(state, identity) {
            Ok(class) -> Ok(inferred(nominal.type_(class), state))
            Error(Nil) ->
              Error(Unsupported(span, "unknown constructor receiver"))
          }
        None -> Error(Unsupported(span, "self outside construction"))
      }
    ast.Assignment(ast.AssignVariable(name), operator, value, span) ->
      actor_assignment(
        name,
        operator,
        value,
        span,
        environment,
        state,
        path,
        context,
      )
    ast.Assignment(target, ast.Assign, value, span) ->
      constructor_assignment(
        target,
        value,
        span,
        environment,
        state,
        path,
        context,
      )
    ast.SuperExpression(span) | ast.Assignment(span:, ..) ->
      Error(Unsupported(span, "superclass and actor assignment inference"))
    ast.Match(subject, branches, span) -> {
      let subject_expression = subject
      let subject_span = ast.expression_span(subject)
      use subject <- result.try(expression_type(
        subject,
        environment,
        state,
        path,
        context,
      ))
      let #(result_type, state) = unify.fresh(subject.state)
      let evidence = case branches {
        [first, ..] -> ast.expression_span(first.body)
        [] -> span
      }
      use #(report, bodies) <- result.try(
        list.try_fold(
          branches,
          #(Inferred(result_type, state, subject.diagnostics), []),
          fn(acc, branch) {
            let #(report, bodies) = acc
            let branch_state = report.state
            use pattern <- result.try(bind_pattern(
              branch.pattern,
              subject.type_,
              environment,
              report.state,
              path,
            ))
            let branch_environment =
              narrow_subject(subject_expression, branch.pattern, pattern)
            use guard <- result.try(case branch.guard {
              None -> Ok(inferred(monotype.BoolType, pattern.state))
              Some(guard) ->
                expression_type(
                  guard,
                  branch_environment,
                  pattern.state,
                  path,
                  Context(..context, region: Guard),
                )
                |> result.map(require(
                  _,
                  monotype.BoolType,
                  branch.span,
                  ast.expression_span(guard),
                  path,
                  "A match guard must evaluate to Bool.",
                ))
            })
            use body <- result.try(expression_type(
              branch.body,
              branch_environment,
              guard.state,
              path,
              context,
            ))
            let body =
              reject_pattern_escape(
                pattern,
                environment,
                subject.type_,
                branch_state,
                body,
                context,
                path,
                branch,
              )
            Ok(
              #(
                Inferred(
                  result_type,
                  body.state,
                  list.flatten([
                    report.diagnostics,
                    pattern.diagnostics,
                    guard.diagnostics,
                    body.diagnostics,
                  ]),
                ),
                [#(body.type_, ast.expression_span(branch.body)), ..bodies],
              ),
            )
          },
        ),
      )

      let bodies = list.reverse(bodies)
      let report =
        Inferred(
          ..report,
          state: join_into(
            result_type,
            list.map(bodies, fn(body) { body.0 }),
            evidence,
            path,
            report.state,
          ),
        )
      let report =
        list.fold(bodies, report, fn(report, body) {
          let checked =
            require(
              Inferred(body.0, report.state, []),
              result_type,
              evidence,
              body.1,
              path,
              "All match branches must produce compatible types.",
            )
          Inferred(
            result_type,
            checked.state,
            list.append(report.diagnostics, checked.diagnostics),
          )
        })
      let coverage = case diagnostic.has_errors(report.diagnostics) {
        True -> []
        False ->
          exhaustiveness.check_in(
            unify.apply(subject.type_, report.state),
            branches,
            path,
            subject_span,
            report.state,
          )
      }
      Ok(
        Inferred(
          ..report,
          diagnostics: list.append(report.diagnostics, coverage),
        ),
      )
    }
    ast.Panic(message:, span:) | ast.Todo(message:, span:) -> {
      use checked <- result.try(check_message(
        message,
        environment,
        state,
        path,
        context,
        span,
      ))
      let #(bottom, state) = unify.fresh(checked.state)
      Ok(Inferred(bottom, state, checked.diagnostics))
    }
    ast.Assert(condition, message, span) -> {
      use condition <- result.try(expression_type(
        condition,
        environment,
        state,
        path,
        context,
      ))
      let condition =
        require(
          condition,
          monotype.BoolType,
          span,
          span,
          path,
          "An assertion condition must evaluate to Bool.",
        )
      use message <- result.try(check_message(
        message,
        environment,
        condition.state,
        path,
        context,
        span,
      ))
      Ok(Inferred(
        monotype.NilType,
        message.state,
        list.append(condition.diagnostics, message.diagnostics),
      ))
    }
    ast.Propagate(operand, span) -> {
      use operand <- result.try(expression_type(
        operand,
        environment,
        state,
        path,
        context,
      ))
      let #(success, state) = unify.fresh(operand.state)
      let #(error, state) = unify.fresh(state)
      let operand =
        require(
          Inferred(..operand, state:),
          monotype.ResultType(success, error),
          span,
          span,
          path,
          "Postfix `?` only propagates a core Result value.",
        )
      case operand.type_, context.returns, context.region {
        monotype.ErrorType, _, _ -> Ok(operand)
        _, Some(return_type), Ordinary -> {
          let #(returned_success, state) = unify.fresh(operand.state)
          let result =
            require(
              Inferred(return_type, state, operand.diagnostics),
              monotype.ResultType(returned_success, error),
              span,
              span,
              path,
              "The enclosing function must return Result with the same error type.",
            )
          Ok(
            Inferred(..result, type_: case result.type_ {
              monotype.ErrorType -> monotype.ErrorType
              _ -> unify.apply(success, result.state)
            }),
          )
        }
        _, _, _ ->
          Ok(invalid_context(
            operand,
            span,
            path,
            "Result propagation requires an enclosing function and cannot occur in a match guard.",
          ))
      }
    }
    ast.Loop(None, body, span) -> {
      let #(loop_type, state) = unify.fresh(state)
      use report <- result.try(block_type(
        body,
        environment,
        state,
        path,
        Context(..context, loop: Some(loop_type)),
      ))
      Ok(finish_loop(report, loop_type, span, path, False))
    }
    ast.Loop(Some(iteration), body, span) ->
      infer_iteration(iteration, body, span, environment, state, path, context)
    ast.Break(value, span) -> {
      use value <- result.try(case value {
        None -> Ok(inferred(monotype.NilType, state))
        Some(value) -> expression_type(value, environment, state, path, context)
      })
      let checked = case context.loop {
        None ->
          invalid_context(
            value,
            span,
            path,
            "A break expression needs a loop in the same callable.",
          )
        Some(loop_type) ->
          Inferred(
            ..value,
            state: unify.remember_break(
              value.state,
              loop_type,
              value.type_,
              span,
            ),
          )
      }
      let #(bottom, state) = unify.fresh(checked.state)
      Ok(Inferred(bottom, state, checked.diagnostics))
    }
    ast.Continue(span) -> {
      let #(bottom, state) = unify.fresh(state)
      let value = inferred(bottom, state)
      Ok(case context.loop {
        Some(_) -> value
        None ->
          invalid_context(
            value,
            span,
            path,
            "A continue expression needs a loop in the same callable.",
          )
      })
    }
    ast.BitArrayExpression(segments, _) ->
      list.try_fold(
        segments,
        inferred(monotype.BitArrayType, state),
        fn(report, segment) {
          use options <- result.try(
            bit_array.analyze(segment.options, path)
            |> result.map_error(fn(error) {
              Unsupported(error.span, error.feature)
            }),
          )
          use value <- result.try(expression_type(
            segment.value,
            environment,
            report.state,
            path,
            context,
          ))
          let value =
            require(
              value,
              options.value_type,
              segment.span,
              ast.expression_span(segment.value),
              path,
              "A bit-array segment value must match its representation.",
            )
          use sizes <- result.try(segment_sizes(
            options.sizes,
            environment,
            value.state,
            path,
            context,
          ))
          Ok(Inferred(
            monotype.BitArrayType,
            sizes.state,
            list.flatten([
              report.diagnostics,
              options.diagnostics,
              case value.type_, diagnostic.has_errors(value.diagnostics) {
                monotype.ErrorType, _ | _, True -> []
                _, False ->
                  bit_array_layout.construction_layout(
                    segment.value,
                    segment.options,
                    options,
                    segment.span,
                    path,
                  )
              },
              value.diagnostics,
              sizes.diagnostics,
            ]),
          ))
        },
      )
  }
}

/// Use the callee's parameter types while walking arguments left to right.
/// Earlier arguments can establish the receiver type needed inside a later
/// callback.
///
/// ```text
/// apply(User("Ada"), fn(user) { user.name }) checks the field with user: User
/// ```
fn infer_arguments(
  values: List(ast.Expression),
  callee: Type,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(#(List(Type), unify.State, List(Diagnostic)), Unsupported) {
  let parameters = case unify.apply(callee, state) {
    monotype.FunctionType(parameters, _) -> parameters
    _ -> []
  }
  case list.length(parameters) == list.length(values) {
    True -> {
      use #(types, state, diagnostics) <- result.try(
        list.try_fold(
          list.zip(values, parameters),
          #([], state, []),
          fn(acc, pair) {
            let #(types, state, diagnostics) = acc
            let #(value, expected) = pair
            use found <- result.try(case value {
              ast.AnonymousFunction(parameters, annotation, body, span) ->
                callable_expected(
                  parameters,
                  annotation,
                  body,
                  span,
                  environment,
                  state,
                  path,
                  Context(..context, actor_writes: False),
                  Some(expected),
                )
              _ -> expression_type(value, environment, state, path, context)
            })
            let state = case
              unify.unify(
                found.type_,
                expected,
                unify.Origin(
                  location.new(path, ast.expression_span(value)),
                  location.new(path, ast.expression_span(value)),
                  "A call argument supplies its parameter type.",
                ),
                found.state,
              )
            {
              Ok(state) -> state
              Error(_) -> found.state
            }
            Ok(#(
              [found.type_, ..types],
              state,
              list.append(diagnostics, found.diagnostics),
            ))
          },
        ),
      )
      Ok(#(list.reverse(types), state, diagnostics))
    }
    False -> infer_many(values, environment, state, path, context)
  }
}

/// Infer a sequence without an expected parameter list, retaining source order
/// and accumulated diagnostics.
///
/// ```text
/// tuple children 1, True -> [Int, Bool]
/// ```
fn infer_many(
  values: List(ast.Expression),
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(#(List(Type), unify.State, List(Diagnostic)), Unsupported) {
  use #(types, state, diagnostics) <- result.try(
    list.try_fold(values, #([], state, []), fn(acc, value) {
      let #(types, state, diagnostics) = acc
      use found <- result.try(expression_type(
        value,
        environment,
        state,
        path,
        context,
      ))
      Ok(#(
        [found.type_, ..types],
        found.state,
        list.append(diagnostics, found.diagnostics),
      ))
    }),
  )
  Ok(#(list.reverse(types), state, diagnostics))
}

/// Create local bindings for parameters, interpreting written annotations under
/// the current generic environment.
///
/// ```text
/// parameter value: Int binds value monomorphically as Int inside the callable
/// ```
fn parameters_type(
  parameters: List(ast.Parameter),
  environment: Environment,
  state: unify.State,
  generics: Dict(String, Type),
  path: String,
) -> Result(#(List(Type), Environment, unify.State), Unsupported) {
  use #(types, locals, state) <- result.try(
    list.try_fold(parameters, #([], environment, state), fn(acc, parameter) {
      let #(types, locals, state) = acc
      use #(type_, state) <- result.try(case parameter.annotation {
        None -> Ok(unify.fresh(state))
        Some(annotation) ->
          annotation_type(annotation, generics, state, path)
          |> result.map(fn(type_) { #(type_, state) })
      })
      let locals = case parameter.name {
        ast.DiscardedParameter -> locals
        ast.NamedParameter(name) ->
          dict.insert(
            locals,
            name,
            Binding(scheme.monomorphic(type_), parameter.span),
          )
      }
      Ok(#([type_, ..types], locals, state))
    }),
  )
  Ok(#(list.reverse(types), locals, state))
}

/// Infer statements in a local environment, letting each binding constrain later
/// statements and using the final expression as the block result.
///
/// ```text
/// let n = 1; n + 2 -> Int (statement sequence shown schematically)
/// ```
fn block_type(
  block: ast.Block,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  use #(report, _) <- result.try(
    list.try_fold(
      block.statements,
      #(inferred(monotype.NilType, state), environment),
      fn(acc, statement) {
        let #(previous, environment) = acc
        case statement {
          ast.ExpressionStatement(value) -> {
            use found <- result.try(expression_type(
              value,
              environment,
              previous.state,
              path,
              context,
            ))
            Ok(#(
              Inferred(
                ..found,
                diagnostics: list.append(
                  previous.diagnostics,
                  found.diagnostics,
                ),
              ),
              environment,
            ))
          }
          ast.LetStatement(pattern:, annotation:, value:, ..) ->
            binding_statement(
              pattern,
              annotation,
              value,
              None,
              environment,
              previous,
              path,
              context,
            )
          ast.LetAssertStatement(pattern:, annotation:, value:, message:, ..) ->
            binding_statement(
              pattern,
              annotation,
              value,
              message,
              environment,
              previous,
              path,
              context,
            )
        }
      },
    ),
  )
  Ok(Inferred(..report, type_: unify.apply(report.type_, report.state)))
}

/// Resolve a written annotation to its monotype, respecting generic variables and
/// qualified nominal identities.
///
/// ```text
/// List(a) under a := Int -> List(Int)
/// ```
pub fn annotation_type(
  annotation: ast.TypeAnnotation,
  generics: Dict(String, Type),
  state: unify.State,
  path: String,
) -> Result(Type, Unsupported) {
  case annotation {
    ast.NamedType(None, name, arguments, span) -> {
      use arguments <- result.try(
        list.try_map(arguments, annotation_type(_, generics, state, path)),
      )
      case name, arguments {
        "Int", [] -> Ok(monotype.IntType)
        "Float", [] -> Ok(monotype.FloatType)
        "String", [] -> Ok(monotype.StringType)
        "UtfCodepoint", [] -> Ok(bit_array.codepoint_type())
        "Bool", [] -> Ok(monotype.BoolType)
        "Nil", [] -> Ok(monotype.NilType)
        "BitArray", [] -> Ok(monotype.BitArrayType)
        "Pid", [] -> Ok(monotype.PidType)
        "List", [value] -> Ok(monotype.ListType(value))
        "Option", [value] -> Ok(monotype.OptionType(value))
        "Result", [value, error] -> Ok(monotype.ResultType(value, error))
        _, _ -> named_annotation("", name, arguments, span, state, path)
      }
    }
    ast.TupleType(elements, _) ->
      list.try_map(elements, annotation_type(_, generics, state, path))
      |> result.map(monotype.TupleType)
    ast.FunctionType(parameters, result, _) -> {
      use parameters <- result.try(
        list.try_map(parameters, annotation_type(_, generics, state, path)),
      )
      use result <- result.try(annotation_type(result, generics, state, path))
      Ok(monotype.FunctionType(parameters, result))
    }
    ast.TypeVariable(name, span) ->
      dict.get(generics, name)
      |> result.map_error(fn(_) {
        Unsupported(span, "unbound generic annotation")
      })
    ast.NamedType(Some(qualifier), name, arguments, span) -> {
      use arguments <- result.try(
        list.try_map(arguments, annotation_type(_, generics, state, path)),
      )
      named_annotation(qualifier, name, arguments, span, state, path)
    }
  }
}

/// Infer a named function with the core environment and a fresh callable
/// boundary.
///
/// ```text
/// identity(value: a) -> a { value } preserves its universal promise
/// ```
pub fn infer_function(
  function: ast.Function,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  let #(core, state) = core_environment(state)
  callable(
    function.parameters,
    function.return_type,
    function.body,
    function.span,
    dict.merge(core, environment),
    state,
    path,
    Context(None, None, Ordinary, dict.new(), None, False),
  )
}

/// Infer primitive operator operands and result types. Division permits mixed
/// numeric operands and always returns Float, so its type never depends on
/// whether a particular quotient happens to be whole.
///
/// ```text
/// 5 / 2 -> Float 2.5; 4 / 2 -> Float 2.0; 1 + 2.0 remains invalid
/// ```
fn primitive_operator(
  operator: ast.BinaryOperator,
  left: ast.Expression,
  right: ast.Expression,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  use first <- result.try(expression_type(
    left,
    environment,
    state,
    path,
    context,
  ))
  use second <- result.try(expression_type(
    right,
    environment,
    first.state,
    path,
    context,
  ))
  let mixed_division = case
    operator,
    unify.apply(first.type_, second.state),
    unify.apply(second.type_, second.state)
  {
    ast.Divide, monotype.FloatType, monotype.IntType
    | ast.Divide, monotype.IntType, monotype.FloatType
    -> True
    _, _, _ -> False
  }
  let second = case mixed_division {
    True -> second
    False ->
      require(
        second,
        first.type_,
        ast.expression_span(left),
        ast.expression_span(right),
        path,
        "Operator operands must have the same type; numeric conversion must be explicit.",
      )
  }
  let report =
    Inferred(
      monotype.ErrorType,
      second.state,
      list.append(first.diagnostics, second.diagnostics),
    )
  case unify.apply(first.type_, second.state), second.type_ {
    monotype.ErrorType, _ | _, monotype.ErrorType -> Ok(report)
    operand, _ -> {
      let result_type = case operator {
        ast.Divide -> monotype.FloatType
        ast.Less | ast.LessOrEqual | ast.Greater | ast.GreaterOrEqual ->
          monotype.BoolType
        _ -> operand
      }
      let kind = case operator {
        ast.Add -> unify.Addable
        _ -> unify.Numeric
      }
      Ok(check_primitive(
        Inferred(..report, type_: result_type),
        operand,
        kind,
        span,
        path,
      ))
    }
  }
}

/// Record the primitive domain a resolved or unresolved operand must support.
///
/// ```text
/// Bool used for subtraction -> invalid Numeric operand
/// ```
fn check_primitive(
  report: Inferred,
  operand: Type,
  kind: unify.PrimitiveKind,
  span: Span,
  path: String,
) -> Inferred {
  case unify.apply(operand, report.state) {
    monotype.ErrorType -> report
    _ -> {
      let at = location.new(path, span)
      let state =
        unify.require_primitive(
          report.state,
          operand,
          kind,
          unify.Origin(
            at,
            at,
            "The operand must support this primitive operation.",
          ),
        )
      let #(state, errors) = unify.settle_primitives(state, set.new())
      Inferred(
        case diagnostic.has_errors(errors) {
          True -> monotype.ErrorType
          False -> report.type_
        },
        state,
        list.append(report.diagnostics, errors),
      )
    }
  }
}

/// Introduce the compiler's actual builtins, including echo and Result/Option
/// construction. IO remains a library concern.
///
/// ```text
/// echo has identity-like value flow and prints through the runtime helper
/// ```
pub fn core_environment(state: unify.State) -> #(Environment, unify.State) {
  let #(a, state) = unify.fresh(state)
  let #(b, state) = unify.fresh(state)
  let at = location.Span(location.start(), location.start())
  let values = [
    #("echo", monotype.FunctionType([a], a)),
    #("Some", monotype.FunctionType([a], monotype.OptionType(a))),
    #("None", monotype.OptionType(a)),
    #("Ok", monotype.FunctionType([a], monotype.ResultType(a, b))),
    #("Error", monotype.FunctionType([b], monotype.ResultType(a, b))),
  ]
  #(
    values
      |> list.map(fn(value) {
        #(value.0, Binding(scheme.generalize(value.1, [], state), at))
      })
      |> dict.from_list,
    state,
  )
}

type PatternReport {
  PatternReport(
    environment: Environment,
    state: unify.State,
    diagnostics: List(Diagnostic),
    matched: Option(Type),
  )
}

/// Refine a matched subject within the selected branch using its successful
/// constructor pattern.
///
/// ```text
/// subject: Ref; branch Tmp(id) -> subject has Tmp members in that branch
/// ```
fn narrow_subject(
  subject: ast.Expression,
  pattern: ast.Pattern,
  report: PatternReport,
) -> Environment {
  case subject, report.matched, diagnostic.has_errors(report.diagnostics) {
    ast.Variable(name, _), Some(matched), False -> {
      case
        list.any(ast.pattern_bindings(pattern), fn(binding) {
          binding.name == name
        })
      {
        True -> report.environment
        False ->
          case dict.get(report.environment, name) {
            Ok(Binding(_, span)) ->
              dict.insert(
                report.environment,
                name,
                Binding(
                  scheme.monomorphic(unify.apply(matched, report.state)),
                  span,
                ),
              )
            _ -> report.environment
          }
      }
    }
    _, _, _ -> report.environment
  }
}

/// Prevent hidden existential type arguments introduced by a class pattern from
/// escaping their safe branch scope.
///
/// ```text
/// a value with an unknown class argument cannot make that argument a public result type
/// ```
fn reject_pattern_escape(
  pattern: PatternReport,
  environment: Environment,
  subject: Type,
  before: unify.State,
  body: Inferred,
  context: Context,
  path: String,
  branch: ast.Branch,
) -> Inferred {
  let outer = generalization_environment(environment, context)
  let known =
    list.fold(
      outer,
      monotype.rigids(unify.apply(subject, before)),
      fn(found, value) {
        set.union(found, scheme.rigid_variables(value, before))
      },
    )
  let matched = case pattern.matched {
    Some(type_) -> monotype.rigids(unify.apply(type_, pattern.state))
    None -> set.new()
  }
  let introduced =
    list.fold(
      environment_schemes(pattern.environment),
      matched,
      fn(found, value) {
        set.union(found, scheme.rigid_variables(value, pattern.state))
      },
    )
    |> set.difference(known)

  let body = case
    set.size(set.intersection(
      introduced,
      monotype.rigids(unify.apply(body.type_, body.state)),
    ))
    > 0
  {
    False -> body
    True -> {
      let candidates = [
        subject,
        ..case context.returns {
          Some(type_) -> [type_]
          None -> []
        }
      ]
      list.find_map(candidates, fn(candidate) {
        let candidate = unify.apply(candidate, body.state)
        case candidate {
          monotype.Nominal(..) -> {
            case
              set.size(set.intersection(introduced, monotype.rigids(candidate)))
              == 0
            {
              False -> Error(Nil)
              True ->
                unify.subsume(
                  candidate,
                  body.type_,
                  unify.Origin(
                    location.new(path, branch.span),
                    location.new(path, ast.expression_span(branch.body)),
                    "A known interface or ancestor can hide a pattern's existential arguments.",
                  ),
                  body.state,
                )
                |> result.map(fn(state) {
                  Inferred(..body, type_: candidate, state:)
                })
                |> result.map_error(fn(_) { Nil })
            }
          }
          _ -> Error(Nil)
        }
      })
      |> result.unwrap(body)
    }
  }
  let break_rigids = case context.loop {
    None -> set.new()
    Some(loop) ->
      list.fold(
        unify.loop_breaks(body.state, loop),
        set.new(),
        fn(found, value) {
          set.union(found, monotype.rigids(unify.apply(value.0, body.state)))
        },
      )
  }
  let escaped =
    list.fold(
      outer,
      set.union(
        break_rigids,
        monotype.rigids(unify.apply(body.type_, body.state)),
      ),
      fn(found, value) {
        set.union(found, scheme.rigid_variables(value, body.state))
      },
    )
    |> set.intersection(introduced)
  case set.size(escaped) > 0 {
    False -> body
    True ->
      Inferred(
        ..body,
        type_: monotype.ErrorType,
        diagnostics: list.append(body.diagnostics, [
          diagnostic.error(
            "type.pattern_type_escape",
            "hidden pattern type escapes its branch",
          )
          |> diagnostic.primary(
            location.new(path, ast.expression_span(branch.body)),
            "this value exposes a type argument hidden by the matched subject",
          )
          |> diagnostic.secondary(
            location.new(path, ast.pattern_span(branch.pattern)),
            "the concrete pattern introduces the hidden type",
          )
          |> diagnostic.help(
            "Return a value whose type is known outside this branch, such as the declared interface.",
          ),
        ]),
      )
  }
}

/// Check the pattern's shape against its subject and bind extracted values
/// locally. Every declared class field must appear in declaration order.
///
/// ```text
/// Box(value) against Box(Int) -> local value: Int
/// ```
fn bind_pattern(
  pattern: ast.Pattern,
  subject: Type,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(PatternReport, Unsupported) {
  case pattern {
    ast.VariablePattern(name, span) ->
      Ok(PatternReport(
        dict.insert(
          environment,
          name,
          Binding(scheme.monomorphic(subject), span),
        ),
        state,
        [],
        None,
      ))
    ast.DiscardPattern(_) -> Ok(PatternReport(environment, state, [], None))
    ast.IntPattern(..) ->
      literal_pattern(
        pattern,
        subject,
        monotype.IntType,
        environment,
        state,
        path,
      )
    ast.FloatPattern(..) ->
      literal_pattern(
        pattern,
        subject,
        monotype.FloatType,
        environment,
        state,
        path,
      )
    ast.StringPattern(..) ->
      literal_pattern(
        pattern,
        subject,
        monotype.StringType,
        environment,
        state,
        path,
      )
    ast.BoolPattern(..) ->
      literal_pattern(
        pattern,
        subject,
        monotype.BoolType,
        environment,
        state,
        path,
      )
    ast.NilPattern(..) ->
      literal_pattern(
        pattern,
        subject,
        monotype.NilType,
        environment,
        state,
        path,
      )
    ast.TuplePattern(elements, span) -> {
      let #(types, state) =
        list.fold(elements, #([], state), fn(acc, _) {
          let #(types, state) = acc
          let #(type_, state) = unify.fresh(state)
          #([type_, ..types], state)
        })
      let types = list.reverse(types)
      let checked =
        require(
          inferred(subject, state),
          monotype.TupleType(types),
          span,
          span,
          path,
          "The pattern must match the subject's tuple type.",
        )
      let types = case checked.type_ {
        monotype.ErrorType -> list.map(types, fn(_) { monotype.ErrorType })
        _ -> types
      }
      bind_elements(elements, types, environment, checked.state, path)
      |> result.map(fn(bound) {
        PatternReport(
          ..bound,
          diagnostics: list.append(checked.diagnostics, bound.diagnostics),
        )
      })
    }
    ast.ListPattern(elements, tail, span) -> {
      let #(element, state) = unify.fresh(state)
      let checked =
        require(
          inferred(subject, state),
          monotype.ListType(element),
          span,
          span,
          path,
          "A list pattern must match a List value.",
        )
      let element = case checked.type_ {
        monotype.ErrorType -> monotype.ErrorType
        _ -> element
      }
      use bound <- result.try(bind_elements(
        elements,
        list.map(elements, fn(_) { element }),
        environment,
        checked.state,
        path,
      ))
      let locals = case tail {
        Some(ast.BoundTail(name, span)) ->
          dict.insert(
            bound.environment,
            name,
            Binding(scheme.monomorphic(monotype.ListType(element)), span),
          )
        Some(ast.IgnoredTail(_)) | None -> bound.environment
      }
      Ok(PatternReport(
        locals,
        bound.state,
        list.append(checked.diagnostics, bound.diagnostics),
        None,
      ))
    }
    ast.EnumPattern(module, enum_name, variant, span) ->
      Ok(enum_pattern(
        option.unwrap(module, ""),
        enum_name,
        variant,
        span,
        subject,
        environment,
        state,
        path,
      ))
    ast.ConstructorPattern(None, name, arguments, span)
      if name == "Some" || name == "None" || name == "Ok" || name == "Error"
    -> {
      let constructor = lookup(name, span, environment, state, path)
      let #(parameters, result_type) = case constructor.type_ {
        monotype.FunctionType(parameters, result_type) -> #(
          parameters,
          result_type,
        )
        value -> #([], value)
      }
      let checked =
        require(
          inferred(subject, constructor.state),
          result_type,
          span,
          span,
          path,
          "The constructor pattern must match the subject's type.",
        )
      let arity = case list.length(parameters) == list.length(arguments) {
        True -> []
        False -> [
          diagnostic.error(
            "type.pattern_arity",
            "wrong number of constructor pattern fields",
          )
          |> diagnostic.primary(
            location.new(path, span),
            "the pattern has the wrong number of fields",
          )
          |> diagnostic.conclusion(
            "This constructor pattern requires "
            <> int.to_string(list.length(parameters))
            <> " field patterns.",
          ),
        ]
      }
      let parameters = case arity, checked.type_ {
        [], monotype.ErrorType ->
          list.map(arguments, fn(_) { monotype.ErrorType })
        [], _ -> parameters
        _, _ -> list.map(arguments, fn(_) { monotype.ErrorType })
      }
      bind_elements(arguments, parameters, environment, checked.state, path)
      |> result.map(fn(bound) {
        PatternReport(
          ..bound,
          diagnostics: list.flatten([
            constructor.diagnostics,
            checked.diagnostics,
            arity,
            bound.diagnostics,
          ]),
        )
      })
    }
    ast.ConstructorPattern(qualifier, name, arguments, span) -> {
      use class <- result.try(
        unify.named_class(
          state,
          path,
          case qualifier {
            Some(value) -> value
            None -> ""
          },
          name,
        )
        |> result.map_error(fn(_) { Unsupported(span, "unknown class pattern") }),
      )
      use <- bool.lazy_guard(class.actor, fn() {
        bind_elements(
          arguments,
          list.repeat(monotype.ErrorType, list.length(arguments)),
          environment,
          state,
          path,
        )
        |> result.map(fn(bound) {
          PatternReport(..bound, diagnostics: [
            diagnostic.error(
              "type.actor_pattern",
              "actor references cannot be destructured",
            )
              |> diagnostic.primary(
                location.new(path, span),
                "An actor reference exposes its protocol, never its state.",
              ),
            ..bound.diagnostics
          ])
        })
      })
      let #(type_arguments, state) =
        fresh_types(list.length(class.parameters), state)
      let expected =
        monotype.Nominal(
          class.module,
          class.source.name.name,
          monotype.ClassKind,
          type_arguments,
        )

      let state = case
        unify.apply(subject, state),
        unify.in_hierarchy(state, class)
      {
        monotype.Variable(_), True -> {
          let root = case
            list.last(unify.ancestors(state, nominal.identity(class)))
          {
            Ok(root) -> root
            Error(Nil) -> nominal.identity(class)
          }
          case unify.upcast(state, expected, root) {
            Ok(root_type) ->
              case
                unify.unify(
                  subject,
                  root_type,
                  unify.Origin(
                    location.new(path, span),
                    location.new(path, span),
                    "A class pattern determines the matched type.",
                  ),
                  state,
                )
              {
                Ok(state) -> state
                Error(_) -> state
              }
            Error(Nil) -> state
          }
        }
        _, _ -> state
      }
      let checked =
        require(
          inferred(expected, state),
          subject,
          span,
          span,
          path,
          "A class pattern must match its subject type or a subclass of it.",
        )

      let visible = monotype.variables(unify.apply(subject, checked.state))
      let hidden =
        set.difference(
          monotype.variables(unify.apply(expected, checked.state)),
          visible,
        )
      let sealed_state =
        list.fold(set.to_list(hidden), checked.state, fn(state, id) {
          let #(_, rigid, state) = unify.fresh_rigid("hidden", state)
          unify.unify(
            monotype.Variable(id),
            rigid,
            unify.Origin(
              location.new(path, span),
              location.new(path, span),
              "A class pattern cannot choose a type argument hidden by its subject.",
            ),
            state,
          )
          |> result.unwrap(state)
        })
      let checked = Inferred(..checked, state: sealed_state)

      let exposed =
        list.zip(class.fields, arguments)
        |> list.filter(fn(pair) {
          let #(field, argument) = pair
          string.starts_with(field.name.name, "_")
          && unify.owner(state) != Some(field.owner)
          && case argument {
            ast.DiscardPattern(_) -> False
            _ -> True
          }
        })
      let issues = case
        exposed,
        list.length(arguments) == list.length(class.fields)
      {
        [#(field, argument), ..], _ -> [
          diagnostic.error(
            "type.private_pattern_field",
            "class pattern exposes a private field",
          )
          |> diagnostic.primary(
            location.new(path, ast.pattern_span(argument)),
            "`"
              <> field.name.name
              <> "` is private to `"
              <> field.owner.1
              <> "`",
          )
          |> diagnostic.conclusion(
            "Use the bare `_` wildcard for a private field outside its class.",
          ),
        ]
        [], False -> [
          diagnostic.error(
            "type.pattern_arity",
            "wrong number of class pattern fields",
          )
          |> diagnostic.primary(
            location.new(path, span),
            "the pattern must contain every class field in declaration order",
          ),
        ]
        [], True -> []
      }
      let fields = case issues, checked.type_ {
        [], monotype.ErrorType ->
          list.repeat(monotype.ErrorType, list.length(arguments))
        [], _ ->
          list.map(class.fields, fn(field) {
            nominal.instantiate(
              unify.apply(field.type_, checked.state),
              class,
              type_arguments,
            )
          })
        _, _ -> list.repeat(monotype.ErrorType, list.length(arguments))
      }
      bind_elements(arguments, fields, environment, checked.state, path)
      |> result.map(fn(bound) {
        PatternReport(
          ..bound,
          matched: Some(expected),
          diagnostics: list.flatten([
            checked.diagnostics,
            issues,
            bound.diagnostics,
          ]),
        )
      })
    }
    ast.BitArrayPattern(segments, span) -> {
      let subject =
        require(
          inferred(subject, state),
          monotype.BitArrayType,
          span,
          span,
          path,
          "A bit-array pattern must match BitArray.",
        )
      list.try_fold(
        segments,
        PatternReport(
          environment,
          subject.state,
          list.append(
            subject.diagnostics,
            bit_array_layout.pattern_layout(segments, path),
          ),
          None,
        ),
        fn(report, segment) {
          use options <- result.try(
            bit_array.analyze(segment.options, path)
            |> result.map_error(fn(error) {
              Unsupported(error.span, error.feature)
            }),
          )
          use Nil <- result.try(case options.kind, segment.value {
            bit_array.Text(_), ast.StringPattern(..) -> Ok(Nil)
            bit_array.Text(_), _ ->
              Error(Unsupported(
                segment.span,
                "non-literal UTF text pattern segments",
              ))
            _, _ -> Ok(Nil)
          })

          use sizes <- result.try(segment_sizes(
            options.sizes,
            report.environment,
            report.state,
            path,
            Context(None, None, Ordinary, dict.new(), None, False),
          ))
          let value_type = case subject.type_ {
            monotype.ErrorType -> monotype.ErrorType
            _ -> options.value_type
          }
          use bound <- result.try(bind_pattern(
            segment.value,
            value_type,
            report.environment,
            sizes.state,
            path,
          ))
          Ok(
            PatternReport(
              ..bound,
              diagnostics: list.flatten([
                report.diagnostics,
                options.diagnostics,
                sizes.diagnostics,
                bound.diagnostics,
              ]),
            ),
          )
        },
      )
    }
  }
}

/// Check one literal against the matched primitive type without treating it as a
/// new binding.
///
/// ```text
/// True pattern expects Bool; an integer pattern expects Int
/// ```
fn literal_pattern(
  pattern: ast.Pattern,
  subject: Type,
  expected: Type,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(PatternReport, Unsupported) {
  let span = ast.pattern_span(pattern)
  let checked =
    require(
      inferred(subject, state),
      expected,
      span,
      span,
      path,
      "A literal pattern must have the subject's type.",
    )
  Ok(PatternReport(environment, checked.state, checked.diagnostics, None))
}

/// Check corresponding product elements while threading pattern bindings and
/// constraints.
///
/// ```text
/// #(name, count) against #(String, Int) -> two local bindings
/// ```
fn bind_elements(
  patterns: List(ast.Pattern),
  types: List(Type),
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(PatternReport, Unsupported) {
  list.zip(patterns, types)
  |> list.try_fold(
    PatternReport(environment, state, [], None),
    fn(report, pair) {
      use bound <- result.try(bind_pattern(
        pair.0,
        pair.1,
        report.environment,
        report.state,
        path,
      ))
      Ok(
        PatternReport(
          ..bound,
          matched: None,
          diagnostics: list.append(report.diagnostics, bound.diagnostics),
        ),
      )
    },
  )
}

/// Include captured values and active control-flow types when deciding which
/// variables may be generalized.
///
/// ```text
/// a loop result or callable return variable can prevent premature generalization
/// ```
fn generalization_environment(
  environment: Environment,
  context: Context,
) -> List(Scheme) {
  let values = environment_schemes(environment)
  let returns = case context.returns {
    Some(value) -> [scheme.monomorphic(value)]
    None -> []
  }
  let loops = case context.loop {
    Some(value) -> [scheme.monomorphic(value)]
    None -> []
  }
  list.flatten([values, returns, loops])
}

/// Infer a binding, check any annotation and pattern, then generalize only
/// variables not captured by the surrounding context.
///
/// ```text
/// let identity = fn(x) { x } can generalize; captured monomorphic state cannot
/// ```
fn binding_statement(
  pattern: ast.Pattern,
  annotation: Option(ast.TypeAnnotation),
  value: ast.Expression,
  message: Option(ast.Expression),
  environment: Environment,
  previous: Inferred,
  path: String,
  context: Context,
) -> Result(#(Inferred, Environment), Unsupported) {
  let generics = context.generics
  use found <- result.try(expression_type(
    value,
    environment,
    previous.state,
    path,
    context,
  ))
  use found <- result.try(case annotation {
    None -> Ok(found)
    Some(annotation) ->
      annotation_type(annotation, generics, found.state, path)
      |> result.map(fn(type_) {
        require(
          found,
          type_,
          ast.type_span(annotation),
          ast.expression_span(value),
          path,
          "The binding must match its type annotation.",
        )
      })
  })

  use message <- result.try(check_message(
    message,
    environment,
    found.state,
    path,
    context,
    ast.pattern_span(pattern),
  ))
  use bound <- result.try(bind_pattern(
    pattern,
    found.type_,
    environment,
    message.state,
    path,
  ))
  let environment_variables =
    generalization_environment(environment, context)
    |> list.fold(set.new(), fn(found, value) {
      set.union(found, scheme.free_variables(value, bound.state))
    })
  let generalized_variables =
    set.difference(
      monotype.variables(unify.apply(found.type_, bound.state)),
      environment_variables,
    )
  let #(state, primitive_errors) =
    unify.settle_primitives(bound.state, generalized_variables)
  let bound =
    PatternReport(
      ..bound,
      state:,
      diagnostics: list.append(bound.diagnostics, primitive_errors),
    )
  let locals =
    list.fold(
      ast.pattern_bindings(pattern),
      bound.environment,
      fn(locals, name) {
        case dict.get(locals, name.name) {
          Error(Nil) -> locals
          Ok(ModuleBinding(..))
          | Ok(NamespaceBinding(..))
          | Ok(ClassBinding(_))
          | Ok(EnumBinding(_))
          | Ok(InterfaceBinding(_)) -> locals
          Ok(Binding(value, _)) -> {
            let #(type_, _) = scheme.instantiate(value, bound.state)
            let generalized = case diagnostic.has_errors(primitive_errors) {
              True -> scheme.monomorphic(monotype.ErrorType)
              False ->
                scheme.generalize(
                  type_,
                  generalization_environment(environment, context),
                  bound.state,
                )
            }
            dict.insert(locals, name.name, Binding(generalized, name.span))
          }
        }
      },
    )
  Ok(#(
    Inferred(
      monotype.NilType,
      bound.state,
      list.flatten([
        previous.diagnostics,
        found.diagnostics,
        message.diagnostics,
        bound.diagnostics,
      ]),
    ),
    locals,
  ))
}

fn check_message(
  message: Option(ast.Expression),
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
  span: Span,
) -> Result(Inferred, Unsupported) {
  case message {
    None -> Ok(inferred(monotype.NilType, state))
    Some(message) ->
      expression_type(message, environment, state, path, context)
      |> result.map(require(
        _,
        monotype.StringType,
        span,
        ast.expression_span(message),
        path,
        "A diagnostic message must evaluate to String.",
      ))
  }
}

fn invalid_context(
  report: Inferred,
  span: Span,
  path: String,
  reason: String,
) -> Inferred {
  Inferred(
    monotype.ErrorType,
    report.state,
    list.append(report.diagnostics, [
      diagnostic.error("type.invalid_context", "invalid expression context")
      |> diagnostic.primary(
        location.new(path, span),
        "this expression cannot exit the current scope",
      )
      |> diagnostic.conclusion(reason),
    ]),
  )
}

/// Check a callable under its own return boundary without supplying extra
/// contextual parameter types.
///
/// ```text
/// named function -> fresh local parameter and return context
/// ```
fn callable(
  parameters: List(ast.Parameter),
  annotation: Option(ast.TypeAnnotation),
  body: ast.Block,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
  outer: Context,
) -> Result(Inferred, Unsupported) {
  callable_expected(
    parameters,
    annotation,
    body,
    span,
    environment,
    state,
    path,
    outer,
    None,
  )
}

/// Seed unannotated callback parameters from an expected function type before
/// checking the body. Explicit universal annotations remain rigid and captures
/// are checked for escapes.
///
/// ```text
/// expected fn(User) -> b gives unannotated callback user the User type
/// ```
fn callable_expected(
  parameters: List(ast.Parameter),
  annotation: Option(ast.TypeAnnotation),
  body: ast.Block,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
  outer: Context,
  expected: Option(Type),
) -> Result(Inferred, Unsupported) {
  let original = state
  let variables =
    list.flat_map(parameters, fn(parameter) {
      case parameter.annotation {
        Some(value) -> annotation_variables(value)
        None -> []
      }
    })
  let variables =
    list.append(variables, case annotation {
      Some(value) -> annotation_variables(value)
      None -> []
    })
    |> list.unique
  let #(generics, introduced, state) =
    list.fold(variables, #(outer.generics, [], state), fn(acc, name) {
      let #(generics, introduced, state) = acc
      case dict.has_key(generics, name) {
        True -> acc
        False -> {
          let #(id, rigid, state) = unify.fresh_rigid(name, state)
          #(dict.insert(generics, name, rigid), [id, ..introduced], state)
        }
      }
    })
  use #(parameter_types, locals, state) <- result.try(parameters_type(
    parameters,
    environment,
    state,
    generics,
    path,
  ))
  let state = case expected {
    Some(expected) ->
      case unify.apply(expected, state) {
        monotype.FunctionType(expected_parameters, _) ->
          list.zip(parameters, list.zip(parameter_types, expected_parameters))
          |> list.fold(state, fn(state, pair) {
            case pair.0.annotation {
              Some(_) -> state
              None ->
                case
                  unify.unify(
                    pair.1.0,
                    pair.1.1,
                    unify.Origin(
                      location.new(path, span),
                      location.new(path, span),
                      "A callback receives its parameter type from the call.",
                    ),
                    state,
                  )
                {
                  Ok(state) -> state
                  Error(_) -> state
                }
            }
          })
        _ -> state
      }
    None -> state
  }
  use #(return_type, state) <- result.try(case annotation {
    None -> Ok(unify.fresh(state))
    Some(value) ->
      annotation_type(value, generics, state, path)
      |> result.map(fn(value) { #(value, state) })
  })
  use report <- result.try(block_type(
    body,
    locals,
    state,
    path,
    Context(
      Some(return_type),
      None,
      Ordinary,
      generics,
      None,
      outer.actor_writes,
    ),
  ))
  let expected_span = case annotation {
    Some(value) -> ast.type_span(value)
    None -> body.span
  }
  let found_span = case list.last(body.statements) {
    Ok(value) -> ast.statement_span(value)
    Error(Nil) -> body.span
  }
  let checked =
    require(
      report,
      return_type,
      expected_span,
      found_span,
      path,
      "The final expression must match the callable's result type.",
    )
  let #(state, primitive_errors) =
    unify.settle_primitives(checked.state, set.new())
  let checked =
    Inferred(
      state:,
      type_: case diagnostic.has_errors(primitive_errors) {
        True -> monotype.ErrorType
        False -> checked.type_
      },
      diagnostics: list.append(checked.diagnostics, primitive_errors),
    )
  let captured =
    generalization_environment(environment, outer)
    |> list.fold(set.new(), fn(found, value) {
      set.union(found, scheme.rigid_variables(value, checked.state))
    })
  let escaped = set.intersection(captured, set.from_list(introduced))
  case set.size(escaped) > 0 {
    True ->
      Ok(Inferred(
        monotype.ErrorType,
        original,
        list.append(checked.diagnostics, [
          diagnostic.error(
            "type.generic_escape",
            "generic annotation escapes its callable",
          )
          |> diagnostic.primary(
            location.new(path, span),
            "a universal type variable constrains a captured binding",
          )
          |> diagnostic.conclusion(
            "A captured monomorphic value cannot depend on a type variable that is universal only inside this callable.",
          ),
        ]),
      ))
    False -> {
      let result_type = case checked.type_ {
        monotype.ErrorType -> monotype.ErrorType
        _ -> unify.apply(return_type, checked.state)
      }
      let raw =
        unify.apply(
          monotype.FunctionType(parameter_types, result_type),
          checked.state,
        )
      let #(replacements, state) =
        list.fold(
          list.reverse(introduced),
          #(dict.new(), checked.state),
          fn(acc, id) {
            let #(replacements, state) = acc
            let #(variable, state) = unify.fresh(state)
            #(dict.insert(replacements, id, variable), state)
          },
        )
      Ok(Inferred(
        monotype.replace_rigids(raw, replacements),
        state,
        checked.diagnostics,
      ))
    }
  }
}

/// Publish an independently quantified contract only when all parameters and the
/// result are annotated. Recursive callers can instantiate that promise before
/// the body is checked.
///
/// ```text
/// make(value: a) -> Box(a) is available polymorphically inside a recursive nominal group
/// ```
pub fn declared_scheme(
  function: ast.Function,
  state: unify.State,
  path: String,
) -> Option(#(Scheme, unify.State)) {
  case
    list.all(function.parameters, fn(parameter) {
      option.is_some(parameter.annotation)
    })
  {
    True -> recovery_scheme(function, state, path)
    False -> None
  }
}

/// Recover only the contract written by the author. A failed implementation is
/// still an error, but its declared result can keep later callers well typed.
/// Missing parameter annotations become error types rather than guesses.
///
/// ```pooka
/// make() -> List(Box) { [Box("wrong")] }
/// // The body fails. A caller still knows that each returned element is Box.
/// ```
pub fn recovery_scheme(
  function: ast.Function,
  state: unify.State,
  path: String,
) -> Option(#(Scheme, unify.State)) {
  let annotations =
    list.map(function.parameters, fn(parameter) { parameter.annotation })
  case function.return_type {
    None -> None
    Some(result) -> {
      let written = option.values([Some(result), ..annotations])
      let #(generics, variables, state) =
        written
        |> list.flat_map(annotation_variables)
        |> list.unique
        |> list.fold(#(dict.new(), [], state), fn(acc, name) {
          let #(generics, variables, state) = acc
          let #(variable, state) = unify.fresh(state)
          let id = case variable {
            monotype.Variable(id) -> [id]
            _ -> []
          }
          #(
            dict.insert(generics, name, variable),
            list.append(variables, id),
            state,
          )
        })
      let declared =
        annotations
        |> list.try_map(fn(annotation) {
          case annotation {
            Some(value) -> annotation_type(value, generics, state, path)
            None -> Ok(monotype.ErrorType)
          }
        })
        |> result.try(fn(parameters) {
          annotation_type(result, generics, state, path)
          |> result.map(monotype.FunctionType(parameters, _))
        })
      case declared {
        Ok(type_) -> Some(#(scheme.quantified(type_, variables), state))
        Error(_) -> None
      }
    }
  }
}

fn annotation_variables(annotation: ast.TypeAnnotation) -> List(String) {
  case annotation {
    ast.TypeVariable(name, _) -> [name]
    ast.NamedType(arguments:, ..) | ast.TupleType(elements: arguments, ..) ->
      list.flat_map(arguments, annotation_variables)
    ast.FunctionType(parameters, result, _) ->
      list.flat_map([result, ..parameters], annotation_variables)
  }
}

/// Check the inferred named-function signature against its declared universal
/// contract.
///
/// ```text
/// declared fn(a) -> a must work for every a, not only Int
/// ```
pub fn validate_signature(
  function: ast.Function,
  actual: Type,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  validate_signature_in(function, actual, state, path, dict.new())
}

/// Validate a method's contract with the owning class's generic parameters in
/// scope.
///
/// ```text
/// Box(a).map(fn(a) -> b) -> Box(b) keeps class a and method b distinct
/// ```
pub fn validate_method_signature(
  class: nominal.Class,
  function: ast.Function,
  actual: Type,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  validate_signature_in(function, actual, state, path, class_generics(class))
}

/// Validate a callable signature using the supplied generic context rather than
/// specializing universal variables.
///
/// ```text
/// a concrete implementation cannot quietly narrow a universal parameter
/// ```
fn validate_signature_in(
  function: ast.Function,
  actual: Type,
  state: unify.State,
  path: String,
  outer_generics: Dict(String, Type),
) -> Result(Inferred, Unsupported) {
  let variables =
    list.flat_map(function.parameters, fn(parameter) {
      case parameter.annotation {
        Some(value) -> annotation_variables(value)
        None -> []
      }
    })
  let variables =
    list.append(variables, case function.return_type {
      Some(value) -> annotation_variables(value)
      None -> []
    })
    |> list.unique
  let #(generics, state) =
    list.fold(variables, #(outer_generics, state), fn(acc, name) {
      let #(generics, state) = acc
      case dict.has_key(generics, name) {
        True -> #(generics, state)
        False -> {
          let #(_, variable, state) = unify.fresh_rigid(name, state)
          #(dict.insert(generics, name, variable), state)
        }
      }
    })
  use #(parameters, _, state) <- result.try(parameters_type(
    function.parameters,
    dict.new(),
    state,
    generics,
    path,
  ))
  use #(return_type, state) <- result.try(case function.return_type {
    Some(value) ->
      annotation_type(value, generics, state, path)
      |> result.map(fn(value) { #(value, state) })
    None -> Ok(unify.fresh(state))
  })
  let checked =
    require(
      inferred(unify.apply(actual, state), state),
      monotype.FunctionType(parameters, return_type),
      function.name.span,
      function.span,
      path,
      "Recursive inference must preserve the function's written universal signature.",
    )
  Ok(Inferred(actual, state, checked.diagnostics))
}

/// Read a foreign function's declared signature without inventing a Pooka
/// implementation body.
///
/// ```text
/// external abs(value: Int) -> Int -> checked callable contract
/// ```
pub fn infer_external_function(
  function: ast.ExternalFunction,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  let annotation = function.return_type
  use annotations <- result.try(
    list.try_map(function.parameters, fn(parameter) {
      case parameter.annotation {
        Some(value) -> Ok(value)
        None ->
          Error(Unsupported(
            parameter.span,
            "external parameter annotation required",
          ))
      }
    }),
  )
  let variables =
    list.flat_map([annotation, ..annotations], annotation_variables)
    |> list.unique
  let #(generics, state) =
    list.fold(variables, #(dict.new(), state), fn(acc, name) {
      let #(generics, state) = acc
      let #(variable, state) = unify.fresh(state)
      #(dict.insert(generics, name, variable), state)
    })
  use parameters <- result.try(
    list.try_map(annotations, annotation_type(_, generics, state, path)),
  )
  use returned <- result.try(annotation_type(annotation, generics, state, path))
  Ok(inferred(monotype.FunctionType(parameters, returned), state))
}

/// Check a test body with its own callable context. A skipped test is still
/// source that must type-check.
///
/// ```text
/// test body -> inferred report, even when the runner will skip execution
/// ```
pub fn infer_test(
  source_test: ast.Test,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  let #(core, state) = core_environment(state)
  block_type(
    source_test.body,
    dict.merge(core, environment),
    state,
    path,
    Context(None, None, Ordinary, dict.new(), None, False),
  )
}

/// Extract ordinary value schemes from the environment for free-variable and
/// escape analysis.
///
/// ```text
/// captured value schemes -> variables unavailable for generalization
/// ```
pub fn environment_schemes(environment: Environment) -> List(Scheme) {
  dict.values(environment)
  |> list.flat_map(fn(value) {
    case value {
      Binding(value, _) -> [value]
      ModuleBinding(_, values, namespaces) ->
        list.append(
          dict.values(values),
          list.flat_map(dict.values(namespaces), dict.values),
        )
      NamespaceBinding(_, functions) -> dict.values(functions)
      ClassBinding(_) | InterfaceBinding(_) | EnumBinding(_) -> []
    }
  })
}

fn module_member(
  identity: String,
  declarations: Dict(String, Scheme),
  name: ast.Name,
  state: unify.State,
  path: String,
) -> Inferred {
  case dict.get(declarations, name.name) {
    Ok(value) -> {
      let #(type_, state) = scheme.instantiate(value, state)
      inferred(type_, state)
    }
    Error(Nil) ->
      Inferred(monotype.ErrorType, state, [
        diagnostic.error(
          "type.unknown_module_member",
          "unknown module declaration",
        )
        |> diagnostic.primary(
          location.new(path, name.span),
          "`"
            <> identity
            <> "` has no inferred public declaration named `"
            <> name.name
            <> "`",
        )
        |> diagnostic.conclusion(
          "Use a public declaration from the imported module.",
        ),
      ])
  }
}

fn segment_sizes(
  values: List(ast.BitArrayOption),
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  list.try_fold(values, inferred(monotype.NilType, state), fn(report, option) {
    let value = case option {
      ast.SizeOption(value, _) | ast.UnitOption(value, _) -> value
      ast.NamedOption(_, _) ->
        panic as "only size and unit options are collected"
    }
    use found <- result.try(expression_type(
      value,
      environment,
      report.state,
      path,
      context,
    ))
    let checked =
      require(
        found,
        monotype.IntType,
        ast.expression_span(value),
        ast.expression_span(value),
        path,
        "Bit-array size and unit expressions must have type Int.",
      )
    Ok(Inferred(
      monotype.NilType,
      checked.state,
      list.flatten([
        report.diagnostics,
        checked.diagnostics,
        case option, diagnostic.has_errors(checked.diagnostics) {
          ast.UnitOption(_, span), False ->
            bit_array.constant_unit(value, span, path)
          _, _ -> []
        },
      ]),
    ))
  })
}

fn external_member(
  namespace: String,
  functions: Dict(String, Scheme),
  name: ast.Name,
  state: unify.State,
  path: String,
) -> Inferred {
  case dict.get(functions, name.name) {
    Ok(value) -> {
      let #(type_, state) = scheme.instantiate(value, state)
      inferred(type_, state)
    }
    Error(Nil) ->
      Inferred(monotype.ErrorType, state, [
        diagnostic.error(
          "type.unknown_external_function",
          "unknown namespace function",
        )
        |> diagnostic.primary(
          location.new(path, name.span),
          "`" <> namespace <> "` declares no function `" <> name.name <> "`",
        )
        |> diagnostic.conclusion("Call a function declared by the namespace."),
      ])
  }
}

fn namespace_as_value(name: String, span: Span, path: String) -> Diagnostic {
  diagnostic.error("type.external_namespace_value", "namespace used as a value")
  |> diagnostic.primary(
    location.new(path, span),
    "`" <> name <> "` is a namespace, not a value",
  )
  |> diagnostic.conclusion(
    "Only the functions of an external or native namespace can be used, as `"
    <> name
    <> ".function(...)`.",
  )
}

fn field_access(
  subject: ast.Expression,
  name: ast.Name,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  let module = case subject {
    ast.Variable(alias, _) -> dict.get(environment, alias)
    ast.TypeName(namespace, _) -> dict.get(environment, namespace)

    ast.FieldAccess(ast.Variable(alias, _), namespace, _) ->
      case dict.get(environment, alias) {
        Ok(ModuleBinding(_, _, namespaces)) ->
          dict.get(namespaces, namespace.name)
          |> result.map(NamespaceBinding(namespace.name, _))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case module {
    Ok(NamespaceBinding(namespace, functions)) ->
      Ok(external_member(namespace, functions, name, state, path))

    Ok(ModuleBinding(identity, declarations, namespaces)) ->
      case dict.has_key(namespaces, name.name) {
        True ->
          Ok(
            Inferred(monotype.ErrorType, state, [
              namespace_as_value(name.name, span, path),
            ]),
          )
        False -> Ok(module_member(identity, declarations, name, state, path))
      }
    _ -> {
      use subject <- result.try(expression_type(
        subject,
        environment,
        state,
        path,
        context,
      ))
      case subject.type_ {
        monotype.ErrorType -> Ok(subject)
        _ -> Ok(object_member(subject, name, path))
      }
    }
  }
}

fn named_annotation(
  qualifier: String,
  name: String,
  arguments: List(Type),
  span: Span,
  state: unify.State,
  path: String,
) -> Result(Type, Unsupported) {
  let descriptor = case unify.named_class(state, path, qualifier, name) {
    Ok(class) ->
      Ok(#(
        class.module,
        class.source.name.name,
        nominal.kind(class),
        list.length(class.parameters),
      ))
    Error(Nil) ->
      unify.named_interface(state, path, qualifier, name)
      |> result.map(fn(interface) {
        #(
          interface.module,
          interface.source.name.name,
          monotype.InterfaceKind,
          list.length(interface.parameters),
        )
      })
      |> result.lazy_or(fn() {
        unify.named_enum(state, path, qualifier, name)
        |> result.map(fn(enum) {
          #(enum.module, enum.source.name.name, monotype.EnumKind, 0)
        })
      })
  }
  use descriptor <- result.try(
    descriptor
    |> result.map_error(fn(_) { Unsupported(span, "unknown nominal type") }),
  )
  case list.length(arguments) == descriptor.3 {
    True ->
      Ok(monotype.Nominal(descriptor.0, descriptor.1, descriptor.2, arguments))
    False -> Error(Unsupported(span, "nominal type argument arity"))
  }
}

/// Resolve a prepared class constructor and instantiate its generic arguments for
/// this use.
///
/// ```text
/// Box(1) and Box("oak") may instantiate different class arguments
/// ```
fn class_constructor(
  identity: nominal.Identity,
  span: Span,
  state: unify.State,
  path: String,
) -> Inferred {
  case unify.class(state, identity) {
    Error(Nil) -> inferred(monotype.ErrorType, state)
    Ok(class) -> {
      use <- bool.lazy_guard(!unify.constructible(state, class), fn() {
        Inferred(monotype.ErrorType, state, [abstract_class(class, span, path)])
      })
      let #(arguments, state) =
        fresh_types(list.length(class.parameters), state)
      let type_ =
        nominal.instantiate(
          unify.apply(class.constructor, state),
          class,
          arguments,
        )
      let #(replacements, state) =
        list.fold(
          class.constructor_quantified,
          #(dict.new(), state),
          fn(acc, id) {
            let #(fresh, state) = unify.fresh(acc.1)
            #(dict.insert(acc.0, id, fresh), state)
          },
        )
      let report = inferred(monotype.replace(type_, replacements), state)
      case class.ready {
        True -> report
        False ->
          Inferred(..report, type_: monotype.ErrorType, diagnostics: [
            diagnostic.error(
              "type.recursive_constructor",
              "constructor signature is not available yet",
            )
            |> diagnostic.primary(
              location.new(path, span),
              "a constructor cannot use itself before its fields have been checked",
            ),
          ])
      }
    }
  }
}

fn fresh_types(count: Int, state: unify.State) -> #(List(Type), unify.State) {
  let #(values, state) =
    list.fold(list.repeat(Nil, count), #([], state), fn(acc, _) {
      let #(value, state) = unify.fresh(acc.1)
      #([value, ..acc.0], state)
    })
  #(list.reverse(values), state)
}

/// Check a field or method against the nominal receiver's substituted metadata
/// and visibility rules.
///
/// ```text
/// Box(Int).value -> Int; a private field needs the correct owner
/// ```
fn object_member(subject: Inferred, name: ast.Name, path: String) -> Inferred {
  let state = subject.state
  case unify.apply(subject.type_, state) {
    monotype.Nominal(module, class_name, kind, arguments)
      if kind == monotype.ClassKind || kind == monotype.ActorKind
    ->
      case unify.class(state, #(module, class_name)) {
        Error(Nil) -> subject
        Ok(class) -> {
          use <- bool.lazy_guard(
            class.actor
              && list.any(class.fields, fn(field) {
              field.name.name == name.name
            }),
            fn() {
              member_error(
                subject,
                name,
                path,
                "actor_field_access",
                "actor state is isolated",
                "Actor fields are accessible only implicitly inside their owning actor.",
              )
            },
          )

          let member = case
            list.find(class.fields, fn(field) { field.name.name == name.name })
          {
            Ok(field) -> Ok(#(field.type_, [], field.owner))
            Error(Nil) ->
              list.find(class.methods, fn(method) {
                method.name.name == name.name
              })
              |> result.map(fn(method) {
                #(method.type_, method.quantified, method.owner)
              })
          }

          let declaring = case member {
            Ok(#(_, _, owner)) -> owner
            Error(Nil) -> nominal.identity(class)
          }
          case
            string.starts_with(name.name, "_")
            && unify.owner(state) != Some(declaring),
            member
          {
            True, _ ->
              member_error(
                subject,
                name,
                path,
                "private_member",
                case class.actor {
                  True -> "private actor member"
                  False -> "private class member"
                },
                "This member is accessible only inside its declaring class.",
              )
            False, Error(Nil) ->
              member_error(
                subject,
                name,
                path,
                "unknown_member",
                case class.actor {
                  True -> "unknown actor message"
                  False -> "unknown class member"
                },
                case class.actor {
                  True ->
                    "The actor declares no ordinary method or behavior with this name."
                  False ->
                    "The class declares no field or method with this name."
                },
              )
            False, Ok(#(type_, quantified, _)) -> {
              let type_ =
                nominal.instantiate(unify.apply(type_, state), class, arguments)
              let #(mapping, state) =
                list.fold(quantified, #(dict.new(), state), fn(acc, id) {
                  let #(variable, state) = unify.fresh(acc.1)
                  #(dict.insert(acc.0, id, variable), state)
                })
              Inferred(
                monotype.replace(type_, mapping),
                state,
                subject.diagnostics,
              )
            }
          }
        }
      }
    monotype.Nominal(module, interface_name, monotype.InterfaceKind, arguments) -> {
      case unify.interface(state, #(module, interface_name)) {
        Error(Nil) -> subject
        Ok(interface) ->
          case
            list.find(interface.methods, fn(method) {
              method.name.name == name.name
            })
          {
            Error(Nil) ->
              member_error(
                subject,
                name,
                path,
                "unknown_member",
                "unknown interface member",
                "The interface declares no method with this name.",
              )
            Ok(method) -> {
              let type_ =
                nominal.instantiate_interface(
                  method.type_,
                  interface,
                  arguments,
                )
              let #(type_, state) =
                scheme.instantiate(
                  scheme.quantified(type_, method.quantified),
                  state,
                )
              Inferred(type_, state, subject.diagnostics)
            }
          }
      }
    }
    _ ->
      member_error(
        subject,
        name,
        path,
        "invalid_member_subject",
        "value has no class members",
        "Field and method access requires a class instance.",
      )
  }
}

fn member_error(
  report: Inferred,
  name: ast.Name,
  path: String,
  id: String,
  title: String,
  detail: String,
) -> Inferred {
  Inferred(
    ..report,
    type_: monotype.ErrorType,
    diagnostics: list.append(report.diagnostics, [
      diagnostic.error("type." <> id, title)
      |> diagnostic.primary(location.new(path, name.span), detail),
    ]),
  )
}

/// Check initialization against the owning field's type while preserving
/// constructor-specific access rules.
///
/// ```text
/// self.value = expression -> expression must match declared field type
/// ```
fn constructor_assignment(
  target: ast.AssignmentTarget,
  value: ast.Expression,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  case context.constructing, target {
    Some(identity), ast.AssignField(ast.SelfExpression(_), name, _) -> {
      use class <- result.try(
        unify.class(state, identity)
        |> result.map_error(fn(_) { Unsupported(span, "constructor receiver") }),
      )
      use field <- result.try(
        list.find(class.fields, fn(field) { field.name.name == name.name })
        |> result.map_error(fn(_) {
          Unsupported(span, "constructor field target")
        }),
      )
      let value_span = ast.expression_span(value)
      use value <- result.try(expression_type(
        value,
        environment,
        state,
        path,
        context,
      ))
      let checked =
        require(
          value,
          field.type_,
          field.name.span,
          value_span,
          path,
          "Field initialization must agree with the class field type.",
        )
      Ok(Inferred(..checked, type_: monotype.NilType))
    }
    _, _ -> Error(Unsupported(span, "assignment outside class construction"))
  }
}

/// Introduce the receiver's fields and callable members into the method's lexical
/// environment.
///
/// ```text
/// an implicit value reference can resolve to self.value inside its class
/// ```
fn class_environment(
  class: nominal.Class,
  environment: Environment,
  state: unify.State,
) -> Environment {
  let visible = fn(name: String, owner: nominal.Identity) {
    !string.starts_with(name, "_") || owner == nominal.identity(class)
  }
  let environment =
    class.fields
    |> list.filter(fn(field) { visible(field.name.name, field.owner) })
    |> list.fold(environment, fn(environment, field) {
      dict.insert(
        environment,
        field.name.name,
        Binding(scheme.monomorphic(field.type_), field.name.span),
      )
    })
  class.methods
  |> list.filter(fn(method) { visible(method.name.name, method.owner) })
  |> list.fold(environment, fn(environment, method) {
    dict.insert(
      environment,
      method.name.name,
      Binding(
        scheme.quantified(unify.apply(method.type_, state), method.quantified),
        method.name.span,
      ),
    )
  })
}

fn class_generics(class: nominal.Class) -> Dict(String, Type) {
  list.zip(class.source.type_parameters, class.parameters)
  |> list.map(fn(pair) { #(pair.0.name, pair.1.1) })
  |> dict.from_list
}

/// Infer construction with an owning class and a construction context, then
/// restore the previous owner.
///
/// ```text
/// constructor field assignment is allowed; ordinary module assignment is not
/// ```
pub fn infer_constructor(
  class: nominal.Class,
  constructor: ast.Constructor,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  let previous_owner = unify.owner(state)
  let state = unify.with_owner(state, Some(nominal.identity(class)))
  let #(core, state) = core_environment(state)
  let environment =
    class_environment(class, dict.merge(core, environment), state)
  let generics = class_generics(class)
  use #(parameters, locals, state) <- result.try(parameters_type(
    constructor.parameters,
    environment,
    state,
    generics,
    path,
  ))
  use report <- result.try(block_type(
    constructor.body,
    locals,
    state,
    path,
    Context(
      None,
      None,
      Ordinary,
      generics,
      Some(nominal.identity(class)),
      False,
    ),
  ))
  Ok(Inferred(
    monotype.FunctionType(parameters, nominal.type_(class)),
    unify.with_owner(report.state, previous_owner),
    report.diagnostics,
  ))
}

/// Infer a method with class generics and private ownership in scope.
///
/// ```text
/// Box(a).get() -> a uses the owning class's a
/// ```
pub fn infer_method(
  class: nominal.Class,
  method: ast.Function,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  let previous_owner = unify.owner(state)
  let state = unify.with_owner(state, Some(nominal.identity(class)))
  let #(core, state) = core_environment(state)
  use report <- result.try(callable(
    method.parameters,
    method.return_type,
    method.body,
    method.span,
    class_environment(class, dict.merge(core, environment), state),
    state,
    path,
    Context(None, None, Ordinary, class_generics(class), None, class.actor),
  ))
  Ok(Inferred(..report, state: unify.with_owner(report.state, previous_owner)))
}

/// Check an optional field initializer under its class environment.
///
/// ```text
/// let count: Int = 0 -> default matches Int
/// ```
pub fn infer_field_default(
  class: nominal.Class,
  field: ast.Field,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(Inferred, Unsupported) {
  case field.value {
    None -> Ok(inferred(monotype.NilType, state))
    Some(value) -> {
      let #(core, state) = core_environment(state)
      expression_type(
        value,
        dict.merge(core, environment),
        state,
        path,
        Context(None, None, Ordinary, class_generics(class), None, False),
      )
    }
  }
}

/// Check each argument against the known parameter signature and return the
/// substituted result type.
///
/// ```text
/// fn(Int) -> String called with Bool -> argument diagnostic
/// ```
fn known_function_call(
  callee: Inferred,
  callee_span: Span,
  arguments: List(ast.Expression),
  argument_types: List(Type),
  report: Inferred,
  path: String,
  otherwise: fn() -> Result(Inferred, Unsupported),
) -> Result(Inferred, Unsupported) {
  case unify.apply(callee.type_, report.state) {
    monotype.FunctionType(parameters, result) ->
      case list.length(parameters) == list.length(arguments) {
        False -> otherwise()
        True -> {
          let initial =
            Inferred(
              result,
              report.state,
              list.append(callee.diagnostics, report.diagnostics),
            )
          let checked =
            list.zip(parameters, list.zip(arguments, argument_types))
            |> list.fold(initial, fn(report, pair) {
              let #(parameter, #(argument, found)) = pair
              let checked =
                require(
                  Inferred(found, report.state, []),
                  parameter,
                  callee_span,
                  ast.expression_span(argument),
                  path,
                  "Each argument must match the type of its parameter.",
                )
              Inferred(
                result,
                checked.state,
                list.append(report.diagnostics, checked.diagnostics),
              )
            })
          let type_ = case diagnostic.has_errors(checked.diagnostics) {
            True -> monotype.ErrorType
            False -> unify.apply(result, checked.state)
          }
          Ok(Inferred(..checked, type_:))
        }
      }
    _ -> otherwise()
  }
}

fn super_member(
  name: ast.Name,
  span: Span,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  let current = case context.constructing {
    Some(identity) -> Some(identity)
    None -> unify.owner(state)
  }
  use class <- result.try(
    option.to_result(current, Nil)
    |> result.try(unify.class(state, _))
    |> result.map_error(fn(_) { Unsupported(span, "super outside a class") }),
  )
  use link <- result.try(option.to_result(
    class.superclass,
    Unsupported(span, "super without a superclass"),
  ))
  use parent <- result.try(
    unify.class(state, link.identity)
    |> result.map_error(fn(_) { Unsupported(span, "unregistered superclass") }),
  )
  let view = fn(type_) {
    nominal.instantiate(unify.apply(type_, state), parent, link.arguments)
  }
  let fresh_quantified = fn(type_, quantified, state) {
    let #(mapping, state) =
      list.fold(quantified, #(dict.new(), state), fn(acc, id) {
        let #(variable, state) = unify.fresh(acc.1)
        #(dict.insert(acc.0, id, variable), state)
      })
    #(monotype.replace(type_, mapping), state)
  }
  case name.name {
    "new" ->
      case view(parent.constructor) {
        monotype.FunctionType(parameters, _) -> {
          let #(type_, state) =
            fresh_quantified(
              monotype.FunctionType(parameters, monotype.NilType),
              parent.constructor_quantified,
              state,
            )
          Ok(inferred(type_, state))
        }
        _ -> Ok(inferred(monotype.ErrorType, state))
      }
    _ ->
      case
        list.find(parent.methods, fn(method) {
          method.name.name == name.name
          && !string.starts_with(method.name.name, "_")
        })
      {
        Ok(method) -> {
          let #(type_, state) =
            fresh_quantified(view(method.type_), method.quantified, state)
          Ok(inferred(type_, state))
        }
        Error(Nil) ->
          Ok(
            Inferred(monotype.ErrorType, state, [
              diagnostic.error(
                "type.unknown_super_member",
                "unknown superclass method",
              )
              |> diagnostic.primary(
                location.new(path, name.span),
                "`"
                  <> parent.source.name.name
                  <> "` has no method `"
                  <> name.name
                  <> "`",
              )
              |> diagnostic.conclusion(
                "`super` can call the public methods of the immediate superclass.",
              ),
            ]),
          )
      }
  }
}

fn abstract_class(
  class: nominal.Class,
  span: Span,
  path: String,
) -> Diagnostic {
  let name = class.source.name.name
  diagnostic.error(
    "type.abstract_class",
    "class cannot be constructed directly",
  )
  |> diagnostic.primary(
    location.new(path, span),
    "`" <> name <> "` has subclasses and no `new`",
  )
  |> diagnostic.conclusion(
    "Only the subclasses of `" <> name <> "` can be constructed.",
  )
  |> diagnostic.help(
    "Construct one of its subclasses, or declare `new` in `" <> name <> "`.",
  )
}

/// Constrain a shared result slot to the nearest compatible type known from its
/// alternatives.
///
/// ```text
/// Some(Tmp) and Some(Con) branches -> Option(Ref)
/// ```
fn join_into(
  target: Type,
  types: List(Type),
  span: Span,
  path: String,
  state: unify.State,
) -> unify.State {
  let known =
    types
    |> list.map(unify.apply(_, state))
    |> list.filter(fn(type_) {
      case type_ {
        monotype.Variable(_) -> False
        _ -> True
      }
    })
  case unify.join(state, known) {
    Ok(joined) -> {
      let origin =
        unify.Origin(
          location.new(path, span),
          location.new(path, span),
          "Values share their nearest compatible common type.",
        )
      case unify.unify(target, joined, origin, state) {
        Ok(state) -> state
        Error(_) -> state
      }
    }
    Error(Nil) -> state
  }
}

/// Check writes only in the actor contexts that permit mutation. The field's
/// declared type still constrains every new value.
///
/// ```text
/// actor var count: Int accepts count += 1, not a String assignment
/// ```
fn actor_assignment(
  name: ast.Name,
  operator: ast.AssignmentOperator,
  value: ast.Expression,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  let descriptor = case unify.owner(state) {
    Some(identity) -> unify.class(state, identity)
    None -> Error(Nil)
  }
  use class <- result.try(
    descriptor
    |> result.map_error(fn(_) {
      Unsupported(span, "state assignment outside an actor")
    }),
  )
  use field <- result.try(
    list.find(class.fields, fn(field) { field.name.name == name.name })
    |> result.map_error(fn(_) { Unsupported(span, "unknown actor state") }),
  )
  let mutable =
    list.any(class.source.members, fn(member) {
      case member {
        ast.FieldMember(source) ->
          source.name.name == name.name && source.mutability == ast.Mutable
        _ -> False
      }
    })
  let unshadowed = case dict.get(environment, name.name) {
    Ok(Binding(_, at)) -> at == field.name.span
    _ -> False
  }
  use <- bool.lazy_guard(
    !class.actor || !context.actor_writes || !mutable || !unshadowed,
    fn() {
      Ok(
        Inferred(monotype.ErrorType, state, [
          diagnostic.error(
            "type.actor_state_assignment",
            "actor state cannot be assigned here",
          )
          |> diagnostic.primary(
            location.new(path, span),
            "Only an unshadowed var field in an actor method or behavior may be updated; captured fields are immutable.",
          ),
        ]),
      )
    },
  )
  let value = case operator {
    ast.Assign -> value
    _ ->
      ast.Binary(
        case operator {
          ast.AddAssign -> ast.Add
          ast.SubtractAssign -> ast.Subtract
          ast.MultiplyAssign -> ast.Multiply
          ast.Assign -> ast.Add
        },
        ast.Variable(name.name, name.span),
        value,
        span,
      )
  }
  use found <- result.try(expression_type(
    value,
    environment,
    state,
    path,
    context,
  ))
  let checked =
    require(
      found,
      field.type_,
      field.name.span,
      ast.expression_span(value),
      path,
      "Actor state updates must preserve the declared field type.",
    )
  Ok(Inferred(..checked, type_: monotype.NilType))
}

/// Check list iteration or the explicit iterator interface and bind the loop
/// pattern to its element type.
///
/// ```text
/// loop Box(value) in boxes -> value gets the Box field type
/// ```
fn infer_iteration(
  iteration: ast.Iteration,
  body: ast.Block,
  span: Span,
  environment: Environment,
  state: unify.State,
  path: String,
  context: Context,
) -> Result(Inferred, Unsupported) {
  use source <- result.try(expression_type(
    iteration.iterable,
    environment,
    state,
    path,
    context,
  ))
  let #(element, state) = unify.fresh(source.state)
  let source = Inferred(..source, state:)
  let checked = case unify.apply(source.type_, state) {
    monotype.Variable(_) | monotype.ListType(_) ->
      require(
        source,
        monotype.ListType(element),
        span,
        ast.expression_span(iteration.iterable),
        path,
        "List iteration uses one homogeneous element type.",
      )
    monotype.ErrorType -> source
    type_ -> {
      let view = iterator_view(type_, state)
      case view {
        Ok(monotype.Nominal(module, name, _, [item])) -> {
          let interface = unify.interface(state, #(module, name))
          let contract = case interface {
            Ok(interface) ->
              list.find(interface.methods, fn(method) {
                method.name.name == "next"
              })
              |> result.map(fn(method) {
                nominal.instantiate_interface(method.type_, interface, [item])
              })
            Error(Nil) -> Error(Nil)
          }
          case contract {
            Ok(contract) -> {
              let contract_check =
                require(
                  inferred(contract, state),
                  monotype.FunctionType([], monotype.OptionType(element)),
                  span,
                  span,
                  path,
                  "Iterator(a).next must take no arguments and return Option(a).",
                )
              require(
                Inferred(..contract_check, type_: item),
                element,
                span,
                span,
                path,
                "Iteration elements use the declared interface argument.",
              )
            }
            Error(Nil) -> iteration_error(source, span, path)
          }
        }
        _ -> iteration_error(source, span, path)
      }
    }
  }
  let #(loop_type, state) = unify.fresh(checked.state)
  let before = state
  use pattern <- result.try(bind_pattern(
    iteration.pattern,
    element,
    environment,
    state,
    path,
  ))
  let loop_context = Context(..context, loop: Some(loop_type))
  use body_report <- result.try(block_type(
    body,
    pattern.environment,
    pattern.state,
    path,
    loop_context,
  ))
  let branch =
    ast.Branch(
      iteration.pattern,
      None,
      ast.BlockExpression(body),
      iteration.span,
    )
  let body_report = finish_loop(body_report, loop_type, span, path, True)
  let body_report =
    reject_pattern_escape(
      pattern,
      environment,
      element,
      before,
      body_report,
      loop_context,
      path,
      branch,
    )
  let coverage = case
    diagnostic.has_errors(list.append(checked.diagnostics, pattern.diagnostics))
  {
    True -> []
    False ->
      exhaustiveness.check_in(
        unify.apply(element, body_report.state),
        [branch],
        path,
        ast.pattern_span(iteration.pattern),
        body_report.state,
      )
      |> list.map(fn(issue) {
        diagnostic.Diagnostic(
          ..issue,
          title: "iteration pattern must match every element",
          conclusion: "Use an irrefutable loop pattern and match inside the body to select elements.",
          suggestions: [],
        )
      })
  }
  Ok(
    Inferred(
      ..body_report,
      diagnostics: list.flatten([
        checked.diagnostics,
        pattern.diagnostics,
        body_report.diagnostics,
        coverage,
      ]),
    ),
  )
}

fn iteration_error(source: Inferred, span: Span, path: String) -> Inferred {
  Inferred(
    ..source,
    type_: monotype.ErrorType,
    diagnostics: list.append(source.diagnostics, [
      diagnostic.error("type.not_iterable", "value is not iterable")
      |> diagnostic.primary(
        location.new(path, span),
        "Expected a List or a value explicitly implementing iterator.Iterator(a).",
      ),
    ]),
  )
}

/// Combine break-value constraints and distinguish effect loops from value-
/// producing loops.
///
/// ```text
/// effect loop result -> Nil; explicit compatible breaks may produce Int
/// ```
fn finish_loop(
  report: Inferred,
  loop: Type,
  span: Span,
  path: String,
  exhausted: Bool,
) -> Inferred {
  let breaks = unify.loop_breaks(report.state, loop)
  let #(state, evidence) = case breaks {
    [] -> #(report.state, span)
    [first, ..] -> #(
      join_into(
        loop,
        list.map(breaks, fn(value) { value.0 }),
        first.1,
        path,
        report.state,
      ),
      first.1,
    )
  }
  let report =
    list.fold(breaks, Inferred(..report, state:), fn(report, value) {
      let checked =
        require(
          inferred(value.0, report.state),
          loop,
          evidence,
          value.1,
          path,
          "Every break from this loop must produce a compatible type.",
        )
      Inferred(
        ..report,
        state: checked.state,
        diagnostics: list.append(report.diagnostics, checked.diagnostics),
      )
    })
  let report = case breaks, exhausted {
    [], True ->
      require(
        Inferred(..report, type_: monotype.NilType),
        loop,
        span,
        span,
        path,
        "An effect-only iteration loop returns Nil when exhausted.",
      )
    _, _ -> report
  }
  Inferred(..report, type_: case diagnostic.has_errors(report.diagnostics) {
    True -> monotype.ErrorType
    False -> unify.apply(loop, report.state)
  })
}

/// Recognize the supported Iterator interface identities, including their
/// package-qualified forms. A method named next alone is not the protocol.
///
/// ```text
/// declared iterator.Iterator(a) -> iterable view; unrelated next method -> no view
/// ```
fn iterator_view(value: Type, state: unify.State) -> Result(Type, Nil) {
  case value {
    monotype.Nominal(module, "Iterator", monotype.InterfaceKind, _) ->
      case string.split(module, "/") {
        ["iterator"]
        | ["$package", _, "iterator"]
        | ["pooka", "iterator"]
        | ["$package", _, "pooka", "iterator"] -> Ok(value)
        _ -> Error(Nil)
      }
    monotype.Nominal(module, name, _, arguments) -> {
      use class <- result.try(unify.class(state, #(module, name)))
      list.find_map(class.interfaces, fn(view) {
        iterator_view(
          nominal.instantiate(unify.apply(view, state), class, arguments),
          state,
        )
      })
    }
    _ -> Error(Nil)
  }
}

fn enum_subject(
  subject: ast.Expression,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(nominal.Enum, Nil) {
  case subject {
    ast.TypeName(name, _) ->
      case dict.get(environment, name) {
        Ok(EnumBinding(identity)) -> unify.enum(state, identity)
        _ -> Error(Nil)
      }
    ast.FieldAccess(ast.Variable(alias, _), name, _) ->
      case dict.get(environment, alias) {
        Ok(ModuleBinding(..)) -> unify.named_enum(state, path, alias, name.name)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn enum_through_module(
  subject: ast.Expression,
  name: ast.Name,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(nominal.Identity, Nil) {
  case subject {
    ast.Variable(alias, _) ->
      case dict.get(environment, alias) {
        Ok(ModuleBinding(..)) ->
          unify.named_enum(state, path, alias, name.name)
          |> result.map(nominal.enum_identity)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn enum_subject_of(
  callee: ast.Expression,
  environment: Environment,
  state: unify.State,
  path: String,
) -> Result(#(nominal.Enum, ast.Name), Nil) {
  case callee {
    ast.FieldAccess(subject, variant, _) ->
      enum_subject(subject, environment, state, path)
      |> result.map(fn(enum) { #(enum, variant) })
    _ -> Error(Nil)
  }
}

fn enum_variant(
  enum: nominal.Enum,
  variant: ast.Name,
  state: unify.State,
  path: String,
) -> Inferred {
  case list.contains(nominal.variants(enum), variant.name) {
    True -> inferred(nominal.enum_type(enum), state)
    False ->
      Inferred(monotype.ErrorType, state, [
        unknown_variant(enum, variant, path),
      ])
  }
}

fn unknown_variant(
  enum: nominal.Enum,
  variant: ast.Name,
  path: String,
) -> Diagnostic {
  let name = enum.source.name.name
  let variants = nominal.variants(enum)
  let base =
    diagnostic.error("type.unknown_enum_variant", "unknown enum variant")
    |> diagnostic.primary(
      location.new(path, variant.span),
      "`" <> name <> "` has no variant named `" <> variant.name <> "`",
    )
    |> diagnostic.conclusion(
      "The variants of `"
      <> name
      <> "` are "
      <> string.join(list.map(variants, fn(v) { "`" <> v <> "`" }), ", ")
      <> ".",
    )
  case text.closest(variant.name, list.sort(variants, string.compare)) {
    Some(suggestion) ->
      diagnostic.help(
        base,
        "Did you mean `" <> name <> "." <> suggestion <> "`?",
      )
    None -> base
  }
}

/// Check arguments and result type for a declared enum variant constructor.
///
/// ```text
/// variant constructor -> enum type under the current type arguments
/// ```
fn enum_call(
  enum: nominal.Enum,
  variant: ast.Name,
  callee: ast.Expression,
  arguments: List(ast.Expression),
  span: Span,
  state: unify.State,
  path: String,
) -> Inferred {
  let value = enum_variant(enum, variant, state, path)
  let callee_span = ast.expression_span(callee)
  let selected = enum.source.name.name <> "." <> variant.name
  let call =
    diagnostic.error("type.enum_variant_call", "enum variant called")
    |> diagnostic.primary(
      location.new(path, location.Span(callee_span.end, span.end)),
      case arguments {
        [] -> "remove these parentheses"
        _ -> "enum variants carry no data"
      },
    )
    |> diagnostic.conclusion(
      "`"
      <> selected
      <> "` is a value, not a constructor, so it is used without parentheses.",
    )
    |> diagnostic.help("Write `" <> selected <> "`.")
  Inferred(..value, diagnostics: list.append(value.diagnostics, [call]))
}

fn enum_as_value(
  identity: nominal.Identity,
  span: Span,
  state: unify.State,
  path: String,
) -> Diagnostic {
  let example = case unify.enum(state, identity) {
    Ok(enum) ->
      case nominal.variants(enum) {
        [first, ..] -> " such as `" <> identity.1 <> "." <> first <> "`"
        [] -> ""
      }
    Error(Nil) -> ""
  }
  diagnostic.error("type.enum_as_value", "enum used as a value")
  |> diagnostic.primary(
    location.new(path, span),
    "`" <> identity.1 <> "` is an enum type",
  )
  |> diagnostic.conclusion("Select one of its variants" <> example <> ".")
}

/// Check an enum variant pattern using its declared enum identity, not a
/// coincidentally equal spelling.
///
/// ```text
/// Order.Less pattern -> subject must have the Order enum type
/// ```
fn enum_pattern(
  qualifier: String,
  enum_name: String,
  variant: ast.Name,
  span: Span,
  subject: Type,
  environment: Environment,
  state: unify.State,
  path: String,
) -> PatternReport {
  case unify.named_enum(state, path, qualifier, enum_name) {
    Error(Nil) ->
      PatternReport(
        environment,
        state,
        [
          diagnostic.error("type.not_an_enum", "pattern does not name an enum")
          |> diagnostic.primary(
            location.new(path, span),
            "`" <> enum_name <> "` is not an enum",
          )
          |> diagnostic.conclusion(
            "`Name.Variant` patterns match enum variants. Classes are matched with `Name(...)`.",
          ),
        ],
        None,
      )
    Ok(enum) -> {
      let checked =
        require(
          inferred(subject, state),
          nominal.enum_type(enum),
          span,
          span,
          path,
          "The enum pattern must match the subject's type.",
        )
      let variant = case list.contains(nominal.variants(enum), variant.name) {
        True -> []
        False -> [unknown_variant(enum, variant, path)]
      }
      PatternReport(
        environment,
        checked.state,
        list.append(checked.diagnostics, variant),
        None,
      )
    }
  }
}
