//// Translate the checked manuscript into terms the BEAM already understands.
////
//// Lower expressions, classes, actors and control flow to Erlang abstract forms.
//// Preserve evaluation order with fresh bindings and carry source lines into
//// nodes so runtime failures still know where they began.
////
//// ```text
//// Pooka 5 / 2 -> {op,1,'div',{integer,1,5},{integer,1,2}}
//// ```
////
//// The route through this module is:
////
//// - generate_internal assembles attributes and declaration forms.
//// - expression lowers values while evaluate pins child evaluation order.
//// - block and lower_pattern carry lexical bindings into matches and clauses.
//// - class_forms and actor_forms emit the runtime entrypoints for nominal values.
//// - return_boundary and loop lowering catch only their own control-flow tags.
////
//// Context carries fresh names, receiver/construction state and checked metadata.
//// A representation choice such as integer div is read from the inferred type;
//// this module must not guess it again from the spelling of an operand.
//// Generated names in explanatory diagrams are schematic unless a complete
//// abstract term is shown. Erlang annotations refer back to Pooka source lines.
////
//// See https://www.erlang.org/doc/apps/erts/absform.html#expressions for the
//// expression shapes, and #module-declarations-and-forms for the outer forms.

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/constructor as constructor_analysis
import compiler/codegen/class_layout
import compiler/codegen/forms as f
import compiler/codegen/propagation
import compiler/constant
import compiler/foreign_language
import compiler/literal
import compiler/parser/ast
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/nominal
import compiler/typesystem/typed_ast
import compiler/typesystem/unify
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/package
import utilities/location.{type Span}

pub type Unsupported {
  Unsupported(span: Span, feature: String)
}

pub type Output {
  Output(name: String, forms: List(f.Term), tests: List(Test))
}

pub type Test {
  Test(name: String, description: String, span: Span, skipped: Bool)
}

type Reference {
  Local(name: String, arity: Int)
  Remote(module: String, name: String, arity: Int)
}

type Context {
  Context(
    locals: Dict(String, f.Term),
    functions: Dict(String, Reference),
    modules: Dict(String, Dict(String, Reference)),
    next: Int,
    state: unify.State,
    path: String,
    namespace: String,
    class: Option(nominal.Identity),
    receiver: Option(f.Term),
    constructing: Option(f.Term),
  )
}

/// Lower a checked production module. The type report travels with the syntax so
/// dispatch and primitive operations need no fresh inference.
///
/// ```text
/// checked module -> attributes + exported function forms
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
pub fn generate(
  module: typed_ast.Module,
  namespace: String,
  identity: String,
  available: Dict(String, module_infer.Module),
) -> Result(Output, Unsupported) {
  generate_internal(module, namespace, identity, available, False)
}

/// Use the same lowering rules with test declarations included. Generated test
/// wrappers still use ordinary Erlang function forms.
///
/// ```text
/// test declaration -> exported zero-argument test function
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
pub fn generate_tests(
  module: typed_ast.Module,
  namespace: String,
  identity: String,
  available: Dict(String, module_infer.Module),
) -> Result(Output, Unsupported) {
  generate_internal(module, namespace, identity, available, True)
}

/// Assemble module attributes, namespace references, functions and nominal
/// dispatchers. Keep test selection at this outer boundary.
///
/// ```erlang
/// {attribute,1,module,'pooka@app@main'}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn generate_internal(
  module: typed_ast.Module,
  namespace: String,
  identity: String,
  available: Dict(String, module_infer.Module),
  include_tests: Bool,
) -> Result(Output, Unsupported) {
  let syntax = typed_ast.syntax(module)
  let inferred = typed_ast.inferred(module)
  let path = typed_ast.path(module)

  let state =
    list.fold(
      unify.classes_for_path(inferred.state, path),
      inferred.state,
      fn(state, class) {
        unify.register_class(
          state,
          nominal.Class(..class, runtime_module: identity),
        )
      },
    )
  let inferred = module_infer.Module(..inferred, state:)
  let functions =
    list.fold(
      inferred.functions,
      dict.from_list([#("echo", Remote("pooka_runtime_ffi", "echo", 1))]),
      fn(found, value) {
        case value.type_ {
          monotype.FunctionType(parameters, _) ->
            dict.insert(
              found,
              value.name.name,
              Local(value.name.name, list.length(parameters)),
            )
          _ -> found
        }
      },
    )
  let #(functions, modules) =
    list.fold(syntax.imports, #(functions, dict.new()), fn(acc, imported) {
      let identity = string.join(imported.module.segments, "/")
      let exports = case dict.get(available, identity) {
        Error(Nil) -> dict.new()
        Ok(target) ->
          list.fold(target.functions, dict.new(), fn(found, value) {
            case value.type_, string.starts_with(value.name.name, "_") {
              monotype.FunctionType(parameters, _), False ->
                dict.insert(
                  found,
                  value.name.name,
                  Remote(
                    module_name(namespace, identity),
                    value.name.name,
                    list.length(parameters),
                  ),
                )
              _, _ -> found
            }
          })
      }
      let alias = case imported.alias {
        Some(alias) -> alias.name
        None -> list.last(imported.module.segments) |> result.unwrap(identity)
      }

      let exports = case dict.get(available, identity) {
        Error(Nil) -> exports
        Ok(target) ->
          list.fold(
            unify.classes_in(target.state, identity),
            exports,
            fn(exports, class) {
              let arity = case unify.apply(class.constructor, target.state) {
                monotype.FunctionType(args, _) -> list.length(args)
                _ -> 0
              }
              case string.starts_with(class.source.name.name, "_") {
                True -> exports
                False ->
                  dict.insert(
                    exports,
                    class.source.name.name,
                    Remote(
                      module_name(namespace, identity),
                      nominal.function_name(class.source.name.name, "new"),
                      arity,
                    ),
                  )
              }
            },
          )
      }
      let functions =
        list.fold(imported.items, acc.0, fn(found, item) {
          case dict.get(exports, item.name.name) {
            Error(Nil) -> found
            Ok(reference) ->
              dict.insert(
                found,
                case item.alias {
                  Some(alias) -> alias.name
                  None -> item.name.name
                },
                reference,
              )
          }
        })
      let namespaces = case dict.get(available, identity) {
        Ok(target) ->
          list.filter(target.externals, fn(namespace) {
            !string.starts_with(namespace.name.name, "_")
          })
        Error(Nil) -> []
      }
      let modules =
        list.fold(
          namespaces,
          dict.insert(acc.1, alias, exports),
          fn(found, namespace) {
            let references = namespace_references(namespace)
            let found =
              dict.insert(
                found,
                alias <> "." <> namespace.name.name,
                references,
              )
            case
              list.find(imported.items, fn(item) {
                item.name.name == namespace.name.name
              })
            {
              Ok(item) ->
                dict.insert(
                  found,
                  case item.alias {
                    Some(alias) -> alias.name
                    None -> item.name.name
                  },
                  references,
                )
              Error(Nil) -> found
            }
          },
        )
      #(functions, modules)
    })

  let modules =
    list.fold(inferred.externals, modules, fn(found, namespace) {
      dict.insert(found, namespace.name.name, namespace_references(namespace))
    })
  let classes = unify.classes_for_path(inferred.state, path)
  let functions =
    list.fold(classes, functions, fn(functions, class) {
      let arity = case unify.apply(class.constructor, inferred.state) {
        monotype.FunctionType(args, _) -> list.length(args)
        _ -> 0
      }
      dict.insert(
        functions,
        class.source.name.name,
        Local(nominal.function_name(class.source.name.name, "new"), arity),
      )
    })
  let context =
    Context(
      dict.new(),
      functions,
      modules,
      0,
      inferred.state,
      path,
      namespace,
      None,
      None,
      None,
    )
  use #(definitions, context) <- result.try(
    list.try_fold(syntax.declarations, #([], context), fn(acc, declaration) {
      case declaration {
        ast.FunctionDeclaration(function) -> {
          use #(form, context) <- result.try(function_form(function, acc.1))
          Ok(#([form, ..acc.0], context))
        }
        ast.TestDeclaration(_) -> Ok(acc)

        ast.ExternalDeclaration(_) -> Ok(acc)
        ast.ClassDeclaration(value) -> {
          use #(forms, context) <- result.try(class_forms(value, acc.1))
          Ok(#(list.append(list.reverse(forms), acc.0), context))
        }
        ast.ActorDeclaration(value) -> {
          use #(forms, context) <- result.try(actor_forms(
            nominal.actor_class(value),
            acc.1,
          ))
          Ok(#(list.append(list.reverse(forms), acc.0), context))
        }

        ast.InterfaceDeclaration(_) -> Ok(acc)

        ast.EnumDeclaration(_) -> Ok(acc)
      }
    }),
  )
  use #(definitions, tests, _) <- result.try(
    list.try_fold(
      syntax.declarations,
      #(definitions, [], context),
      fn(acc, declaration) {
        case declaration, include_tests {
          ast.TestDeclaration(test_case), True -> {
            let name = "$pooka_test_" <> int.to_string(list.length(acc.1))

            let body =
              ast.Block(
                list.append(test_case.body.statements, [
                  ast.ExpressionStatement(ast.NilLiteral(test_case.body.span)),
                ]),
                test_case.body.span,
              )
            let function =
              ast.Function(
                [],
                ast.Name(name, test_case.span),
                [],
                None,
                body,
                test_case.span,
              )
            use #(form, context) <- result.try(function_form(function, acc.2))
            Ok(#(
              [form, ..acc.0],
              [
                Test(name, test_case.name, test_case.span, test_case.skipped),
                ..acc.1
              ],
              context,
            ))
          }
          _, _ -> Ok(acc)
        }
      },
    ),
  )
  let interface_forms = interface_dispatcher(classes, inferred.state)
  let definitions = list.append(definitions, interface_forms)
  let name = module_name(namespace, identity)
  let exports =
    list.filter_map(inferred.functions, fn(value) {
      case value.type_, string.starts_with(value.name.name, "_") {
        monotype.FunctionType(parameters, _), False ->
          Ok(
            f.Tuple([
              f.Atom(value.name.name),
              f.Integer(list.length(parameters)),
            ]),
          )
        _, _ -> Error(Nil)
      }
    })
  let class_exports =
    list.flat_map(classes, fn(class) {
      let ctor_arity = case unify.apply(class.constructor, inferred.state) {
        monotype.FunctionType(args, _) -> list.length(args)
        _ -> 0
      }
      [
        f.Tuple([
          f.Atom(nominal.function_name(class.source.name.name, "new")),
          f.Integer(ctor_arity),
        ]),
        ..list.map(class.methods, fn(method) {
          let arity = case unify.apply(method.type_, inferred.state) {
            monotype.FunctionType(args, _) -> list.length(args) + 1
            _ -> 1
          }
          f.Tuple([
            f.Atom(nominal.function_name(
              class.source.name.name,
              method.name.name,
            )),
            f.Integer(arity),
          ])
        })
      ]
    })
  let actor_exports =
    list.flat_map(list.filter(classes, fn(class) { class.actor }), fn(class) {
      let arity = case class.constructor {
        monotype.FunctionType(args, _) -> list.length(args)
        _ -> 0
      }
      [
        f.Tuple([f.Atom(actor_initializer(class)), f.Integer(arity)]),
        ..list.map(class.methods, fn(method) {
          let arity = case unify.apply(method.type_, inferred.state) {
            monotype.FunctionType(args, _) -> list.length(args) + 1
            _ -> 1
          }
          f.Tuple([
            f.Atom(actor_body(class, method.name.name)),
            f.Integer(arity),
          ])
        })
      ]
    })
  let exports = list.append(exports, actor_exports)
  let exports = list.append(exports, class_exports)
  let exports = case interface_forms {
    [] -> exports
    _ -> [f.Tuple([f.Atom("$interface@call"), f.Integer(3)]), ..exports]
  }
  let exports =
    list.append(
      exports,
      list.map(tests, fn(test_case) {
        f.Tuple([f.Atom(test_case.name), f.Integer(0)])
      }),
    )
  Ok(Output(
    name,
    [
      f.node("attribute", 1, [f.Atom("module"), f.Atom(name)]),
      f.node("attribute", 1, [
        f.Atom("file"),
        f.Tuple([f.Characters(path), f.Integer(1)]),
      ]),
      f.node("attribute", 1, [f.Atom("export"), f.Sequence(exports)]),
      ..list.reverse(definitions)
    ],
    list.reverse(tests),
  ))
}

/// Give a source module its package-qualified BEAM identity. The separators
/// prevent neighbouring packages from sharing a module by accident.
///
/// ```text
/// module_name("app", "main") -> "pooka@app@main"
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
pub fn module_name(namespace: String, identity: String) -> String {
  let #(namespace, identity) = package.module_owner(identity, namespace)
  "pooka@" <> namespace <> "@" <> string.replace(identity, "/", "@")
}

/// Emit a named function from its checked parameters and body. Each clause
/// receives source annotations from the original declaration.
///
/// ```erlang
/// {function,1,identity,1,[{clause,1,[{var,1,'X'}],[],[{var,1,'X'}]}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn function_form(
  function: ast.Function,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = function.span.start.line
  let outer = context.locals
  let #(parameters, context) =
    parameters(function.parameters, Context(..context, locals: dict.new()))
  use #(body, context) <- result.try(block(function.body, context))
  let #(returned, context) = fresh(context, line)
  Ok(#(
    f.node("function", line, [
      f.Atom(function.name.name),
      f.Integer(list.length(parameters)),
      f.Sequence([
        f.clause(
          parameters,
          [return_boundary(body, line, returned, function.body)],
          line,
        ),
      ]),
    ]),
    Context(..context, locals: outer),
  ))
}

/// Reserve a new Erlang variable in the lowering context. A fresh name keeps one
/// evaluation from accidentally reusing another binding.
///
/// ```erlang
/// {var,1,'Pooka0'}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn fresh(context: Context, line: Int) -> #(f.Term, Context) {
  #(
    f.variable("M" <> int.to_string(context.next), line),
    Context(..context, next: context.next + 1),
  )
}

/// Assign Erlang variables to source parameters and extend the local environment.
/// Discarded parameters use wildcard patterns rather than exported names.
///
/// ```erlang
/// {var,1,'_'}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn parameters(
  values: List(ast.Parameter),
  context: Context,
) -> #(List(f.Term), Context) {
  let #(values, context) =
    list.fold(values, #([], context), fn(acc, parameter) {
      let #(variable, context) = fresh(acc.1, parameter.span.start.line)
      let context = case parameter.name {
        ast.NamedParameter(name) ->
          Context(
            ..context,
            locals: dict.insert(context.locals, name, variable),
          )
        ast.DiscardedParameter -> context
      }
      #([variable, ..acc.0], context)
    })
  #(list.reverse(values), context)
}

/// Lower statements in order while carrying local bindings. A let becomes a match
/// expression; its final expression supplies the block's value.
///
/// ```erlang
/// {match,1,{var,1,'X'},{integer,1,42}}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn block(
  value: ast.Block,
  context: Context,
) -> Result(#(List(f.Term), Context), Unsupported) {
  use #(body, context, final_expression) <- result.try(
    list.try_fold(value.statements, #([], context, False), fn(acc, statement) {
      case statement {
        ast.ExpressionStatement(value) -> {
          use #(value, context) <- result.try(expression(value, acc.1))
          Ok(#([value, ..acc.0], context, True))
        }
        ast.LetAssertStatement(pattern:, value:, message:, span:, ..) -> {
          let line = span.start.line
          let outer = acc.1.locals
          use #(bindings, values, context) <- result.try(evaluate(
            [value],
            acc.1,
          ))
          let assert [value] = values
          let success_state = context.constructing
          use #(message, context) <- result.try(case message {
            None ->
              Ok(#(binary_text("pattern assertion failed", line), context))
            Some(message) -> expression(message, context)
          })

          let context = Context(..context, constructing: success_state)
          use #(check_pattern, context) <- result.try(lower_pattern(
            pattern,
            context,
          ))
          use #(bound_pattern, context) <- result.try(lower_pattern(
            pattern,
            Context(..context, locals: outer),
          ))
          let checked =
            f.node("case", line, [
              value,
              f.Sequence([
                f.clause([check_pattern], [value], line),
                f.clause(
                  [f.variable("_", line)],
                  [
                    f.remote(
                      "pooka_runtime_ffi",
                      "assert",
                      [f.atom("false", line), message],
                      line,
                    ),
                  ],
                  line,
                ),
              ]),
            ])
          Ok(#(
            [
              sequence(
                bindings,
                f.node("match", line, [bound_pattern, checked]),
                line,
              ),
              ..acc.0
            ],
            context,
            False,
          ))
        }
        ast.LetStatement(pattern:, value:, ..) -> {
          use #(value, context) <- result.try(expression(value, acc.1))
          use #(pattern, context) <- result.try(lower_pattern(pattern, context))
          Ok(#(
            [f.node("match", value_line(statement), [pattern, value]), ..acc.0],
            context,
            False,
          ))
        }
      }
    }),
  )
  let body = list.reverse(body)
  Ok(#(
    case final_expression {
      True -> body
      False -> list.append(body, [f.atom("nil", value.span.end.line)])
    },
    context,
  ))
}

/// Recover the source line of a statement for emitted annotations. This number
/// belongs to Pooka source, not to a generated Erlang file.
///
/// ```text
/// let at source line 12 -> ANNO 12
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn value_line(value: ast.Statement) -> Int {
  case value {
    ast.ExpressionStatement(value) -> ast.expression_span(value).start.line
    ast.LetStatement(span:, ..) | ast.LetAssertStatement(span:, ..) ->
      span.start.line
  }
}

/// Evaluate child expressions from left to right into fresh bindings. Calls,
/// tuples and lists then reuse those values without replaying side effects.
///
/// ```text
/// f(next(), next()) -> bind first call; bind second call; invoke f
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn evaluate(
  values: List(ast.Expression),
  context: Context,
) -> Result(#(List(f.Term), List(f.Term), Context), Unsupported) {
  use #(bindings, values, context) <- result.try(
    list.try_fold(values, #([], [], context), fn(acc, value) {
      let line = ast.expression_span(value).start.line
      use #(value, context) <- result.try(expression(value, acc.2))
      let #(variable, context) = fresh(context, line)
      Ok(#(
        [f.node("match", line, [variable, value]), ..acc.0],
        [variable, ..acc.1],
        context,
      ))
    }),
  )
  Ok(#(list.reverse(bindings), list.reverse(values), context))
}

/// Dispatch a checked expression to its Erlang representation. Runtime helpers
/// are used only where one source feature needs more than an ordinary Erlang
/// expression.
///
/// ```text
/// Pooka 42 -> {integer,1,42}
/// Pooka #(1, 2) -> {tuple,1,[{integer,1,1},{integer,1,2}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn expression(
  value: ast.Expression,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let span = ast.expression_span(value)
  let line = span.start.line
  case value {
    // A whole number stays a whole number; the annotation remembers its source line.
    //
    // Schematic mapping; L is the source annotation and capitalized
    // names such as Value stand for already lowered abstract expressions.
    //
    // ```text
    // 42 -> {integer,L,42}
    // ```
    //
    // https://www.erlang.org/doc/apps/erts/absform.html#atomic-literals
    ast.IntLiteral(value, _) ->
      Ok(#(
        f.node("integer", line, [
          f.Integer(literal.parse_int(value) |> result.unwrap(0)),
        ]),
        context,
      ))
    ast.FloatLiteral(value, _) ->
      Ok(#(
        f.node("float", line, [
          f.Floating(literal.parse_float(value) |> result.unwrap(0.0)),
        ]),
        context,
      ))
    // Strings become UTF-8 binary segments rather than Erlang charlists.
    //
    // Schematic mapping; L is the source annotation and capitalized
    // names such as Value stand for already lowered abstract expressions.
    //
    // ```text
    // "oak" -> {bin,L,[{bin_element,L,{string,L,"oak"},default,[utf8]}]}
    // ```
    //
    // https://www.erlang.org/doc/apps/erts/absform.html#expressions
    ast.StringLiteral(value, _) ->
      Ok(#(
        binary_text(literal.decode_string(value) |> result.unwrap(value), line),
        context,
      ))
    ast.BoolLiteral(value, _) ->
      Ok(#(
        f.atom(
          case value {
            True -> "true"
            False -> "false"
          },
          line,
        ),
        context,
      ))
    // The Pooka value Nil is an atom. Keep it distinct from the empty list node.
    //
    // Schematic mapping; L is the source annotation and capitalized
    // names such as Value stand for already lowered abstract expressions.
    //
    // ```text
    // Nil -> {atom,L,nil}; [] -> {nil,L}
    // ```
    //
    // https://www.erlang.org/doc/apps/erts/absform.html#atomic-literals
    ast.NilLiteral(_) -> Ok(#(f.atom("nil", line), context))
    ast.Variable(name, _) | ast.TypeName(name, _) ->
      reference(name, span, context)
    ast.TupleExpression(values, _) | ast.ListExpression(values, _) -> {
      use #(bindings, values, context) <- result.try(evaluate(values, context))
      let value = case value {
        ast.TupleExpression(..) -> f.node("tuple", line, [f.Sequence(values)])
        _ -> list_term(values, f.node("nil", line, []), line)
      }
      Ok(#(sequence(bindings, value, line), context))
    }
    // A spread supplies the final cons tail; it is never appended by copying.
    // Evaluate the heads first, then the tail, each exactly once.
    //
    // ```text
    // [A, B, ..Rest] -> {cons,L,A,{cons,L,B,Rest}}
    // ```
    // https://www.erlang.org/doc/apps/erts/absform.html#expressions
    ast.ListSpread(values, tail, _) -> {
      use #(bindings, values, context) <- result.try(evaluate(
        list.append(values, [tail]),
        context,
      ))
      let assert [tail, ..reversed] = list.reverse(values)
      Ok(#(
        sequence(bindings, list_term(list.reverse(reversed), tail, line), line),
        context,
      ))
    }
    ast.BlockExpression(value) -> {
      let outer = context.locals
      use #(body, context) <- result.try(block(value, context))
      Ok(#(
        f.node("block", line, [f.Sequence(body)]),
        Context(..context, locals: outer),
      ))
    }
    // A closure is a fun node with its own clauses and propagation boundary.
    //
    // Schematic mapping; L is the source annotation and capitalized
    // names such as Value stand for already lowered abstract expressions.
    //
    // ```text
    // fn(x) { x } -> {'fun',L,{clauses,[{clause,L,[X],[],[X]}]}}
    // ```
    //
    // https://www.erlang.org/doc/apps/erts/absform.html#expressions
    ast.AnonymousFunction(args, _, source_body, _) -> {
      let outer_context = context
      let outer = context.locals
      let captured = case context.constructing {
        Some(value) -> Some(value)
        None -> context.receiver
      }
      let context = Context(..context, receiver: captured, constructing: None)
      let #(captures, context) = actor_captures(context, line)
      let #(args, context) = parameters(args, context)
      use #(body, context) <- result.try(block(source_body, context))
      let #(returned, context) = fresh(context, line)
      Ok(#(
        sequence(
          captures,
          anonymous(
            args,
            [return_boundary(body, line, returned, source_body)],
            line,
          ),
          line,
        ),
        Context(
          ..context,
          locals: outer,
          receiver: outer_context.receiver,
          constructing: outer_context.constructing,
        ),
      ))
    }
    ast.Call(
      ast.FieldAccess(ast.SuperExpression(_), ast.Name("new", _), _),
      arguments,
      _,
    ) -> super_constructor(arguments, span, context)
    ast.Call(ast.FieldAccess(ast.SuperExpression(_), name, _), arguments, _) ->
      super_method(name.name, arguments, span, context)
    // Bind child values once before assembling the call. F and Args below are lowered nodes.
    //
    // Schematic mapping; L is the source annotation and capitalized
    // names such as Value stand for already lowered abstract expressions.
    //
    // ```text
    // f(value) -> {call,L,F,[Value]}
    // ```
    //
    // https://www.erlang.org/doc/apps/erts/absform.html#expressions
    ast.Call(callee, arguments, _) -> {
      use #(bindings, values, context) <- result.try(evaluate(
        [callee, ..arguments],
        context,
      ))
      let assert [callee, ..arguments] = values
      Ok(#(
        sequence(
          bindings,
          f.node("call", line, [callee, f.Sequence(arguments)]),
          line,
        ),
        context,
      ))
    }
    // A tuple counts its pockets from zero in Pooka and from one in Erlang.
    // The checked index is constant; evaluate its receiver exactly once.
    //
    // ```text
    // pair.0 -> erlang:element(1, Pair)
    // {call,L,{remote,L,{atom,L,erlang},{atom,L,element}},
    //   [{integer,L,1}, Pair]}
    // ```
    // https://www.erlang.org/doc/apps/erts/absform.html#expressions
    ast.TupleAccess(subject:, index:, ..) -> {
      use #(value, context) <- result.try(expression(subject, context))
      Ok(#(
        f.remote(
          "erlang",
          "element",
          [f.node("integer", line, [f.Integer(index + 1)]), value],
          line,
        ),
        context,
      ))
    }
    ast.FieldAccess(subject, name, _) ->
      case enum_of(subject, context) {
        Ok(enum) ->
          Ok(#(
            f.atom(nominal.variant_atom(enum.source.name.name, name.name), line),
            context,
          ))
        Error(Nil) -> member_access(subject, name, span, context)
      }
    ast.SelfExpression(_) ->
      case
        context.class
        |> option.map(fn(identity) { unify.class(context.state, identity) }),
        context.receiver
      {
        Some(Ok(nominal.Class(actor: True, ..))), Some(receiver) ->
          Ok(#(receiver, context))
        _, _ ->
          case context.constructing {
            Some(receiver) -> Ok(#(receiver, context))
            None -> Error(Unsupported(span, "self outside a constructor"))
          }
      }
    ast.Assignment(ast.AssignVariable(name), operator, value, _) -> {
      use class <- result.try(
        case context.class {
          Some(identity) -> unify.class(context.state, identity)
          None -> Error(Nil)
        }
        |> result.map_error(fn(_) {
          Unsupported(span, "actor assignment scope")
        }),
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
      actor_write(class, name, value, span, context)
    }
    ast.Assignment(
      ast.AssignField(ast.SelfExpression(_), name, _),
      ast.Assign,
      value,
      _,
    ) -> initialize_field(name, value, span, context)
    // The pipe rewrites to an ordinary call; no pipe helper survives in the runtime.
    //
    // Schematic mapping; L is the source annotation and capitalized
    // names such as Value stand for already lowered abstract expressions.
    //
    // ```text
    // value |> f(extra) -> {call,L,F,[Value,Extra]}
    // ```
    //
    // https://www.erlang.org/doc/apps/erts/absform.html#expressions
    ast.Binary(ast.PipeOperator, left, right, _) ->
      expression(
        case right {
          ast.Call(callee, args, _) -> ast.Call(callee, [left, ..args], span)
          _ -> ast.Call(right, [left], span)
        },
        context,
      )
    ast.Binary(operator, left, right, _) ->
      binary_operator(operator, left, right, span, context)
    ast.Unary(operator, operand, _) -> {
      use #(operand, context) <- result.try(expression(operand, context))
      Ok(#(
        f.node("op", line, [
          f.Atom(case operator {
            ast.Negate -> "-"
            ast.Not -> "not"
          }),
          operand,
        ]),
        context,
      ))
    }
    ast.Match(subject, branches, _) -> {
      use #(bindings, values, context) <- result.try(evaluate(
        [subject],
        context,
      ))
      let assert [subject] = values
      use #(matched, context) <- result.try(lower_branches(
        branches,
        subject,
        line,
        context,
      ))
      case context.constructing {
        None -> Ok(#(sequence(bindings, matched, line), context))
        Some(_) -> {
          let #(pair, context) = fresh(context, line)
          let result = tuple_element(1, pair, line)
          let state = tuple_element(2, pair, line)
          Ok(#(
            sequence(
              list.append(bindings, [f.node("match", line, [pair, matched])]),
              result,
              line,
            ),
            Context(..context, constructing: Some(state)),
          ))
        }
      }
    }
    // A successful Result yields its value. An error travels to the private
    // return boundary generated for this callable, not an enclosing closure.
    //
    // ```text
    // read()? -> {call,L,{remote,L,{atom,L,pooka_runtime_ffi},
    //                              {atom,L,propagate}},[ReadResult]}
    // ```
    //
    // https://www.erlang.org/doc/apps/erts/absform.html#expressions
    ast.Propagate(operand, _) -> runtime("propagate", [operand], line, context)
    ast.Panic(message, _) | ast.Todo(message, _) ->
      runtime(
        "panic",
        [
          case message {
            Some(value) -> value
            None -> ast.StringLiteral("process terminated", span)
          },
        ],
        line,
        context,
      )
    ast.Assert(condition, message, _) -> {
      use #(bindings, condition, expected, found, context) <- result.try(
        case condition {
          ast.Binary(ast.Equal, left, right, _) -> {
            use #(bindings, values, context) <- result.try(evaluate(
              [left, right],
              context,
            ))
            let assert [found, expected] = values
            Ok(#(
              bindings,
              f.node("op", line, [f.Atom("=:="), found, expected]),
              expected,
              found,
              context,
            ))
          }
          _ -> {
            use #(condition, context) <- result.try(expression(
              condition,
              context,
            ))
            Ok(#(
              [],
              condition,
              f.atom("true", line),
              f.atom("false", line),
              context,
            ))
          }
        },
      )
      let success_state = context.constructing
      use #(message, context) <- result.try(expression(
        case message {
          Some(value) -> value
          None -> ast.StringLiteral("assertion failed", span)
        },
        context,
      ))

      let context = Context(..context, constructing: success_state)
      Ok(#(
        f.node("block", line, [
          f.Sequence(
            list.append(bindings, [
              f.node("case", line, [
                condition,
                f.Sequence([
                  f.clause([f.atom("true", line)], [f.atom("nil", line)], line),
                  f.clause(
                    [f.atom("false", line)],
                    [
                      f.remote(
                        "pooka_runtime_ffi",
                        "assert_equal",
                        [
                          expected,
                          found,
                          message,
                          binary_text(context.path, line),
                          f.node("integer", line, [f.Integer(line)]),
                        ],
                        line,
                      ),
                    ],
                    line,
                  ),
                ]),
              ]),
            ]),
          ),
        ]),
        context,
      ))
    }
    ast.Loop(Some(iteration), body, _) ->
      iteration_loop(iteration, body, span, context)
    ast.Loop(None, body, _) ->
      case context.constructing {
        None -> loop(body, line, context)
        Some(_) -> constructor_loop(body, line, context)
      }
    ast.Break(value, _) -> {
      let value = case value {
        Some(value) -> value
        None -> ast.NilLiteral(span)
      }
      use #(bindings, values, context) <- result.try(evaluate([value], context))
      let assert [value] = values
      let thrown = case context.constructing {
        None -> f.remote("pooka_runtime_ffi", "break", [value], line)
        Some(state) ->
          f.remote(
            "erlang",
            "throw",
            [
              f.node("tuple", line, [
                f.Sequence([
                  f.atom("pooka_constructor_break", line),
                  value,
                  state,
                ]),
              ]),
            ],
            line,
          )
      }
      Ok(#(sequence(bindings, thrown, line), context))
    }
    ast.Continue(_) -> {
      let thrown = case context.constructing {
        None -> f.remote("pooka_runtime_ffi", "continue", [], line)
        Some(state) ->
          f.remote(
            "erlang",
            "throw",
            [
              f.node("tuple", line, [
                f.Sequence([f.atom("pooka_constructor_continue", line), state]),
              ]),
            ],
            line,
          )
      }
      Ok(#(thrown, context))
    }
    ast.BitArrayExpression(segments, _) -> bit_array(segments, line, context)
    _ -> Error(Unsupported(span, "expression lowering"))
  }
}

/// Encode a Pooka string as a UTF-8 binary constructor, not as an Erlang
/// character list. The string node is the binary segment's value.
///
/// ```erlang
/// {bin,1,[{bin_element,1,{string,1,"oak"},default,[utf8]}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn binary_text(value: String, line: Int) -> f.Term {
  f.node("bin", line, [
    f.Sequence([
      f.node("bin_element", line, [
        f.node("string", line, [f.Characters(value)]),
        f.Atom("default"),
        f.Sequence([f.Atom("utf8")]),
      ]),
    ]),
  ])
}

/// Place prerequisite bindings before the final value. With no bindings the value
/// can walk straight through without an extra block.
///
/// ```erlang
/// {block,1,[{match,1,{var,1,'X'},{integer,1,1}},{var,1,'X'}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn sequence(bindings: List(f.Term), value: f.Term, line: Int) -> f.Term {
  case bindings {
    [] -> value
    _ -> f.node("block", line, [f.Sequence(list.append(bindings, [value]))])
  }
}

/// Fold elements into cons cells, ending at the supplied tail. A proper empty
/// list is a nil node; the Pooka value Nil is an atom instead.
///
/// ```erlang
/// {cons,1,{integer,1,1},{nil,1}}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn list_term(values: List(f.Term), tail: f.Term, line: Int) -> f.Term {
  list.fold(list.reverse(values), tail, fn(tail, head) {
    f.node("cons", line, [head, tail])
  })
}

/// Build a fun with one unguarded clause from already lowered parameters and body
/// expressions.
///
/// ```erlang
/// {'fun',1,{clauses,[{clause,1,[{var,1,'X'}],[],[{var,1,'X'}]}]}}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn anonymous(args: List(f.Term), body: List(f.Term), line: Int) -> f.Term {
  f.node("fun", line, [
    f.Tuple([f.Atom("clauses"), f.Sequence([f.clause(args, body, line)])]),
  ])
}

/// Publish foreign namespace functions as references available to expression
/// lowering. A reference stores how to call the foreign module, not its result.
///
/// ```text
/// external Math -> abs reference -> Erlang module/function/arity
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn namespace_references(
  namespace: module_infer.Namespace,
) -> Dict(String, Reference) {
  list.fold(namespace.functions, dict.new(), fn(found, function) {
    case function.type_ {
      monotype.FunctionType(parameters, _) ->
        dict.insert(
          found,
          function.name.name,
          Remote(
            foreign_language.beam_module(namespace.language, namespace.module),
            function.name.name,
            list.length(parameters),
          ),
        )
      _ -> found
    }
  })
}

/// Record one foreign function under its namespace name. Call arity comes from
/// the checked signature.
///
/// ```text
/// Math.abs -> a remote callable with arity 1
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn namespace_function(
  namespace: String,
  name: ast.Name,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  use reference <- result.try(
    dict.get(context.modules, namespace)
    |> result.try(dict.get(_, name.name))
    |> result.map_error(fn(_) { Unsupported(span, "unknown external function") }),
  )
  Ok(#(function_reference(reference, span.start.line), context))
}

/// Turn a callable reference into a local or remote fun expression. A value
/// referring to a function must not invoke it prematurely.
///
/// ```erlang
/// {'fun',1,{function,{atom,1,erlang},{atom,1,abs},{integer,1,1}}}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn function_reference(value: Reference, line: Int) -> f.Term {
  case value {
    Local(name, arity) -> f.local_fun(name, arity, line)
    Remote(module, name, arity) ->
      f.node("fun", line, [
        f.Tuple([
          f.Atom("function"),
          f.atom(module, line),
          f.atom(name, line),
          f.node("integer", line, [f.Integer(arity)]),
        ]),
      ])
  }
}

/// Resolve a source name against local bindings and outer callable references.
/// Locals keep the Erlang variable assigned at their binding site.
///
/// ```erlang
/// {var,1,'Pooka0'}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn reference(
  name: String,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let class_member = case context.class {
    None -> False
    Some(identity) ->
      case unify.class(context.state, identity) {
        Error(Nil) -> False
        Ok(class) ->
          list.any(class.fields, fn(field) { field.name.name == name })
          || list.any(class.methods, fn(method) { method.name.name == name })
      }
  }
  case class_member && !dict.has_key(context.locals, name) {
    True -> implicit_member(name, span, context)
    False -> reference_outer(name, span, context)
  }
}

/// Resolve names not bound locally, including builtins and declaration
/// references. Builtins can be passed as callable values as well as called
/// directly.
///
/// ```text
/// let inspect = echo -> a callable reference to the runtime helper
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn reference_outer(
  name: String,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  case dict.get(context.locals, name) {
    Ok(value) -> Ok(#(value, context))
    Error(Nil) ->
      case dict.get(context.functions, name) {
        Ok(Remote("pooka_runtime_ffi", "echo", 1)) -> {
          let #(value, context) = fresh(context, line)
          Ok(#(
            anonymous(
              [value],
              [
                f.remote(
                  "pooka_runtime_ffi",
                  "echo",
                  [
                    value,
                    binary_text(context.path, line),
                    f.node("integer", line, [f.Integer(line)]),
                  ],
                  line,
                ),
              ],
              line,
            ),
            context,
          ))
        }
        Ok(value) -> Ok(#(function_reference(value, line), context))
        Error(Nil) ->
          case name {
            "None" -> Ok(#(f.atom("none", line), context))
            "Some" | "Ok" | "Error" -> {
              let #(variable, context) = fresh(context, line)
              let tag = case name {
                "Some" -> "some"
                "Ok" -> "ok"
                _ -> "error"
              }
              Ok(#(
                anonymous(
                  [variable],
                  [
                    f.node("tuple", line, [
                      f.Sequence([f.atom(tag, line), variable]),
                    ]),
                  ],
                  line,
                ),
                context,
              ))
            }
            _ -> Error(Unsupported(span, "unresolved value `" <> name <> "`"))
          }
      }
  }
}

/// Choose the appropriate short-circuit or ordinary operator lowering. Evaluation
/// strategy is part of the operator's meaning, not a formatting preference.
///
/// ```text
/// False && expensive() -> skip expensive()
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn binary_operator(
  operator: ast.BinaryOperator,
  left: ast.Expression,
  right: ast.Expression,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let boolean = operator == ast.And || operator == ast.Or
  case boolean, context.constructing {
    True, Some(_) ->
      expression(
        ast.Match(
          left,
          [
            ast.Branch(
              ast.BoolPattern(True, span),
              None,
              case operator {
                ast.And -> right
                _ -> ast.BoolLiteral(True, span)
              },
              span,
            ),
            ast.Branch(
              ast.BoolPattern(False, span),
              None,
              case operator {
                ast.And -> ast.BoolLiteral(False, span)
                _ -> right
              },
              span,
            ),
          ],
          span,
        ),
        context,
      )
    _, _ -> binary_operator_inner(operator, left, right, span, context)
  }
}

/// Emit the checked primitive operation. Int division uses div; division with a
/// Float uses /. String addition constructs a binary instead of applying numeric
/// addition.
///
/// ```erlang
/// {op,1,'div',{integer,1,5},{integer,1,2}}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn binary_operator_inner(
  operator: ast.BinaryOperator,
  left: ast.Expression,
  right: ast.Expression,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  case operator {
    ast.And | ast.Or -> {
      use #(left, context) <- result.try(expression(left, context))
      use #(right, context) <- result.try(expression(right, context))
      Ok(#(
        f.node("op", line, [
          f.Atom(case operator {
            ast.And -> "andalso"
            _ -> "orelse"
          }),
          left,
          right,
        ]),
        context,
      ))
    }
    _ -> {
      let operand =
        unify.expression_type(
          context.state,
          context.path,
          ast.expression_span(left),
        )
      use #(bindings, values, context) <- result.try(evaluate(
        [left, right],
        context,
      ))
      let assert [left, right] = values
      let value = case operator, operand {
        ast.Add, Ok(monotype.StringType) ->
          f.node("bin", line, [
            f.Sequence([
              f.node("bin_element", line, [
                left,
                f.Atom("default"),
                f.Sequence([f.Atom("binary")]),
              ]),
              f.node("bin_element", line, [
                right,
                f.Atom("default"),
                f.Sequence([f.Atom("binary")]),
              ]),
            ]),
          ])
        ast.Remainder, _ ->
          f.remote("pooka_runtime_ffi", "remainder", [left, right], line)
        // Division always produces a Float, as in Python 3: `7 / 2` is
        // `3.5` and `4 / 2` is `2.0`. Erlang's `/` has the same rule, so
        // Int, Float and mixed operands share one operation. Integer
        // division belongs to `int.divide`.
        ast.Divide, _ -> f.node("op", line, [f.Atom("/"), left, right])
        _, _ ->
          f.node("op", line, [
            f.Atom(case operator {
              ast.Add -> "+"
              ast.Subtract -> "-"
              ast.Multiply -> "*"
              ast.Divide -> "/"
              ast.Equal -> "=:="
              ast.NotEqual -> "=/="
              ast.Less -> "<"
              ast.LessOrEqual -> "=<"
              ast.Greater -> ">"
              ast.GreaterOrEqual -> ">="
              ast.BitAnd -> "band"
              ast.BitOr -> "bor"
              _ -> "+"
            }),
            left,
            right,
          ])
      }
      case operand {
        Error(Nil) ->
          Error(Unsupported(span, "missing expression type metadata"))
        Ok(_) -> Ok(#(sequence(bindings, value, line), context))
      }
    }
  }
}

/// Call a helper in pooka_runtime_ffi while retaining the expression's source
/// line. Arguments are abstract expressions, not raw runtime values.
///
/// ```text
/// runtime helper call -> {call,Line,{remote,Line,...},Arguments}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn runtime(
  name: String,
  args: List(ast.Expression),
  line: Int,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  use #(bindings, args, context) <- result.try(evaluate(args, context))
  Ok(#(
    sequence(bindings, f.remote("pooka_runtime_ffi", name, args, line), line),
    context,
  ))
}

/// Catch only this callable's tagged Result propagation. Nested closures
/// establish their own boundary, so an error cannot return from the wrong
/// function.
///
/// ```text
/// read()? -> runtime propagation; throw({pooka_return, Error}) is caught here
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn return_boundary(
  body: List(f.Term),
  line: Int,
  value: f.Term,
  source: ast.Block,
) -> f.Term {
  case propagation.block(source) {
    False -> f.node("block", line, [f.Sequence(body)])
    True ->
      f.node("try", line, [
        f.Sequence(body),
        f.Sequence([]),
        f.Sequence([
          catch_clause(
            f.node("tuple", line, [
              f.Sequence([f.atom("pooka_return", line), value]),
            ]),
            [value],
            line,
          ),
        ]),
        f.Sequence([]),
      ])
  }
}

/// Build a catch clause matching throw, the private reason pattern and a
/// discarded stacktrace. Do not catch every exception raised by user code.
///
/// ```text
/// {clause,Line,[{tuple,Line,[throw-pattern,reason-pattern,stack-pattern]}],[],Body}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#clauses.
fn catch_clause(reason: f.Term, body: List(f.Term), line: Int) -> f.Term {
  f.clause(
    [
      f.node("tuple", line, [
        f.Sequence([f.atom("throw", line), reason, f.variable("_", line)]),
      ]),
    ],
    body,
    line,
  )
}

/// Translate source match branches through the appropriate pattern path. Guard
/// and binary-pattern handling must preserve the original branch order.
///
/// ```text
/// match value { Some(x) -> x; None -> 0 } -> ordered case clauses
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#clauses.
fn lower_branches(
  values: List(ast.Branch),
  subject: f.Term,
  line: Int,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  case context.constructing {
    Some(_) -> constructor_branches(values, subject, line, context)
    None -> ordinary_branches(values, subject, line, context)
  }
}

/// Build ordinary case clauses with lowered patterns, guards and bodies. A guard
/// list is a list of alternative guard sequences.
///
/// ```text
/// {clause,Line,[Pattern],GuardSequences,Body}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#clauses.
fn ordinary_branches(
  values: List(ast.Branch),
  subject: f.Term,
  line: Int,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  case values {
    [] ->
      Ok(#(
        f.remote("erlang", "error", [f.atom("pooka_match_failure", line)], line),
        context,
      ))
    [branch, ..rest] -> {
      let outer = context.locals
      use #(branch_subject, pattern, context) <- result.try(
        lower_branch_pattern(branch.pattern, subject, context),
      )
      use #(body, context) <- result.try(expression(branch.body, context))
      use #(guard, context) <- result.try(case branch.guard {
        None -> Ok(#(None, context))
        Some(guard) ->
          expression(guard, context)
          |> result.map(fn(pair) { #(Some(pair.0), pair.1) })
      })
      use #(fallback, context) <- result.try(lower_branches(
        rest,
        subject,
        line,
        Context(..context, locals: outer),
      ))

      let #(next, context) = fresh(context, line)
      let continuation =
        f.node("match", line, [next, anonymous([], [fallback], line)])
      let fallback = f.node("call", line, [next, f.Sequence([])])
      let body = case guard {
        None -> body
        Some(guard) ->
          f.node("case", line, [
            guard,
            f.Sequence([
              f.clause([f.atom("true", line)], [body], line),
              f.clause([f.atom("false", line)], [fallback], line),
            ]),
          ])
      }
      Ok(#(
        sequence(
          [continuation],
          f.node("case", line, [
            branch_subject,
            f.Sequence([
              f.clause([pattern], [body], line),
              f.clause([f.variable("_", line)], [fallback], line),
            ]),
          ]),
          line,
        ),
        context,
      ))
    }
  }
}

/// Lower a source pattern and extend the local bindings it introduces.
/// Constructor patterns use checked class layouts; binary patterns use their
/// segment rules.
///
/// ```erlang
/// {tuple,1,[{atom,1,some},{var,1,'X'}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn lower_pattern(
  value: ast.Pattern,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let span = ast.pattern_span(value)
  let line = span.start.line
  case value {
    ast.AlternativePattern(..) ->
      Error(Unsupported(span, "alternatives outside a match arm"))
    ast.VariablePattern(name, _) -> {
      let #(variable, context) = fresh(context, line)
      Ok(#(
        variable,
        Context(..context, locals: dict.insert(context.locals, name, variable)),
      ))
    }
    ast.DiscardPattern(_) -> Ok(#(f.variable("_", line), context))
    ast.IntPattern(value, _) -> expression(ast.IntLiteral(value, span), context)
    ast.FloatPattern(value, _) ->
      expression(ast.FloatLiteral(value, span), context)
    ast.StringPattern(value, _) ->
      expression(ast.StringLiteral(value, span), context)
    ast.BoolPattern(value, _) ->
      expression(ast.BoolLiteral(value, span), context)
    ast.NilPattern(_) -> Ok(#(f.atom("nil", line), context))
    ast.EnumPattern(qualifier, enum_name, variant, _) -> {
      use enum <- result.try(
        unify.named_enum(
          context.state,
          context.path,
          option.unwrap(qualifier, ""),
          enum_name,
        )
        |> result.map_error(fn(_) { Unsupported(span, "unknown enum pattern") }),
      )
      Ok(#(
        f.atom(nominal.variant_atom(enum.source.name.name, variant.name), line),
        context,
      ))
    }
    ast.ConstructorPattern(qualifier, name, elements, _)
      if name != "Some" && name != "None" && name != "Ok" && name != "Error"
    -> {
      use class <- result.try(
        unify.named_class(
          context.state,
          context.path,
          case qualifier {
            Some(value) -> value
            None -> ""
          },
          name,
        )
        |> result.map_error(fn(_) {
          Unsupported(span, "unknown nominal pattern")
        }),
      )
      use #(elements, context) <- result.try(patterns(elements, context))

      Ok(#(class_layout.pattern(context.state, class, elements, line), context))
    }
    ast.TuplePattern(elements, _)
    | ast.ConstructorPattern(None, _, elements, _) -> {
      use #(elements, context) <- result.try(patterns(elements, context))
      let elements = case value {
        ast.ConstructorPattern(_, name, _, _) -> [
          f.atom(
            case name {
              "Some" -> "some"
              "None" -> "none"
              "Ok" -> "ok"
              _ -> "error"
            },
            line,
          ),
          ..elements
        ]
        _ -> elements
      }
      let value = case value {
        ast.ConstructorPattern(_, "None", _, _) -> f.atom("none", line)
        _ -> f.node("tuple", line, [f.Sequence(elements)])
      }
      Ok(#(value, context))
    }
    ast.ListPattern(elements, tail, _) -> {
      use #(elements, context) <- result.try(patterns(elements, context))
      let #(tail, context) = case tail {
        None -> #(f.node("nil", line, []), context)
        Some(ast.IgnoredTail(_)) -> #(f.variable("_", line), context)
        Some(ast.BoundTail(name, _)) -> {
          let #(tail, context) = fresh(context, line)
          #(
            tail,
            Context(..context, locals: dict.insert(context.locals, name, tail)),
          )
        }
      }
      Ok(#(list_term(elements, tail, line), context))
    }
    ast.BitArrayPattern(segments, _) ->
      bit_lower_pattern(segments, line, context)
    _ -> Error(Unsupported(span, "nominal pattern lowering"))
  }
}

/// Lower several patterns while threading their shared binding context. Later
/// patterns must see bindings established according to the language's pattern
/// rules.
///
/// ```text
/// #(first, second) -> tuple pattern with two bound variables
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn patterns(
  values: List(ast.Pattern),
  context: Context,
) -> Result(#(List(f.Term), Context), Unsupported) {
  use #(values, context) <- result.try(
    list.try_fold(values, #([], context), fn(acc, value) {
      use #(value, context) <- result.try(lower_pattern(value, acc.1))
      Ok(#([value, ..acc.0], context))
    }),
  )
  Ok(#(list.reverse(values), context))
}

/// Dispatch loop lowering while preserving the loop's break/continue boundary.
/// Iterator loops and unbounded loops have different state to carry.
///
/// ```text
/// loop { break 42 } -> recursive control structure with a break boundary
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn loop(
  body: ast.Block,
  line: Int,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let outer = context.locals
  let name = "Loop" <> int.to_string(context.next)
  let context = Context(..context, next: context.next + 1)
  use #(body, context) <- result.try(block(body, context))
  let again = f.node("call", line, [f.variable(name, line), f.Sequence([])])
  let #(value, context) = fresh(context, line)
  let continued = f.atom("pooka_loop_continue", line)
  let caught =
    f.node("try", line, [
      f.Sequence(list.append(body, [continued])),
      f.Sequence([]),
      f.Sequence([
        catch_clause(
          f.node("tuple", line, [
            f.Sequence([f.atom("pooka_break", line), value]),
          ]),
          [
            f.node("tuple", line, [
              f.Sequence([f.atom("pooka_loop_done", line), value]),
            ]),
          ],
          line,
        ),
        catch_clause(f.atom("pooka_continue", line), [continued], line),
      ]),
      f.Sequence([]),
    ])
  let #(result_value, context) = fresh(context, line)

  let caught =
    f.node("case", line, [
      caught,
      f.Sequence([
        f.clause([continued], [again], line),
        f.clause(
          [
            f.node("tuple", line, [
              f.Sequence([f.atom("pooka_loop_done", line), result_value]),
            ]),
          ],
          [result_value],
          line,
        ),
      ]),
    ])
  let fun_ =
    f.node("named_fun", line, [
      f.Atom(name),
      f.Sequence([f.clause([], [caught], line)]),
    ])
  Ok(#(
    f.node("call", line, [fun_, f.Sequence([])]),
    Context(..context, locals: outer),
  ))
}

/// Translate checked bit-segment options into Erlang size, unit and type-
/// specifier terms. Keep default size distinct from an explicit integer
/// expression.
///
/// ```text
/// value:size(8) -> bin_element with {integer,Line,8} size
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn segment_options(
  options: List(ast.BitArrayOption),
  context: Context,
) -> Result(#(f.Term, f.Term, List(f.Term), Context), Unsupported) {
  use #(size, types, bindings, context) <- result.try(
    list.try_fold(
      options,
      #(f.Atom("default"), [], [], context),
      fn(acc, option) {
        case option {
          ast.SizeOption(value, _) -> {
            use #(bindings, values, context) <- result.try(evaluate(
              [value],
              acc.3,
            ))
            let assert [size] = values
            Ok(#(size, acc.1, list.append(acc.2, bindings), context))
          }
          ast.UnitOption(value, span) -> {
            use unit <- result.try(
              compiler_constant(value)
              |> result.map_error(fn(_) {
                Unsupported(
                  span,
                  "a bit-array unit must be a compile-time integer",
                )
              }),
            )
            Ok(#(
              acc.0,
              [f.Tuple([f.Atom("unit"), f.Integer(unit)]), ..acc.1],
              acc.2,
              acc.3,
            ))
          }
          ast.NamedOption(name, _) ->
            Ok(#(
              acc.0,
              [f.Atom(segment_representation(name, options)), ..acc.1],
              acc.2,
              acc.3,
            ))
        }
      },
    ),
  )
  Ok(#(
    size,
    case types {
      [] -> f.Atom("default")
      _ -> f.Sequence(list.reverse(types))
    },
    bindings,
    context,
  ))
}

/// Read an integer constant expression without running user code. Unsupported
/// expressions keep their nonconstant status.
///
/// ```text
/// constant size expression -> Ok(bits), otherwise Error(Nil)
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn compiler_constant(value: ast.Expression) -> Result(Int, Nil) {
  constant.integer(value)
}

/// Build a binary constructor from normalized segment representations. Prefix
/// bindings preserve evaluation order before the bin node is assembled.
///
/// ```erlang
/// {bin,1,[{bin_element,1,{integer,1,65},default,default}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn bit_array(
  segments: List(ast.BitArraySegment(ast.Expression)),
  line: Int,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  use #(elements, bindings, context) <- result.try(
    list.try_fold(segments, #([], [], context), fn(acc, segment) {
      use #(bindings, values, context) <- result.try(evaluate(
        [segment.value],
        acc.2,
      ))
      let assert [value] = values
      use #(size, types, size_bindings, context) <- result.try(segment_options(
        segment.options,
        context,
      ))
      let encoding =
        list.find_map(segment.options, fn(option) {
          case option {
            ast.NamedOption(name, _)
              if name == "utf8" || name == "utf16" || name == "utf32"
            -> Ok(name)
            _ -> Error(Nil)
          }
        })
      let #(value, types, encoding_bindings, context) = case encoding {
        Error(Nil) -> #(value, types, [], context)
        Ok(encoding) -> {
          let endian =
            list.find_map(segment.options, fn(option) {
              case option {
                ast.NamedOption(name, _)
                  if name == "big" || name == "little" || name == "native"
                -> Ok(name)
                _ -> Error(Nil)
              }
            })
            |> result.unwrap("big")
          let #(encoded, context) = fresh(context, segment.span.start.line)
          #(
            encoded,
            f.Sequence([f.Atom("binary")]),
            [
              f.node("match", line, [
                encoded,
                f.remote(
                  "pooka_runtime_ffi",
                  "encode",
                  [value, f.atom(encoding, line), f.atom(endian, line)],
                  line,
                ),
              ]),
            ],
            context,
          )
        }
      }
      Ok(#(
        [
          f.node("bin_element", segment.span.start.line, [value, size, types]),
          ..acc.0
        ],
        list.flatten([acc.1, bindings, size_bindings, encoding_bindings]),
        context,
      ))
    }),
  )
  Ok(#(
    sequence(
      bindings,
      f.node("bin", line, [f.Sequence(list.reverse(elements))]),
      line,
    ),
    context,
  ))
}

/// Lower a binary pattern while recording the variables its segments bind.
/// Segment sizes remain expressions with their own source annotations.
///
/// ```erlang
/// {bin,1,[{bin_element,1,{var,1,'Byte'},default,default}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn bit_lower_pattern(
  segments: List(ast.BitArraySegment(ast.Pattern)),
  line: Int,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  use #(elements, context) <- result.try(
    list.try_fold(segments, #([], context), fn(acc, segment) {
      use #(size, types, context) <- result.try(pattern_options(
        segment.options,
        acc.1,
      ))
      use #(value, context) <- result.try(lower_pattern(segment.value, context))
      let value = case segment.value {
        ast.StringPattern(text, _) ->
          f.node("string", line, [
            f.Characters(literal.decode_string(text) |> result.unwrap(text)),
          ])
        _ -> value
      }
      Ok(#(
        [
          f.node("bin_element", segment.span.start.line, [value, size, types]),
          ..acc.0
        ],
        context,
      ))
    }),
  )
  Ok(#(f.node("bin", line, [f.Sequence(list.reverse(elements))]), context))
}

/// Construct the segment type-specifier list used by a binary pattern.
/// Signedness, endian and unit options must agree with the checker.
///
/// ```text
/// <<n:int-signed-little>> -> bin_element type specifiers
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn pattern_options(
  options: List(ast.BitArrayOption),
  context: Context,
) -> Result(#(f.Term, f.Term, Context), Unsupported) {
  use #(size, types) <- result.try(
    list.try_fold(options, #(f.Atom("default"), []), fn(acc, option) {
      case option {
        ast.SizeOption(value, _) ->
          pattern_size(value, context)
          |> result.map(fn(size) { #(size, acc.1) })
        ast.UnitOption(value, span) ->
          compiler_constant(value)
          |> result.map(fn(unit) {
            #(acc.0, [f.Tuple([f.Atom("unit"), f.Integer(unit)]), ..acc.1])
          })
          |> result.map_error(fn(_) {
            Unsupported(span, "dynamic pattern unit")
          })
        ast.NamedOption(name, _) ->
          Ok(#(acc.0, [f.Atom(segment_representation(name, options)), ..acc.1]))
      }
    }),
  )
  Ok(#(
    size,
    case types {
      [] -> f.Atom("default")
      _ -> f.Sequence(list.reverse(types))
    },
    context,
  ))
}

/// Lower the size expression for a binary pattern using the available pattern
/// environment. An omitted size keeps Erlang's default marker.
///
/// ```text
/// <<head:size(width), tail:bits>> -> width expression + default tail size
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn pattern_size(
  value: ast.Expression,
  context: Context,
) -> Result(f.Term, Unsupported) {
  let span = ast.expression_span(value)
  let line = span.start.line
  case value {
    ast.IntLiteral(text, _) ->
      Ok(
        f.node("integer", line, [
          f.Integer(literal.parse_int(text) |> result.unwrap(0)),
        ]),
      )
    ast.Variable(name, _) ->
      dict.get(context.locals, name)
      |> result.map_error(fn(_) {
        Unsupported(span, "unbound binary pattern size")
      })
    ast.Unary(ast.Negate, value, _) ->
      pattern_size(value, context)
      |> result.map(fn(value) { f.node("op", line, [f.Atom("-"), value]) })
    ast.Binary(operator, left, right, _) -> {
      use left <- result.try(pattern_size(left, context))
      use right <- result.try(pattern_size(right, context))
      case operator {
        ast.Add
        | ast.Subtract
        | ast.Multiply
        | ast.Remainder
        | ast.BitAnd
        | ast.BitOr ->
          Ok(
            f.node("op", line, [
              f.Atom(case operator {
                ast.Add -> "+"
                ast.Subtract -> "-"
                ast.Multiply -> "*"
                ast.BitAnd -> "band"
                ast.BitOr -> "bor"
                _ -> "rem"
              }),
              left,
              right,
            ]),
          )
        _ -> Error(Unsupported(span, "non-integer pattern size operator"))
      }
    }
    _ -> Error(Unsupported(span, "binary pattern sizes must be guard-safe"))
  }
}

/// Read one tuple position with Erlang's one-based element operation. Source
/// field indexes have already been mapped by class_layout.
///
/// ```text
/// field slot 2 -> erlang:element(2, Object)
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn tuple_element(index: Int, tuple: f.Term, line: Int) -> f.Term {
  f.remote(
    "erlang",
    "element",
    [f.node("integer", line, [f.Integer(index)]), tuple],
    line,
  )
}

/// Resolve a class name into the generated constructor callable. The class's
/// runtime representation is supplied by its checked metadata.
///
/// ```text
/// Box -> generated constructor reference for Box
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn class_reference(
  value: ast.Expression,
  context: Context,
) -> Result(nominal.Class, Nil) {
  case value {
    ast.TypeName(name, _) ->
      unify.named_class(context.state, context.path, "", name)
    ast.FieldAccess(ast.Variable(alias, _), name, _) ->
      case dict.has_key(context.locals, alias) {
        True -> Error(Nil)
        False ->
          unify.named_class(context.state, context.path, alias, name.name)
      }
    _ -> Error(Nil)
  }
}

/// Choose the generated constructor function and its arity. An inherited family
/// without a permitted constructor is not made constructible by codegen.
///
/// ```text
/// Box(42) -> call the checked Box constructor
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn constructor_reference(
  class: nominal.Class,
  line: Int,
  context: Context,
) -> f.Term {
  let arity = case unify.apply(class.constructor, context.state) {
    monotype.FunctionType(args, _) -> list.length(args)
    _ -> 0
  }
  function_reference(
    case class.path == context.path {
      True -> Local(nominal.function_name(class.source.name.name, "new"), arity)
      False ->
        Remote(
          module_name(context.namespace, class.module),
          nominal.function_name(class.source.name.name, "new"),
          arity,
        )
    },
    line,
  )
}

/// Lower field, bound-method or namespace access according to the checked
/// receiver. Evaluate the receiver once before constructing a bound callable.
///
/// ```text
/// let get = object.read -> fun() captures the evaluated object
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn member_access(
  subject: ast.Expression,
  name: ast.Name,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let class = case name.name {
    "new" -> class_reference(subject, context)
    _ -> Error(Nil)
  }
  case class {
    Ok(class) ->
      Ok(#(constructor_reference(class, span.start.line, context), context))
    Error(Nil) ->
      case subject {
        ast.TypeName(namespace, _) ->
          namespace_function(namespace, name, span, context)
        ast.FieldAccess(ast.Variable(alias, _), namespace, _) ->
          case
            !dict.has_key(context.locals, alias)
            && dict.has_key(context.modules, alias <> "." <> namespace.name)
          {
            True ->
              namespace_function(
                alias <> "." <> namespace.name,
                name,
                span,
                context,
              )
            False -> object_access(subject, name, span, context)
          }
        ast.Variable(alias, _) -> {
          let member = case context.class {
            None -> False
            Some(identity) ->
              case unify.class(context.state, identity) {
                Error(Nil) -> False
                Ok(class) ->
                  list.any(class.fields, fn(field) { field.name.name == alias })
                  || list.any(class.methods, fn(method) {
                    method.name.name == alias
                  })
              }
          }
          case
            !member && !dict.has_key(context.locals, alias),
            dict.get(context.modules, alias)
          {
            True, Ok(exports) -> {
              use reference <- result.try(
                dict.get(exports, name.name)
                |> result.map_error(fn(_) {
                  Unsupported(span, "unknown imported member")
                }),
              )
              Ok(#(function_reference(reference, span.start.line), context))
            }
            _, _ -> object_access(subject, name, span, context)
          }
        }
        _ -> object_access(subject, name, span, context)
      }
  }
}

/// Select a class member from its typed receiver. Field access follows the shared
/// tuple layout; methods use the generated dispatch convention.
///
/// ```text
/// object.value -> element path; object.read -> bound fun
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn object_access(
  subject: ast.Expression,
  name: ast.Name,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  use type_ <- result.try(
    unify.expression_type(
      context.state,
      context.path,
      ast.expression_span(subject),
    )
    |> result.map_error(fn(_) { Unsupported(span, "missing receiver type") }),
  )
  use <- bool.lazy_guard(
    case type_ {
      monotype.Nominal(_, _, monotype.InterfaceKind, _) -> True
      _ -> False
    },
    fn() { interface_access(subject, name, span, type_, context) },
  )
  use class <- result.try(
    case type_ {
      monotype.Nominal(module, name, _, _) ->
        unify.class(context.state, #(module, name))
      _ -> Error(Nil)
    }
    |> result.map_error(fn(_) { Unsupported(span, "non-class receiver") }),
  )
  use #(bindings, values, context) <- result.try(evaluate([subject], context))
  let assert [receiver] = values
  use #(value, context) <- result.try(member_value(
    class,
    receiver,
    name.name,
    span,
    context,
  ))
  Ok(#(sequence(bindings, value, line), context))
}

/// Build the value exposed by a checked member, retaining receiver identity for
/// methods and actors.
///
/// ```text
/// bound method -> fun(Args) -> dispatch(Receiver, Args) end
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn member_value(
  class: nominal.Class,
  receiver: f.Term,
  name: String,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  use <- bool.lazy_guard(class.actor, fn() {
    actor_member(class, receiver, name, span, context)
  })
  case list.find(class.fields, fn(field) { field.name.name == name }) {
    Ok(field) ->
      Ok(#(class_layout.read(context.state, field, receiver, line), context))
    Error(Nil) -> {
      use method <- result.try(
        list.find(class.methods, fn(method) { method.name.name == name })
        |> result.map_error(fn(_) { Unsupported(span, "unknown method") }),
      )
      let arity = case unify.apply(method.type_, context.state) {
        monotype.FunctionType(args, _) -> list.length(args)
        _ -> 0
      }
      let #(args, context) =
        list.fold(list.repeat(Nil, arity), #([], context), fn(acc, _) {
          let #(arg, context) = fresh(acc.1, line)
          #([arg, ..acc.0], context)
        })
      let args = list.reverse(args)
      let implementation = nominal.function_name(class.source.name.name, name)
      let call = case class.path == context.path {
        True ->
          f.node("call", line, [
            f.atom(implementation, line),
            f.Sequence([receiver, ..args]),
          ])
        False ->
          f.remote(
            module_name(context.namespace, class.module),
            implementation,
            [receiver, ..args],
            line,
          )
      }
      Ok(#(anonymous(args, [call], line), context))
    }
  }
}

/// Resolve an unqualified member through the current receiver. A local lexical
/// binding still has its normal shadowing priority.
///
/// ```text
/// inside a method, value -> self's value field
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn implicit_member(
  name: String,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  use identity <- result.try(case context.class {
    Some(identity) -> Ok(identity)
    None -> Error(Unsupported(span, "no class scope"))
  })
  use class <- result.try(
    unify.class(context.state, identity)
    |> result.map_error(fn(_) { Unsupported(span, "unknown class scope") }),
  )
  use receiver <- result.try(case context.constructing, context.receiver {
    Some(receiver), _ | _, Some(receiver) -> Ok(receiver)
    _, _ -> Error(Unsupported(span, "missing implicit receiver"))
  })
  member_value(class, receiver, name, span, context)
}

/// Update the constructor's current object value with one initialized field. The
/// tuple update returns another value; it does not mutate an existing object.
///
/// ```text
/// self.value = 42 -> erlang:setelement(Slot, Current, 42)
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn initialize_field(
  name: ast.Name,
  value: ast.Expression,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  use identity <- result.try(case context.class {
    Some(value) -> Ok(value)
    None -> Error(Unsupported(span, "constructor class scope"))
  })
  use class <- result.try(
    unify.class(context.state, identity)
    |> result.map_error(fn(_) { Unsupported(span, "constructor class") }),
  )
  use <- bool.lazy_guard(class.actor, fn() {
    actor_write(class, name, value, span, context)
  })
  use field <- result.try(
    list.find(class.fields, fn(field) { field.name.name == name.name })
    |> result.map_error(fn(_) { Unsupported(span, "constructor field") }),
  )
  let line = span.start.line
  use #(bindings, values, context) <- result.try(evaluate([value], context))
  let assert [value] = values
  use previous <- result.try(case context.constructing {
    Some(value) -> Ok(value)
    None -> Error(Unsupported(span, "field assignment outside construction"))
  })
  let #(state, context) = fresh(context, line)
  let initialized =
    f.node("match", line, [
      state,
      class_layout.write(context.state, field, previous, value, line),
    ])
  Ok(#(
    sequence(list.append(bindings, [initialized]), f.atom("nil", line), line),
    Context(..context, constructing: Some(state)),
  ))
}

/// Emit constructors, method bodies and dispatchers for a checked immutable
/// class. All readers and writers use class_layout's tuple contract.
///
/// ```text
/// class Box(value: Int) -> tagged tuple constructor + callable forms
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn class_forms(
  source: ast.Class,
  outer: Context,
) -> Result(#(List(f.Term), Context), Unsupported) {
  use class <- result.try(
    unify.named_class(outer.state, outer.path, "", source.name.name)
    |> result.map_error(fn(_) { Unsupported(source.span, "class metadata") }),
  )
  let hierarchy = unify.in_hierarchy(outer.state, class)
  let constructor =
    list.find_map(source.members, fn(member) {
      case member {
        ast.ConstructorMember(value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
    |> result.unwrap(ast.Constructor(
      [],
      [],
      ast.Block([], source.span),
      source.span,
    ))
  let line = constructor.span.start.line
  let context =
    Context(
      ..outer,
      locals: dict.new(),
      class: Some(nominal.identity(class)),
      receiver: None,
      constructing: None,
    )
  let #(constructor_patterns, parameters_context) =
    parameters(constructor.parameters, context)
  let #(initial, context) =
    fresh(Context(..parameters_context, locals: dict.new()), line)

  let first = case hierarchy {
    False -> [
      f.node("match", line, [
        initial,
        class_layout.skeleton(outer.state, class, line),
      ]),
    ]
    True -> []
  }
  let context = Context(..context, constructing: Some(initial))

  use #(implicit_parent, context) <- result.try(
    case
      class.superclass,
      constructor_analysis.has_super_call(constructor.body)
    {
      Some(parent), False -> {
        use parent <- result.try(
          unify.class(context.state, parent.identity)
          |> result.map_error(fn(_) {
            Unsupported(source.span, "superclass metadata")
          }),
        )
        let #(state, context) = fresh(context, line)
        Ok(#(
          [
            f.node("match", line, [
              state,
              f.node("call", line, [
                f.atom(initializer(parent), line),
                f.Sequence([initial]),
              ]),
            ]),
          ],
          Context(..context, constructing: Some(state)),
        ))
      }
      _, _ -> Ok(#([], context))
    },
  )
  use #(defaults, context) <- result.try(
    list.try_fold(source.members, #([], context), fn(acc, member) {
      case member {
        ast.FieldMember(field) ->
          case field.value {
            None -> Ok(acc)
            Some(value) -> {
              use #(value, context) <- result.try(initialize_field(
                field.name,
                value,
                field.span,
                acc.1,
              ))
              Ok(#(list.append(acc.0, [value]), context))
            }
          }
        _ -> Ok(acc)
      }
    }),
  )
  let context = Context(..context, locals: parameters_context.locals)
  use #(body, context) <- result.try(block(constructor.body, context))
  let assert Some(completed) = context.constructing
  let statements =
    list.flatten([first, implicit_parent, defaults, body, [completed]])
  let constructors = case hierarchy {
    False -> [
      f.node("function", line, [
        f.Atom(nominal.function_name(source.name.name, "new")),
        f.Integer(list.length(constructor_patterns)),
        f.Sequence([f.clause(constructor_patterns, statements, line)]),
      ]),
    ]
    True -> {
      let arity = list.length(constructor_patterns)
      let arguments =
        list.index_map(list.repeat(Nil, arity), fn(_, index) {
          f.variable("A" <> int.to_string(index), line)
        })
      [
        f.node("function", line, [
          f.Atom(initializer(class)),
          f.Integer(arity + 1),
          f.Sequence([
            f.clause([initial, ..constructor_patterns], statements, line),
          ]),
        ]),
        f.node("function", line, [
          f.Atom(nominal.function_name(source.name.name, "new")),
          f.Integer(arity),
          f.Sequence([
            f.clause(
              arguments,
              [
                f.node("call", line, [
                  f.atom(initializer(class), line),
                  f.Sequence([
                    class_layout.skeleton(outer.state, class, line),
                    ..arguments
                  ]),
                ]),
              ],
              line,
            ),
          ]),
        ]),
      ]
    }
  }
  use #(methods, context) <- result.try(
    list.try_fold(source.members, #([], context), fn(acc, member) {
      case member {
        ast.MethodMember(method) -> {
          let line = method.span.start.line
          let #(receiver, context) =
            fresh(
              Context(..acc.1, locals: dict.new(), constructing: None),
              line,
            )
          let context = Context(..context, receiver: Some(receiver))
          let #(args, context) = parameters(method.parameters, context)
          use #(body, context) <- result.try(block(method.body, context))
          let #(returned, context) = fresh(context, line)

          let name = case
            hierarchy && !string.starts_with(method.name.name, "_")
          {
            True -> body_name(source.name.name, method.name.name)
            False -> nominal.function_name(source.name.name, method.name.name)
          }
          let form =
            f.node("function", line, [
              f.Atom(name),
              f.Integer(list.length(args) + 1),
              f.Sequence([
                f.clause(
                  [receiver, ..args],
                  [return_boundary(body, line, returned, method.body)],
                  line,
                ),
              ]),
            ])
          Ok(#(list.append(acc.0, [form]), context))
        }
        _ -> Ok(acc)
      }
    }),
  )
  let dispatchers = case hierarchy {
    False -> []
    True -> dispatchers(class, source.span.start.line, outer.state)
  }
  Ok(#(
    list.flatten([constructors, methods, dispatchers]),
    Context(..outer, next: context.next),
  ))
}

/// Name the generated class initializer. Keep the naming rule shared by
/// constructor emission and constructor references.
///
/// ```text
/// class identity -> generated initializer atom
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn initializer(class: nominal.Class) -> String {
  nominal.function_name(class.source.name.name, "init")
}

/// Name a generated method implementation separately from its dispatcher. This
/// keeps overridden bodies addressable for super calls.
///
/// ```text
/// class + method -> implementation name
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn body_name(class: String, method: String) -> String {
  nominal.function_name(class, method) <> "@body"
}

/// Generate runtime dispatch clauses for a class hierarchy. Choose the
/// implementation using the concrete class while retaining the parent's visible
/// contract.
///
/// ```text
/// Animal receiver holding Dog -> Dog's overriding body
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#clauses.
fn dispatchers(
  class: nominal.Class,
  line: Int,
  state: unify.State,
) -> List(f.Term) {
  let children = unify.children(state, nominal.identity(class))
  class.methods
  |> list.filter(fn(method) { !string.starts_with(method.name.name, "_") })
  |> list.map(fn(method) {
    let arity = case unify.apply(method.type_, state) {
      monotype.FunctionType(arguments, _) -> list.length(arguments)
      _ -> 0
    }
    let receiver = f.variable("Receiver", line)
    let arguments =
      list.index_map(list.repeat(Nil, arity), fn(_, index) {
        f.variable("A" <> int.to_string(index), line)
      })
    let call = fn(name) {
      f.node("call", line, [
        f.atom(name, line),
        f.Sequence([receiver, ..arguments]),
      ])
    }
    let own = call(body_name(method.owner.1, method.name.name))
    let body = case children {
      [] -> own
      _ ->
        f.node("case", line, [
          class_layout.extension(state, class, receiver, line),
          f.Sequence([
            f.clause([f.atom("nil", line)], [own], line),
            f.clause(
              [f.variable("Extension", line)],
              [
                f.node("case", line, [
                  f.remote(
                    "erlang",
                    "element",
                    [
                      f.node("integer", line, [f.Integer(1)]),
                      f.variable("Extension", line),
                    ],
                    line,
                  ),
                  f.Sequence(
                    list.append(
                      list.map(children, fn(child) {
                        f.clause(
                          [class_layout.tag(child, line)],
                          [
                            call(nominal.function_name(
                              child.source.name.name,
                              method.name.name,
                            )),
                          ],
                          line,
                        )
                      }),
                      [f.clause([f.variable("_", line)], [own], line)],
                    ),
                  ),
                ]),
              ],
              line,
            ),
          ]),
        ])
    }
    f.node("function", line, [
      f.Atom(nominal.function_name(class.source.name.name, method.name.name)),
      f.Integer(arity + 1),
      f.Sequence([f.clause([receiver, ..arguments], [body], line)]),
    ])
  })
}

/// Call the checked parent initializer with the constructor's current object and
/// supplied arguments. Initialization remains inside the same object
/// construction.
///
/// ```text
/// super.new(name) -> generated parent initializer call
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn super_constructor(
  arguments: List(ast.Expression),
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  use parent <- result.try(parent_class(span, context))
  use previous <- result.try(option.to_result(
    context.constructing,
    Unsupported(span, "super.new outside construction"),
  ))
  use #(bindings, values, context) <- result.try(evaluate(arguments, context))
  let #(state, context) = fresh(context, line)
  let initialized =
    f.node("match", line, [
      state,
      f.node("call", line, [
        f.atom(initializer(parent), line),
        f.Sequence([previous, ..values]),
      ]),
    ])
  Ok(#(
    sequence(list.append(bindings, [initialized]), f.atom("nil", line), line),
    Context(..context, constructing: Some(state)),
  ))
}

/// Resolve the parent implementation directly rather than redispatching to the
/// current override. Keep the same receiver object.
///
/// ```text
/// super.describe() -> parent body with current receiver
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn super_method(
  name: String,
  arguments: List(ast.Expression),
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  use parent <- result.try(parent_class(span, context))
  use method <- result.try(
    list.find(parent.methods, fn(method) { method.name.name == name })
    |> result.map_error(fn(_) { Unsupported(span, "unknown superclass method") }),
  )
  use receiver <- result.try(case context.receiver, context.constructing {
    Some(receiver), _ | None, Some(receiver) -> Ok(receiver)
    None, None -> Error(Unsupported(span, "super outside a class body"))
  })
  use #(bindings, values, context) <- result.try(evaluate(arguments, context))
  Ok(#(
    sequence(
      bindings,
      f.node("call", line, [
        f.atom(body_name(method.owner.1, name), line),
        f.Sequence([receiver, ..values]),
      ]),
      line,
    ),
    context,
  ))
}

/// Retrieve the checked superclass descriptor used by super lowering. Missing
/// metadata is an unsupported-codegen report, not a guessed layout.
///
/// ```text
/// current class -> declared superclass metadata
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn parent_class(
  span: Span,
  context: Context,
) -> Result(nominal.Class, Unsupported) {
  context.class
  |> option.to_result(Nil)
  |> result.try(unify.class(context.state, _))
  |> result.try(fn(class) { option.to_result(class.superclass, Nil) })
  |> result.try(fn(parent) { unify.class(context.state, parent.identity) })
  |> result.map_error(fn(_) { Unsupported(span, "super without a superclass") })
}

/// Lower constructor branches while threading the partially initialized object.
/// Every successful branch must return the appropriate current construction
/// value.
///
/// ```text
/// constructor match branch -> clause returning updated object state
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#clauses.
fn constructor_branches(
  values: List(ast.Branch),
  subject: f.Term,
  line: Int,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  case values {
    [] ->
      Ok(#(
        f.remote("erlang", "error", [f.atom("pooka_match_failure", line)], line),
        context,
      ))
    [branch, ..rest] -> {
      let outer = context
      use #(branch_subject, pattern, context) <- result.try(
        lower_branch_pattern(branch.pattern, subject, context),
      )
      use #(guard, context) <- result.try(case branch.guard {
        None -> Ok(#(None, context))
        Some(guard) ->
          expression(guard, context)
          |> result.map(fn(pair) { #(Some(pair.0), pair.1) })
      })
      let guard_state = context.constructing
      use #(body, context) <- result.try(expression(branch.body, context))
      let assert Some(final_state) = context.constructing
      let #(body_value, context) = fresh(context, line)
      let body =
        sequence(
          [f.node("match", line, [body_value, body])],
          f.node("tuple", line, [f.Sequence([body_value, final_state])]),
          line,
        )
      let #(state_parameter, context) = fresh(context, line)
      use #(fallback, context) <- result.try(constructor_branches(
        rest,
        subject,
        line,
        Context(
          ..context,
          locals: outer.locals,
          constructing: Some(state_parameter),
        ),
      ))
      let #(next, context) = fresh(context, line)
      let continuation =
        f.node("match", line, [
          next,
          anonymous([state_parameter], [fallback], line),
        ])
      let assert Some(initial_state) = outer.constructing
      let assert Some(guard_state) = guard_state
      let fallback_pattern =
        f.node("call", line, [next, f.Sequence([initial_state])])
      let body = case guard {
        None -> body
        Some(guard) ->
          f.node("case", line, [
            guard,
            f.Sequence([
              f.clause([f.atom("true", line)], [body], line),
              f.clause(
                [f.atom("false", line)],
                [f.node("call", line, [next, f.Sequence([guard_state])])],
                line,
              ),
            ]),
          ])
      }
      let matched =
        f.node("case", line, [
          branch_subject,
          f.Sequence([
            f.clause([pattern], [body], line),
            f.clause([f.variable("_", line)], [fallback_pattern], line),
          ]),
        ])
      Ok(#(
        sequence([continuation], matched, line),
        Context(..outer, next: context.next),
      ))
    }
  }
}

/// Build access through a declared interface contract. The runtime receiver
/// remains concrete even though its static view is an interface.
///
/// ```text
/// value: Named -> name method dispatch on concrete receiver
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn interface_access(
  subject: ast.Expression,
  name: ast.Name,
  span: Span,
  type_: monotype.Type,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let assert monotype.Nominal(module, interface_name, _, _) = type_
  use interface <- result.try(
    unify.interface(context.state, #(module, interface_name))
    |> result.map_error(fn(_) { Unsupported(span, "interface metadata") }),
  )
  use method <- result.try(
    list.find(interface.methods, fn(method) { method.name.name == name.name })
    |> result.map_error(fn(_) { Unsupported(span, "interface method") }),
  )
  let assert monotype.FunctionType(parameters, _) = method.type_
  let line = span.start.line
  use #(bindings, values, context) <- result.try(evaluate([subject], context))
  let assert [receiver] = values
  let #(arguments, context) =
    list.fold(parameters, #([], context), fn(acc, _) {
      let #(variable, context) = fresh(acc.1, line)
      #(list.append(acc.0, [variable]), context)
    })
  let call =
    f.remote(
      "pooka_runtime_ffi",
      "interface_call",
      [
        f.atom(context.namespace, line),
        receiver,
        f.atom(name.name, line),
        list_term(arguments, f.node("nil", line, []), line),
      ],
      line,
    )
  Ok(#(sequence(bindings, anonymous(arguments, [call], line), line), context))
}

/// Generate clauses routing an interface method to its checked implementations.
/// Interface membership does not introduce a separate object representation.
///
/// ```text
/// interface method -> implementation dispatch clauses
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#clauses.
fn interface_dispatcher(
  classes: List(nominal.Class),
  state: unify.State,
) -> List(f.Term) {
  let clauses =
    list.flat_map(classes, fn(class) {
      let methods =
        list.flat_map(class.interfaces, fn(type_) {
          case type_ {
            monotype.Nominal(module, name, monotype.InterfaceKind, _) ->
              case unify.interface(state, #(module, name)) {
                Ok(interface) ->
                  list.map(interface.methods, fn(method) { method.name.name })
                Error(Nil) -> []
              }
            _ -> []
          }
        })
        |> list.unique
      list.filter_map(methods, fn(name) {
        use method <- result.try(
          list.find(class.methods, fn(method) { method.name.name == name }),
        )
        let assert monotype.FunctionType(parameters, _) =
          unify.apply(method.type_, state)
        let line = class.source.span.start.line
        let receiver = f.variable("Receiver", line)
        let arguments =
          list.index_map(parameters, fn(_, index) {
            f.variable("A" <> int.to_string(index), line)
          })
        let fields = list.map(class.fields, fn(_) { f.variable("_", line) })
        let pattern =
          f.node("match", line, [
            receiver,
            class_layout.exact_pattern(state, class, fields, line),
          ])
        let call =
          f.node("call", line, [
            f.atom(nominal.function_name(class.source.name.name, name), line),
            f.Sequence([receiver, ..arguments]),
          ])
        Ok(f.clause(
          [
            pattern,
            f.atom(name, line),
            list_term(arguments, f.node("nil", line, []), line),
          ],
          [call],
          line,
        ))
      })
    })
  case clauses {
    [] -> []
    _ -> [
      f.node("function", 1, [
        f.Atom("$interface@call"),
        f.Integer(3),
        f.Sequence(clauses),
      ]),
    ]
  }
}

/// Name the generated actor initializer used by construction.
///
/// ```text
/// actor identity -> initializer function atom
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn actor_initializer(class: nominal.Class) -> String {
  "$actor@" <> class.source.name.name <> "@init"
}

/// Name a generated actor method or behavior implementation.
///
/// ```text
/// actor + member -> implementation function atom
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn actor_body(class: nominal.Class, method: String) -> String {
  "$actor@" <> class.source.name.name <> "@" <> method
}

/// Emit actor construction, member entrypoints and runtime support calls. Mutable
/// actor state belongs to the actor service, not an immutable class tuple handed
/// to callers.
///
/// ```text
/// actor Counter -> runtime actor handle + generated function forms
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
fn actor_forms(
  source: ast.Class,
  outer: Context,
) -> Result(#(List(f.Term), Context), Unsupported) {
  use class <- result.try(
    unify.named_class(outer.state, outer.path, "", source.name.name)
    |> result.map_error(fn(_) { Unsupported(source.span, "actor metadata") }),
  )
  let constructor =
    list.find_map(source.members, fn(member) {
      case member {
        ast.ConstructorMember(value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
    |> result.unwrap(ast.Constructor(
      [],
      [],
      ast.Block([], source.span),
      source.span,
    ))
  let line = constructor.span.start.line
  let context =
    Context(
      ..outer,
      locals: dict.new(),
      class: Some(nominal.identity(class)),
      constructing: None,
    )
  let #(args, parameters_context) = parameters(constructor.parameters, context)
  let #(receiver, context) =
    fresh(Context(..parameters_context, locals: dict.new()), line)
  let context = Context(..context, receiver: Some(receiver))
  let initialize =
    f.remote(
      "pooka_runtime_ffi",
      "actor_initialize",
      [class_layout.skeleton(outer.state, class, line)],
      line,
    )
  let bind_receiver =
    f.node("match", line, [
      receiver,
      f.remote("pooka_runtime_ffi", "actor_self", [], line),
    ])
  use #(defaults, context) <- result.try(
    list.try_fold(source.members, #([], context), fn(acc, member) {
      case member {
        ast.FieldMember(field) ->
          case field.value {
            None -> Ok(acc)
            Some(value) -> {
              use #(value, context) <- result.try(actor_write(
                class,
                field.name,
                value,
                field.span,
                acc.1,
              ))
              Ok(#(list.append(acc.0, [value]), context))
            }
          }
        _ -> Ok(acc)
      }
    }),
  )
  use #(body, context) <- result.try(block(
    constructor.body,
    Context(..context, locals: parameters_context.locals),
  ))
  let init =
    f.node("function", line, [
      f.Atom(actor_initializer(class)),
      f.Integer(list.length(args)),
      f.Sequence([
        f.clause(
          args,
          list.flatten([
            [initialize, bind_receiver],
            defaults,
            body,
            [f.atom("nil", line)],
          ]),
          line,
        ),
      ]),
    ])
  let wrapper_args =
    list.index_map(args, fn(_, i) { f.variable("A" <> int.to_string(i), line) })
  let start =
    f.remote(
      "pooka_runtime_ffi",
      "actor_start",
      [
        f.atom(module_name(outer.namespace, class.runtime_module), line),
        f.atom(source.name.name, line),
        f.atom(actor_initializer(class), line),
        list_term(wrapper_args, f.node("nil", line, []), line),
      ],
      line,
    )
  let constructor =
    f.node("function", line, [
      f.Atom(nominal.function_name(source.name.name, "new")),
      f.Integer(list.length(args)),
      f.Sequence([f.clause(wrapper_args, [start], line)]),
    ])
  use #(methods, context) <- result.try(
    list.try_fold(source.members, #([], context), fn(acc, member) {
      case member {
        ast.MethodMember(method) -> {
          let line = method.span.start.line
          let #(receiver, context) =
            fresh(
              Context(..acc.1, locals: dict.new(), constructing: None),
              line,
            )
          let context = Context(..context, receiver: Some(receiver))
          let #(args, context) = parameters(method.parameters, context)
          use #(body, context) <- result.try(block(method.body, context))
          let #(returned, context) = fresh(context, line)
          let check_owner =
            f.remote("pooka_runtime_ffi", "actor_owner", [receiver], line)
          let implementation =
            f.node("function", line, [
              f.Atom(actor_body(class, method.name.name)),
              f.Integer(list.length(args) + 1),
              f.Sequence([
                f.clause(
                  [receiver, ..args],
                  [
                    check_owner,
                    return_boundary(body, line, returned, method.body),
                  ],
                  line,
                ),
              ]),
            ])
          let receiver = f.variable("Receiver", line)
          let arguments =
            list.index_map(args, fn(_, i) {
              f.variable("A" <> int.to_string(i), line)
            })
          let call =
            f.remote(
              "pooka_runtime_ffi",
              "actor_call",
              [
                receiver,
                f.atom(actor_body(class, method.name.name), line),
                list_term(arguments, f.node("nil", line, []), line),
                f.atom(
                  case list.contains(class.behaviours, method.name.name) {
                    True -> "true"
                    False -> "false"
                  },
                  line,
                ),
              ],
              line,
            )
          let wrapper =
            f.node("function", line, [
              f.Atom(nominal.function_name(source.name.name, method.name.name)),
              f.Integer(list.length(args) + 1),
              f.Sequence([f.clause([receiver, ..arguments], [call], line)]),
            ])
          Ok(#(list.flatten([acc.0, [implementation, wrapper]]), context))
        }
        _ -> Ok(acc)
      }
    }),
  )
  Ok(#([init, constructor, ..methods], Context(..outer, next: context.next)))
}

/// Lower access to an actor member through its runtime handle. Preserve the
/// distinction between synchronous reads and queued behaviors.
///
/// ```text
/// counter.value() -> synchronous runtime request
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn actor_member(
  class: nominal.Class,
  receiver: f.Term,
  name: String,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  case list.find(class.fields, fn(field) { field.name.name == name }) {
    Ok(field) ->
      Ok(#(
        f.remote(
          "pooka_runtime_ffi",
          "actor_read",
          [receiver, f.node("integer", line, [f.Integer(field.index)])],
          line,
        ),
        context,
      ))
    Error(Nil) -> {
      use method <- result.try(
        list.find(class.methods, fn(method) { method.name.name == name })
        |> result.map_error(fn(_) { Unsupported(span, "unknown actor method") }),
      )
      let assert monotype.FunctionType(parameters, _) =
        unify.apply(method.type_, context.state)
      let #(args, context) =
        list.fold(parameters, #([], context), fn(acc, _) {
          let #(arg, context) = fresh(acc.1, line)
          #(list.append(acc.0, [arg]), context)
        })
      let call =
        f.remote(
          module_name(context.namespace, class.runtime_module),
          nominal.function_name(class.source.name.name, name),
          [receiver, ..args],
          line,
        )
      Ok(#(anonymous(args, [call], line), context))
    }
  }
}

/// Lower a checked actor-state assignment through the runtime state machinery.
/// Ordinary immutable let bindings never use this path.
///
/// ```text
/// actor state += value -> read/compute/write in actor execution
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn actor_write(
  class: nominal.Class,
  name: ast.Name,
  value: ast.Expression,
  span: Span,
  context: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  use field <- result.try(
    list.find(class.fields, fn(field) { field.name.name == name.name })
    |> result.map_error(fn(_) { Unsupported(span, "actor field") }),
  )
  use receiver <- result.try(option.to_result(
    context.receiver,
    Unsupported(span, "actor receiver"),
  ))
  use #(bindings, values, context) <- result.try(evaluate([value], context))
  let assert [value] = values
  let line = span.start.line
  let call =
    f.remote(
      "pooka_runtime_ffi",
      "actor_write",
      [receiver, f.node("integer", line, [f.Integer(field.index)]), value],
      line,
    )
  Ok(#(sequence(bindings, call, line), context))
}

/// Capture actor-sensitive receiver state before building a closure. Evaluate
/// captures now so invoking the closure later retains the intended context.
///
/// ```text
/// fn() { self.value } -> closure with captured actor context
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn actor_captures(context: Context, line: Int) -> #(List(f.Term), Context) {
  let descriptor = case context.class {
    Some(identity) -> unify.class(context.state, identity)
    None -> Error(Nil)
  }
  case descriptor, context.receiver {
    Ok(nominal.Class(actor: True, fields: fields, ..)), Some(receiver) ->
      list.fold(fields, #([], context), fn(acc, field) {
        case dict.has_key(acc.1.locals, field.name.name) {
          True -> acc
          False -> {
            let #(value, context) = fresh(acc.1, line)
            let read =
              f.remote(
                "pooka_runtime_ffi",
                "actor_read",
                [receiver, f.node("integer", line, [f.Integer(field.index)])],
                line,
              )
            #(
              list.append(acc.0, [f.node("match", line, [value, read])]),
              Context(
                ..context,
                locals: dict.insert(context.locals, field.name.name, value),
              ),
            )
          }
        }
      })
    _, _ -> #([], context)
  }
}

/// Lower a loop inside construction while carrying the current partially
/// initialized value. A branch cannot silently lose initialization performed
/// before it.
///
/// ```text
/// constructor loop -> recursive function carrying construction state
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn constructor_loop(
  body: ast.Block,
  line: Int,
  outer: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let assert Some(initial) = outer.constructing
  let name = "ConstructorLoop" <> int.to_string(outer.next)
  let context = Context(..outer, next: outer.next + 1)
  let #(parameter, context) = fresh(context, line)
  use #(body, context) <- result.try(block(
    body,
    Context(..context, constructing: Some(parameter)),
  ))
  let assert Some(completed) = context.constructing
  let #(break_value, context) = fresh(context, line)
  let #(break_state, context) = fresh(context, line)
  let #(continue_state, context) = fresh(context, line)
  let tuple = fn(elements) { f.node("tuple", line, [f.Sequence(elements)]) }
  let next = fn(state) { tuple([f.atom("continue", line), state]) }
  let done = fn(value, state) { tuple([f.atom("done", line), value, state]) }
  let protected =
    f.node("try", line, [
      f.Sequence(list.append(body, [next(completed)])),
      f.Sequence([]),
      f.Sequence([
        catch_clause(
          tuple([
            f.atom("pooka_constructor_break", line),
            break_value,
            break_state,
          ]),
          [done(break_value, break_state)],
          line,
        ),
        catch_clause(
          tuple([f.atom("pooka_constructor_continue", line), continue_state]),
          [next(continue_state)],
          line,
        ),
      ]),
      f.Sequence([]),
    ])
  let #(next_state, context) = fresh(context, line)
  let #(result_value, context) = fresh(context, line)
  let #(result_state, context) = fresh(context, line)
  let continued =
    f.node("call", line, [f.variable(name, line), f.Sequence([next_state])])
  let dispatch =
    f.node("case", line, [
      protected,
      f.Sequence([
        f.clause([next(next_state)], [continued], line),
        f.clause(
          [done(result_value, result_state)],
          [tuple([result_value, result_state])],
          line,
        ),
      ]),
    ])
  let fun_ =
    f.node("named_fun", line, [
      f.Atom(name),
      f.Sequence([f.clause([parameter], [dispatch], line)]),
    ])
  let called = f.node("call", line, [fun_, f.Sequence([initial])])
  let #(pair, context) = fresh(context, line)
  Ok(#(
    sequence(
      [f.node("match", line, [pair, called])],
      tuple_element(1, pair, line),
      line,
    ),
    Context(
      ..context,
      locals: outer.locals,
      constructing: Some(tuple_element(2, pair, line)),
    ),
  ))
}

/// Lower iteration by advancing the checked iterator and handling Some/None
/// termination. Keep explicit break values and continue transfers local to this
/// loop.
///
/// ```text
/// runtime iterator step -> {some, Value, Rest} or none -> loop step/end
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn iteration_loop(
  iteration: ast.Iteration,
  body: ast.Block,
  span: Span,
  outer: Context,
) -> Result(#(f.Term, Context), Unsupported) {
  let line = span.start.line
  let mode = case
    unify.expression_type(
      outer.state,
      outer.path,
      ast.expression_span(iteration.iterable),
    )
  {
    Ok(monotype.ListType(_)) -> "list"
    _ -> "protocol"
  }
  let value_loop = case unify.expression_type(outer.state, outer.path, span) {
    Ok(monotype.NilType) -> False
    _ -> True
  }
  use #(bindings, sources, context) <- result.try(evaluate(
    [iteration.iterable],
    outer,
  ))
  let assert [source] = sources
  let constructing = option.is_some(context.constructing)
  let initial = option.unwrap(context.constructing, f.atom("nil", line))
  let name = "Iteration" <> int.to_string(context.next)
  let context = Context(..context, next: context.next + 1)
  let #(remaining, context) = fresh(context, line)
  let #(state_parameter, context) = fresh(context, line)
  let #(rest, context) = fresh(context, line)
  let context =
    Context(..context, constructing: case constructing {
      True -> Some(state_parameter)
      False -> None
    })
  use #(pattern, context) <- result.try(lower_pattern(
    iteration.pattern,
    context,
  ))
  use #(body, context) <- result.try(block(body, context))
  let completed = option.unwrap(context.constructing, state_parameter)
  let tuple = fn(elements) { f.node("tuple", line, [f.Sequence(elements)]) }
  let next = fn(state) { tuple([f.atom("continue", line), state]) }
  let done = fn(value, state) { tuple([f.atom("done", line), value, state]) }
  let #(break_value, context) = fresh(context, line)
  let #(break_state, context) = fresh(context, line)
  let #(continue_state, context) = fresh(context, line)
  let catches = case constructing {
    True -> [
      catch_clause(
        tuple([
          f.atom("pooka_constructor_break", line),
          break_value,
          break_state,
        ]),
        [done(break_value, break_state)],
        line,
      ),
      catch_clause(
        tuple([f.atom("pooka_constructor_continue", line), continue_state]),
        [next(continue_state)],
        line,
      ),
    ]
    False -> [
      catch_clause(
        tuple([f.atom("pooka_break", line), break_value]),
        [done(break_value, state_parameter)],
        line,
      ),
      catch_clause(
        f.atom("pooka_continue", line),
        [next(state_parameter)],
        line,
      ),
    ]
  }
  let protected =
    f.node("try", line, [
      f.Sequence(list.append(body, [next(completed)])),
      f.Sequence([]),
      f.Sequence(catches),
      f.Sequence([]),
    ])
  let #(next_state, context) = fresh(context, line)
  let #(result_value, context) = fresh(context, line)
  let #(result_state, context) = fresh(context, line)
  let dispatch =
    f.node("case", line, [
      protected,
      f.Sequence([
        f.clause(
          [next(next_state)],
          [
            f.node("call", line, [
              f.variable(name, line),
              f.Sequence([rest, next_state]),
            ]),
          ],
          line,
        ),
        f.clause(
          [done(result_value, result_state)],
          [tuple([result_value, result_state])],
          line,
        ),
      ]),
    ])
  let exhausted = case value_loop {
    True -> f.remote("pooka_runtime_ffi", "iteration_exhausted", [], line)
    False -> tuple([f.atom("nil", line), state_parameter])
  }
  let step =
    f.remote(
      "pooka_runtime_ffi",
      "iteration_next",
      [f.atom(context.namespace, line), remaining, f.atom(mode, line)],
      line,
    )
  let body =
    f.node("case", line, [
      step,
      f.Sequence([
        f.clause([f.atom("none", line)], [exhausted], line),
        f.clause(
          [tuple([f.atom("some", line), pattern, rest])],
          [dispatch],
          line,
        ),
      ]),
    ])
  let fun_ =
    f.node("named_fun", line, [
      f.Atom(name),
      f.Sequence([f.clause([remaining, state_parameter], [body], line)]),
    ])
  let call = f.node("call", line, [fun_, f.Sequence([source, initial])])
  let #(pair, context) = fresh(context, line)
  Ok(#(
    sequence(
      list.append(bindings, [f.node("match", line, [pair, call])]),
      tuple_element(1, pair, line),
      line,
    ),
    Context(..context, locals: outer.locals, constructing: case constructing {
      True -> Some(tuple_element(2, pair, line))
      False -> None
    }),
  ))
}

/// Select the emitted binary representation from checked segment information. The
/// type checker and emitter must agree on bytes, bits and UTF encodings.
///
/// ```text
/// UTF-8 segment -> bin_element with utf8 specifier
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn segment_representation(
  name: String,
  options: List(ast.BitArrayOption),
) -> String {
  case name {
    "int" -> "integer"
    "utf8_codepoint" -> "utf8"
    "utf16_codepoint" -> "utf16"
    "utf32_codepoint" -> "utf32"
    "bytes" -> "binary"
    "bits" ->
      case
        list.any(options, fn(option) {
          case option {
            ast.UnitOption(_, _) -> True
            _ -> False
          }
        })
      {
        True -> "binary"
        False -> "bitstring"
      }
    _ -> name
  }
}

/// Resolve the nominal enum descriptor used for variant lowering. Variant
/// identity comes from the declaration, not its display spelling alone.
///
/// ```text
/// Order.Less -> enum metadata + declared variant atom
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#atomic-literals.
fn enum_of(
  subject: ast.Expression,
  context: Context,
) -> Result(nominal.Enum, Nil) {
  case subject {
    ast.TypeName(name, _) ->
      unify.named_enum(context.state, context.path, "", name)
    ast.FieldAccess(ast.Variable(alias, _), name, _) ->
      case dict.has_key(context.locals, alias) {
        True -> Error(Nil)
        False -> unify.named_enum(context.state, context.path, alias, name.name)
      }
    _ -> Error(Nil)
  }
}

/// Select one alternative before entering the shared guard. A false guard
/// continues with the next arm, rather than trying another door in this one.
/// Fresh inner bindings are gathered into one tuple for the shared body.
///
/// ```text
/// [x] | ["greet", x] -> body
/// case Subject of P1 -> {matched,X1}; P2 -> {matched,X2}; _ -> no_match end
/// ```
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn lower_branch_pattern(
  value: ast.Pattern,
  subject: f.Term,
  context: Context,
) -> Result(#(f.Term, f.Term, Context), Unsupported) {
  case value {
    ast.AlternativePattern(values, span) -> {
      let line = span.start.line
      let outer = context.locals
      let names = ast.pattern_bindings(value)
      use #(reversed, context) <- result.try(
        list.try_fold(values, #([], context), fn(acc, pattern) {
          use #(pattern, context) <- result.try(lower_pattern(
            pattern,
            Context(..acc.1, locals: outer),
          ))
          let bindings =
            list.map(names, fn(name) {
              let assert Ok(value) = dict.get(context.locals, name.name)
              value
            })
          let tuple =
            f.node("tuple", line, [
              f.Sequence([f.atom("matched", line), ..bindings]),
            ])
          Ok(#([f.clause([pattern], [tuple], line), ..acc.0], context))
        }),
      )
      let selector =
        f.node("case", line, [
          subject,
          f.Sequence(
            list.append(list.reverse(reversed), [
              f.clause(
                [f.variable("_", line)],
                [f.atom("no_match", line)],
                line,
              ),
            ]),
          ),
        ])
      let #(variables, context) =
        list.fold(
          names,
          #([], Context(..context, locals: outer)),
          fn(acc, name) {
            let #(variable, context) = fresh(acc.1, line)
            #(
              [variable, ..acc.0],
              Context(
                ..context,
                locals: dict.insert(context.locals, name.name, variable),
              ),
            )
          },
        )
      let pattern =
        f.node("tuple", line, [
          f.Sequence([f.atom("matched", line), ..list.reverse(variables)]),
        ])
      Ok(#(selector, pattern, context))
    }
    _ -> {
      use #(pattern, context) <- result.try(lower_pattern(value, context))
      Ok(#(subject, pattern, context))
    }
  }
}
