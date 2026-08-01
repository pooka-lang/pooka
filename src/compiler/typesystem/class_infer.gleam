//// A class arrives as syntax and leaves with a measured set of fields.
////
//// Register identities first, prepare fields and signatures next, then check
//// construction and methods. This staging lets a recursive group refer to a class
//// without mistaking an unprepared field list for an empty class.
////
//// ```text
//// register Box -> prepare its value field -> check Box patterns
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/function_group
import compiler/parser/ast
import compiler/typesystem/infer
import compiler/typesystem/interface_infer
import compiler/typesystem/monotype as t
import compiler/typesystem/nominal
import compiler/typesystem/scheme
import compiler/typesystem/unify
import diagnostics/diagnostic.{type Diagnostic}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import utilities/location.{type Span}

pub type Report {
  Report(state: unify.State, diagnostics: List(Diagnostic))
}

/// Derive the nominal module identity from the compiler's source path convention.
///
/// ```text
/// source module path -> qualified identity used by class metadata
/// ```
pub fn module_identity(path: String) -> String {
  case path {
    "src/" <> rest -> string.drop_end(rest, string.length(".pooka"))
    _ -> path
  }
}

/// Reserve qualified class identities before bodies are inferred. An identity's
/// existence does not mean its fields have been prepared yet.
///
/// ```text
/// registered Box may still have ready=False until prepare
/// ```
pub fn register(
  module: ast.Module,
  state: unify.State,
  path: String,
) -> unify.State {
  list.fold(module.declarations, state, fn(state, declaration) {
    let descriptor = case declaration {
      ast.ClassDeclaration(source) -> Some(#(source, False, []))
      ast.ActorDeclaration(actor) ->
        Some(#(
          nominal.actor_class(actor),
          True,
          list.filter_map(actor.members, fn(member) {
            case member {
              ast.BehaviourMember(method) -> Ok(method.name.name)
              _ -> Error(Nil)
            }
          }),
        ))
      _ -> None
    }
    case descriptor {
      Some(#(source, actor, behaviours)) -> {
        let #(parameters, state) =
          list.fold(source.type_parameters, #([], state), fn(acc, name) {
            let #(id, type_, state) = unify.fresh_rigid(name.name, acc.1)
            #([#(id, type_), ..acc.0], state)
          })
        let class =
          nominal.Class(
            module_identity(path),
            path,
            module_identity(path),
            source,
            list.reverse(parameters),
            [],
            t.ErrorType,
            [],
            [],
            False,
            local_superclass(module, source, path),
            [],
            actor,
            behaviours,
          )
        state
        |> unify.register_class(class)
        |> unify.bind_type(path, "", source.name.name, nominal.identity(class))
      }
      None -> state
    }
  })
}

fn local_superclass(
  module: ast.Module,
  source: ast.Class,
  path: String,
) -> Option(nominal.Superclass) {
  case source.superclass {
    Some(ast.NamedType(None, name, _, _)) ->
      case
        list.any(module.declarations, fn(declaration) {
          case declaration {
            ast.ClassDeclaration(class) -> class.name.name == name
            _ -> False
          }
        })
      {
        True -> Some(nominal.Superclass(#(module_identity(path), name), []))
        False -> None
      }
    _ -> None
  }
}

/// Resolve the field and callable schema before class patterns or recursive
/// methods inspect it.
///
/// ```text
/// Box(value: Int) -> one prepared field of type Int
/// ```
pub fn prepare(
  source: ast.Class,
  state: unify.State,
  path: String,
) -> Result(#(Prepared, unify.State), infer.Unsupported) {
  use class <- result.try(
    unify.named_class(state, path, "", source.name.name)
    |> result.map_error(fn(_) {
      infer.Unsupported(source.span, "unregistered class")
    }),
  )
  let generics =
    list.zip(source.type_parameters, class.parameters)
    |> list.map(fn(pair) { #(pair.0.name, pair.1.1) })
    |> dict.from_list
  use #(parent, state) <- result.try(superclass(class, generics, state, path))
  use implemented <- result.try(
    list.try_map(source.interfaces, infer.annotation_type(
      _,
      generics,
      state,
      path,
    )),
  )
  use Nil <- result.try(
    list.try_each(implemented, fn(type_) {
      case type_ {
        t.Nominal(_, _, t.InterfaceKind, _) -> Ok(Nil)
        _ ->
          Error(infer.Unsupported(
            source.span,
            "a with clause must name an interface",
          ))
      }
    }),
  )
  let inherited_interfaces = case parent {
    None -> []
    Some(#(parent, arguments)) ->
      list.map(parent.interfaces, nominal.instantiate(_, parent, arguments))
  }
  let class =
    nominal.Class(
      ..class,
      interfaces: list.unique(list.append(inherited_interfaces, implemented)),
      superclass: option.map(parent, fn(parent) {
        nominal.Superclass(nominal.identity(parent.0), parent.1)
      }),
    )
  use #(fields, methods, constructor, state) <- result.try(signatures(
    class,
    generics,
    state,
    path,
  ))
  let #(fields, methods, state, inheritance_errors) = case parent {
    None -> #(fields, methods, state, [])
    Some(#(parent, arguments)) ->
      inherit(parent, arguments, fields, methods, state, path)
  }
  let methods =
    list.map(methods, fn(method) {
      case list.contains(class.behaviours, method.name.name), method.type_ {
        True, t.FunctionType(parameters, _) ->
          nominal.Method(..method, type_: t.FunctionType(parameters, t.NilType))
        _, _ -> method
      }
    })
  let class =
    nominal.Class(..class, fields:, methods:, constructor: constructor.0)
  let policy_errors = constructor_policy(class, parent, state, path)
  let errors = list.append(inheritance_errors, policy_errors)
  let class = case diagnostic.has_errors(errors) {
    True -> nominal.Class(..class, constructor: t.ErrorType)
    False -> class
  }
  let state = interface_infer.seed_methods(class, state, path)
  let state = unify.register_class(state, class)
  Ok(#(Prepared(constructor.1, errors), state))
}

pub type Prepared {
  Prepared(constructor: ast.Constructor, diagnostics: List(Diagnostic))
}

/// Prepare and check a class through the ordinary class-inference entrypoint.
///
/// ```text
/// class syntax -> checked field and method metadata
/// ```
pub fn check(
  source: ast.Class,
  environment: infer.Environment,
  state: unify.State,
  path: String,
) -> Result(Report, infer.Unsupported) {
  use #(prepared, state) <- result.try(prepare(source, state, path))
  let assert Ok(class) = unify.named_class(state, path, "", source.name.name)
  let state = unify.register_class(state, nominal.Class(..class, ready: True))
  check_prepared(source, prepared, environment, state, path, False)
}

/// Check implementations against a class schema that its recursive group has
/// already prepared.
///
/// ```text
/// prepared constructor signature -> validate constructor body
/// ```
pub fn check_prepared(
  source: ast.Class,
  prepared: Prepared,
  environment: infer.Environment,
  state: unify.State,
  path: String,
  deferred: Bool,
) -> Result(Report, infer.Unsupported) {
  let assert Ok(class) = unify.named_class(state, path, "", source.name.name)
  let #(class, state, inheritance_errors) = case deferred, class.superclass {
    True, Some(link) -> {
      let assert Ok(parent) = unify.class(state, link.identity)
      let own_fields =
        list.index_map(nominal.own_fields(class), fn(field, index) {
          nominal.Field(..field, index: index + 2)
        })
      let own_methods =
        list.filter(class.methods, fn(method) {
          method.owner == nominal.identity(class)
        })
      let #(fields, methods, state, errors) =
        inherit(parent, link.arguments, own_fields, own_methods, state, path)
      let class = nominal.Class(..class, fields:, methods:)
      #(
        class,
        unify.register_class(state, class),
        list.unique(list.append(prepared.diagnostics, errors)),
      )
    }
    _, _ -> #(class, state, prepared.diagnostics)
  }
  let fields = class.fields
  let methods = class.methods
  let constructor = #(class.constructor, prepared.constructor)
  let captured =
    list.fold(
      infer.environment_schemes(environment),
      set.new(),
      fn(found, value) { set.union(found, scheme.free_variables(value, state)) },
    )
  use initial <- result.try(
    list.try_fold(
      source.members,
      Report(state, inheritance_errors),
      fn(report, member) {
        case member {
          ast.FieldMember(field) ->
            case field.value {
              None -> Ok(report)
              Some(value) -> {
                use found <- result.try(infer.infer_field_default(
                  class,
                  field,
                  environment,
                  report.state,
                  path,
                ))
                let assert Ok(expected) =
                  list.find(fields, fn(value) {
                    value.name.name == field.name.name
                  })
                Ok(constrain(
                  expected.type_,
                  found.type_,
                  field.name.span,
                  ast.expression_span(value),
                  "A field default must match its declared type.",
                  Report(
                    found.state,
                    list.append(report.diagnostics, found.diagnostics),
                  ),
                  path,
                ))
              }
            }
          _ -> Ok(report)
        }
      },
    ),
  )
  use constructor_report <- result.try(infer.infer_constructor(
    class,
    constructor.1,
    environment,
    initial.state,
    path,
  ))
  let report =
    constrain(
      class.constructor,
      constructor_report.type_,
      source.name.span,
      constructor.1.span,
      "Constructor parameters must agree with field initialization.",
      Report(
        constructor_report.state,
        list.append(initial.diagnostics, constructor_report.diagnostics),
      ),
      path,
    )
  let field_variables =
    variables(list.map(fields, fn(field) { field.type_ }), report.state)
  let quantified =
    variables([class.constructor], report.state)
    |> set.difference(field_variables)
    |> set.difference(captured)
    |> set.difference(variables(
      list.map(methods, fn(method) { method.type_ }),
      report.state,
    ))
    |> set.to_list
    |> list.sort(int.compare)
  let class =
    nominal.Class(..class, ready: True, constructor_quantified: case deferred {
      True -> []
      False -> quantified
    })
  let state = unify.register_class(report.state, class)
  let source_methods =
    list.filter_map(source.members, fn(member) {
      case member {
        ast.MethodMember(method) ->
          Ok(case list.contains(class.behaviours, method.name.name) {
            True ->
              ast.Function(
                ..method,
                return_type: Some(ast.NamedType(None, "Nil", [], method.span)),
              )
            False -> method
          })
        _ -> Error(Nil)
      }
    })
  use report <- result.try(
    list.try_fold(
      function_group.groups(source_methods),
      Report(state, report.diagnostics),
      fn(report, group) {
        use report <- result.try(
          list.try_fold(group, report, fn(report, method) {
            let assert Ok(current) =
              unify.class(report.state, nominal.identity(class))
            use found <- result.try(infer.infer_method(
              current,
              method,
              environment,
              report.state,
              path,
            ))
            let assert Ok(expected) =
              list.find(current.methods, fn(value) {
                value.name.name == method.name.name
              })
            Ok(constrain(
              expected.type_,
              found.type_,
              method.name.span,
              method.span,
              "Method bodies and recursive uses must agree.",
              Report(
                found.state,
                list.append(report.diagnostics, found.diagnostics),
              ),
              path,
            ))
          }),
        )
        use report <- result.try(
          list.try_fold(group, report, fn(report, method) {
            let assert Ok(current) =
              unify.class(report.state, nominal.identity(class))
            let assert Ok(signature) =
              list.find(current.methods, fn(value) {
                value.name.name == method.name.name
              })
            use checked <- result.try(infer.validate_method_signature(
              current,
              method,
              unify.apply(signature.type_, report.state),
              report.state,
              path,
            ))
            Ok(Report(
              checked.state,
              list.append(report.diagnostics, checked.diagnostics),
            ))
          }),
        )
        let assert Ok(current) =
          unify.class(report.state, nominal.identity(class))
        let group_members =
          list.filter(current.methods, fn(method) {
            list.any(group, fn(source) { source.name.name == method.name.name })
          })
        let field_captures =
          variables(
            list.map(current.fields, fn(field) { field.type_ }),
            report.state,
          )
        let pending_constructor =
          scheme.free_variables(
            scheme.quantified(
              current.constructor,
              current.constructor_quantified,
            ),
            report.state,
          )
        let captured =
          set.union(set.union(captured, field_captures), pending_constructor)
        let group_variables =
          variables(
            list.map(group_members, fn(method) { method.type_ }),
            report.state,
          )
          |> set.difference(captured)
        let #(state, primitive_errors) =
          unify.settle_primitives(report.state, case deferred {
            True -> set.new()
            False -> group_variables
          })
        let methods =
          list.map(current.methods, fn(method) {
            case
              list.any(group_members, fn(member) {
                member.name.name == method.name.name
              })
            {
              False -> method
              True ->
                nominal.Method(..method, quantified: case deferred {
                  True -> []
                  False ->
                    variables([method.type_], state)
                    |> set.difference(captured)
                    |> set.to_list
                    |> list.sort(int.compare)
                })
            }
          })
        Ok(Report(
          unify.register_class(state, nominal.Class(..current, methods:)),
          list.append(report.diagnostics, primitive_errors),
        ))
      },
    ),
  )
  use <- bool.lazy_guard(deferred, fn() {
    let assert Ok(current) = unify.class(report.state, nominal.identity(class))
    Ok(Report(
      unify.register_class(
        report.state,
        nominal.Class(
          ..current,
          ready: True,
          constructor_quantified: [],
          methods: list.map(current.methods, fn(method) {
            nominal.Method(..method, quantified: [])
          }),
        ),
      ),
      report.diagnostics,
    ))
  })
  let all_types = [
    class.constructor,
    ..list.append(
      list.map(fields, fn(field) { field.type_ }),
      list.map(methods, fn(method) { method.type_ }),
    )
  ]
  let #(state, primitive_errors) =
    unify.settle_primitives(report.state, variables(all_types, report.state))
  let field_errors = case class.constructor == t.ErrorType {
    True -> []
    False ->
      list.filter_map(fields, fn(field) {
        case set.size(t.variables(unify.apply(field.type_, state))) > 0 {
          False -> Error(Nil)
          True ->
            Ok(
              diagnostic.error(
                "type.ambiguous_field",
                "field type cannot be determined",
              )
              |> diagnostic.primary(
                location.new(path, field.name.span),
                "this field still contains an unconstrained type variable",
              )
              |> diagnostic.help(
                "Annotate the field or declare a class type parameter to make its variability explicit.",
              ),
            )
        }
      })
  }
  let errors =
    list.flatten([report.diagnostics, primitive_errors, field_errors])
  let field_variables =
    variables(list.map(fields, fn(field) { field.type_ }), state)
  let methods =
    list.map(methods, fn(method) {
      nominal.Method(
        ..method,
        quantified: variables([method.type_], state)
          |> set.difference(field_variables)
          |> set.difference(captured)
          |> set.to_list
          |> list.sort(int.compare),
      )
    })
  let interface_errors =
    interface_infer.conformance(nominal.Class(..class, methods:), state, path)
  let errors = list.append(errors, interface_errors)
  let class = case diagnostic.has_errors(errors) {
    False ->
      nominal.Class(
        ..class,
        methods:,
        constructor_quantified: variables([class.constructor], state)
          |> set.difference(field_variables)
          |> set.difference(captured)
          |> set.to_list
          |> list.sort(int.compare),
      )
    True ->
      nominal.Class(
        ..class,
        constructor: t.ErrorType,
        fields: list.map(fields, fn(field) {
          nominal.Field(..field, type_: t.ErrorType)
        }),
        methods: list.map(methods, fn(method) {
          nominal.Method(..method, type_: t.ErrorType)
        }),
      )
  }
  Ok(Report(unify.register_class(state, class), errors))
}

fn signatures(
  class: nominal.Class,
  generics: dict.Dict(String, t.Type),
  state: unify.State,
  path: String,
) -> Result(
  #(
    List(nominal.Field),
    List(nominal.Method),
    #(t.Type, ast.Constructor),
    unify.State,
  ),
  infer.Unsupported,
) {
  use #(fields, methods, constructors, state) <- result.try(
    list.try_fold(class.source.members, #([], [], [], state), fn(acc, member) {
      let #(fields, methods, constructors, state) = acc
      case member {
        ast.FieldMember(field) -> {
          use #(type_, state) <- result.try(type_or_fresh(
            field.annotation,
            generics,
            state,
            path,
          ))
          Ok(#(
            [
              nominal.Field(
                field.name,
                type_,
                list.length(fields) + 2,
                nominal.identity(class),
              ),
              ..fields
            ],
            methods,
            constructors,
            state,
          ))
        }
        ast.MethodMember(method) -> {
          let names =
            list.append(
              optional_type_variables(method.return_type),
              list.flat_map(method.parameters, fn(parameter) {
                optional_type_variables(parameter.annotation)
              }),
            )
            |> list.unique
          let #(method_generics, state) =
            list.fold(names, #(generics, state), fn(acc, name) {
              case dict.has_key(acc.0, name) {
                True -> acc
                False -> {
                  let #(variable, state) = unify.fresh(acc.1)
                  #(dict.insert(acc.0, name, variable), state)
                }
              }
            })
          use #(type_, state) <- result.try(signature(
            method.parameters,
            method.return_type,
            method_generics,
            state,
            path,
          ))
          Ok(#(
            fields,
            [
              nominal.Method(method.name, type_, [], nominal.identity(class)),
              ..methods
            ],
            constructors,
            state,
          ))
        }
        ast.ConstructorMember(constructor) ->
          Ok(#(fields, methods, [constructor, ..constructors], state))
        ast.BehaviourMember(value) ->
          Error(infer.Unsupported(value.span, "behaviour in a class"))
      }
    }),
  )
  use constructor <- result.try(case constructors {
    [constructor] -> Ok(constructor)
    [] ->
      Ok(ast.Constructor(
        [],
        [],
        ast.Block([], class.source.span),
        class.source.span,
      ))
    _ -> Error(infer.Unsupported(class.source.span, "multiple constructors"))
  })
  use #(type_, state) <- result.try(signature(
    constructor.parameters,
    None,
    generics,
    state,
    path,
  ))
  let assert t.FunctionType(parameters, _) = type_
  Ok(#(
    list.reverse(fields),
    list.reverse(methods),
    #(t.FunctionType(parameters, nominal.type_(class)), constructor),
    state,
  ))
}

fn signature(
  parameters: List(ast.Parameter),
  returned: Option(ast.TypeAnnotation),
  generics: dict.Dict(String, t.Type),
  state: unify.State,
  path: String,
) -> Result(#(t.Type, unify.State), infer.Unsupported) {
  use #(parameters, state) <- result.try(
    list.try_fold(parameters, #([], state), fn(acc, parameter) {
      use #(type_, state) <- result.try(type_or_fresh(
        parameter.annotation,
        generics,
        acc.1,
        path,
      ))
      Ok(#([type_, ..acc.0], state))
    }),
  )
  use #(returned, state) <- result.try(type_or_fresh(
    returned,
    generics,
    state,
    path,
  ))
  Ok(#(t.FunctionType(list.reverse(parameters), returned), state))
}

fn type_or_fresh(
  annotation: Option(ast.TypeAnnotation),
  generics: dict.Dict(String, t.Type),
  state: unify.State,
  path: String,
) -> Result(#(t.Type, unify.State), infer.Unsupported) {
  case annotation {
    None -> Ok(unify.fresh(state))
    Some(annotation) ->
      infer.annotation_type(annotation, generics, state, path)
      |> result.map(fn(type_) { #(type_, state) })
  }
}

fn variables(types: List(t.Type), state: unify.State) -> set.Set(Int) {
  list.fold(types, set.new(), fn(found, type_) {
    set.union(found, t.variables(unify.apply(type_, state)))
  })
}

fn constrain(
  expected: t.Type,
  actual: t.Type,
  expected_span: Span,
  actual_span: Span,
  reason: String,
  report: Report,
  path: String,
) -> Report {
  case
    unify.unify(
      expected,
      actual,
      unify.Origin(
        location.new(path, expected_span),
        location.new(path, actual_span),
        reason,
      ),
      report.state,
    )
  {
    Ok(state) -> Report(..report, state:)
    Error(error) ->
      Report(
        ..report,
        diagnostics: list.append(report.diagnostics, [
          unify.to_diagnostic(error),
        ]),
      )
  }
}

pub fn entities(module: ast.Module) -> List(ast.Function) {
  let declarations =
    list.map(module.declarations, fn(declaration) {
      case declaration {
        ast.ActorDeclaration(actor) ->
          ast.ClassDeclaration(nominal.actor_class(actor))
        _ -> declaration
      }
    })
  list.filter_map(declarations, fn(declaration) {
    case declaration {
      ast.FunctionDeclaration(function) ->
        Ok(with_annotation_dependencies(function))
      ast.ClassDeclaration(class) -> {
        let expressions =
          list.flat_map(class.members, fn(member) {
            case member {
              ast.FieldMember(field) ->
                case field.value {
                  Some(value) -> [value]
                  None -> []
                }
              ast.MethodMember(method) -> [
                ast.AnonymousFunction(
                  method.parameters,
                  method.return_type,
                  method.body,
                  method.span,
                ),
              ]
              ast.ConstructorMember(constructor) -> [
                ast.AnonymousFunction(
                  constructor.parameters,
                  None,
                  constructor.body,
                  constructor.span,
                ),
              ]
              ast.BehaviourMember(_) -> []
            }
          })
        let bound_members =
          list.filter_map(class.members, fn(member) {
            case member {
              ast.FieldMember(field) ->
                Ok(ast.Parameter(
                  ast.NamedParameter(field.name.name),
                  None,
                  field.span,
                ))
              ast.MethodMember(method) ->
                Ok(ast.Parameter(
                  ast.NamedParameter(method.name.name),
                  None,
                  method.span,
                ))
              _ -> Error(Nil)
            }
          })
        let annotations =
          list.flat_map(class.members, fn(member) {
            case member {
              ast.FieldMember(field) -> optional_annotation(field.annotation)
              ast.MethodMember(method) -> function_annotations(method)
              ast.ConstructorMember(constructor) ->
                list.flat_map(constructor.parameters, fn(parameter) {
                  optional_annotation(parameter.annotation)
                })
              ast.BehaviourMember(_) -> []
            }
          })

        let parent =
          list.append(
            optional_annotation(class.superclass),
            list.flat_map(class.interfaces, fn(annotation) {
              optional_annotation(Some(annotation))
            }),
          )
        let statements =
          list.map(
            list.flatten([parent, annotations, expressions]),
            ast.ExpressionStatement,
          )
        Ok(ast.Function(
          [],
          class.name,
          [],
          None,
          ast.Block(
            [
              ast.ExpressionStatement(ast.AnonymousFunction(
                bound_members,
                None,
                ast.Block(statements, class.span),
                class.span,
              )),
            ],
            class.span,
          ),
          class.span,
        ))
      }
      _ -> Error(Nil)
    }
  })
}

fn with_annotation_dependencies(function: ast.Function) -> ast.Function {
  ast.Function(
    ..function,
    body: ast.Block(
      ..function.body,
      statements: list.append(
        list.map(function_annotations(function), ast.ExpressionStatement),
        function.body.statements,
      ),
    ),
  )
}

fn function_annotations(function: ast.Function) -> List(ast.Expression) {
  list.append(
    optional_annotation(function.return_type),
    list.flat_map(function.parameters, fn(parameter) {
      optional_annotation(parameter.annotation)
    }),
  )
}

fn optional_annotation(
  value: Option(ast.TypeAnnotation),
) -> List(ast.Expression) {
  case value {
    Some(value) -> annotation_dependencies(value)
    None -> []
  }
}

fn annotation_dependencies(value: ast.TypeAnnotation) -> List(ast.Expression) {
  case value {
    ast.NamedType(None, name, arguments, span) -> [
      ast.TypeName(name, span),
      ..list.flat_map(arguments, annotation_dependencies)
    ]
    ast.NamedType(Some(_), _, arguments, _) | ast.TupleType(arguments, _) ->
      list.flat_map(arguments, annotation_dependencies)
    ast.FunctionType(parameters, result, _) ->
      list.flat_map([result, ..parameters], annotation_dependencies)
    ast.TypeVariable(..) -> []
  }
}

fn optional_type_variables(
  annotation: Option(ast.TypeAnnotation),
) -> List(String) {
  case annotation {
    None -> []
    Some(value) -> type_variables(value)
  }
}

fn type_variables(value: ast.TypeAnnotation) -> List(String) {
  case value {
    ast.TypeVariable(name, _) -> [name]
    ast.NamedType(arguments:, ..) | ast.TupleType(elements: arguments, ..) ->
      list.flat_map(arguments, type_variables)
    ast.FunctionType(parameters, result, _) ->
      list.flat_map([result, ..parameters], type_variables)
  }
}

fn superclass(
  class: nominal.Class,
  generics: dict.Dict(String, t.Type),
  state: unify.State,
  path: String,
) -> Result(
  #(Option(#(nominal.Class, List(t.Type))), unify.State),
  infer.Unsupported,
) {
  case class.superclass, class.source.superclass {
    Some(link), Some(annotation) -> {
      use type_ <- result.try(infer.annotation_type(
        annotation,
        generics,
        state,
        path,
      ))
      use parent <- result.try(
        unify.class(state, link.identity)
        |> result.map_error(fn(_) {
          infer.Unsupported(
            ast.type_span(annotation),
            "unregistered superclass",
          )
        }),
      )
      case parent.ready, type_ {
        True, t.Nominal(arguments:, ..) ->
          Ok(#(Some(#(parent, arguments)), state))
        False, _ ->
          Error(infer.Unsupported(
            ast.type_span(annotation),
            "a superclass that depends on its own subclasses",
          ))
        True, _ ->
          Error(infer.Unsupported(ast.type_span(annotation), "superclass type"))
      }
    }
    _, _ -> Ok(#(None, state))
  }
}

fn inherit(
  parent: nominal.Class,
  arguments: List(t.Type),
  fields: List(nominal.Field),
  methods: List(nominal.Method),
  state: unify.State,
  path: String,
) -> #(List(nominal.Field), List(nominal.Method), unify.State, List(Diagnostic)) {
  let view = fn(type_) {
    nominal.instantiate(unify.apply(type_, state), parent, arguments)
  }
  let inherited_fields =
    list.map(parent.fields, fn(field) {
      nominal.Field(..field, type_: view(field.type_))
    })
  let redeclared =
    list.filter_map(fields, fn(field) {
      case
        list.find(inherited_fields, fn(inherited) {
          inherited.name.name == field.name.name
          && !string.starts_with(inherited.name.name, "_")
        })
      {
        Error(Nil) -> Error(Nil)
        Ok(inherited) ->
          Ok(
            diagnostic.error(
              "type.inherited_field_redeclared",
              "field is already inherited",
            )
            |> diagnostic.primary(
              location.new(path, field.name.span),
              "`" <> field.name.name <> "` is declared again here",
            )
            |> diagnostic.secondary(
              location.new(path, inherited.name.span),
              "inherited from `" <> inherited.owner.1 <> "`",
            )
            |> diagnostic.conclusion(
              "Classes are immutable values, so a subclass cannot replace an inherited field.",
            ),
          )
      }
    })

  let offset = list.length(inherited_fields)
  let own_fields =
    list.map(fields, fn(field) {
      nominal.Field(..field, index: field.index + offset)
    })
  let visible =
    list.filter(parent.methods, fn(method) {
      !string.starts_with(method.name.name, "_")
    })
  let #(state, override_errors) =
    list.fold(methods, #(state, []), fn(acc, method) {
      let #(state, errors) = acc
      case
        list.find(visible, fn(inherited) {
          inherited.name.name == method.name.name
        })
      {
        Error(Nil) -> acc
        Ok(inherited) -> {
          let expected = view(inherited.type_)
          let origin =
            unify.Origin(
              location.new(path, inherited.name.span),
              location.new(path, method.name.span),
              "An overriding method must have the type of the method it overrides.",
            )
          case unify.unify(expected, method.type_, origin, state) {
            Ok(state) -> #(state, errors)
            Error(_) -> #(state, [
              override_error(inherited, expected, method, state, path),
              ..errors
            ])
          }
        }
      }
    })
  let inherited_methods =
    list.filter_map(visible, fn(inherited) {
      case list.any(methods, fn(own) { own.name.name == inherited.name.name }) {
        True -> Error(Nil)
        False -> Ok(nominal.Method(..inherited, type_: view(inherited.type_)))
      }
    })
  #(
    list.append(inherited_fields, own_fields),
    list.append(inherited_methods, methods),
    state,
    list.append(redeclared, list.reverse(override_errors)),
  )
}

fn override_error(
  inherited: nominal.Method,
  expected: t.Type,
  method: nominal.Method,
  state: unify.State,
  path: String,
) -> Diagnostic {
  let #(expected, found) =
    t.format_pair(
      unify.apply(expected, state),
      unify.apply(method.type_, state),
    )
  diagnostic.error("type.incompatible_override", "incompatible method override")
  |> diagnostic.secondary(
    location.new(path, inherited.name.span),
    "inherited method",
  )
  |> diagnostic.primary(
    location.new(path, method.name.span),
    "overriding method",
  )
  |> diagnostic.conclusion("Expected: " <> expected <> "\n   Found: " <> found)
}

pub fn publish(
  class: nominal.Class,
  environment: infer.Environment,
  state: unify.State,
  path: String,
) -> Report {
  let captured =
    list.fold(
      infer.environment_schemes(environment),
      set.new(),
      fn(found, value) { set.union(found, scheme.free_variables(value, state)) },
    )
  let storage =
    variables(list.map(class.fields, fn(field) { field.type_ }), state)
  let captured = set.union(captured, storage)
  let quantify = fn(type_) {
    variables([type_], state)
    |> set.difference(captured)
    |> set.to_list
    |> list.sort(int.compare)
  }
  let methods =
    list.map(class.methods, fn(method) {
      nominal.Method(..method, quantified: quantify(method.type_))
    })
  let class =
    nominal.Class(
      ..class,
      methods:,
      constructor_quantified: quantify(class.constructor),
    )
  let field_errors = case class.constructor == t.ErrorType {
    True -> []
    False ->
      list.filter_map(class.fields, fn(field) {
        case set.size(t.variables(unify.apply(field.type_, state))) > 0 {
          False -> Error(Nil)
          True ->
            Ok(
              diagnostic.error(
                "type.ambiguous_field",
                "field type cannot be determined",
              )
              |> diagnostic.primary(
                location.new(path, field.name.span),
                "Annotate this field or declare a class type parameter.",
              ),
            )
        }
      })
  }
  let errors =
    list.append(field_errors, interface_infer.conformance(class, state, path))
  Report(unify.register_class(state, class), errors)
}

fn constructor_policy(
  class: nominal.Class,
  parent: Option(#(nominal.Class, List(t.Type))),
  state: unify.State,
  path: String,
) -> List(Diagnostic) {
  case nominal.has_constructor(class) {
    True -> []
    False -> {
      let missing =
        list.filter_map(class.source.members, fn(member) {
          case member {
            ast.FieldMember(field) if field.value == None -> Ok(field.name)
            _ -> Error(Nil)
          }
        })
      let fields = case missing {
        [] -> []
        _ -> [
          list.fold(
            missing,
            diagnostic.error(
              "type.missing_constructor",
              "fields require an explicit constructor",
            )
              |> diagnostic.primary(
                location.new(path, class.source.name.span),
                "A zero-argument implicit constructor cannot initialize these fields.",
              ),
            fn(error, name) {
              diagnostic.secondary(
                error,
                location.new(path, name.span),
                "`" <> name.name <> "` has no default initializer",
              )
            },
          )
          |> diagnostic.help(
            "Declare new(...) and initialize each field exactly once using self.field = value.",
          ),
        ]
      }
      let inherited = case parent {
        None -> []
        Some(#(parent, _)) ->
          case unify.apply(parent.constructor, state) {
            t.FunctionType([_, ..] as parameters, _) -> [
              diagnostic.error(
                "type.missing_super_constructor",
                "parent constructor requires explicit arguments",
              )
              |> diagnostic.primary(
                location.new(path, class.source.name.span),
                "This subclass has no constructor to supply the parent's arguments.",
              )
              |> diagnostic.secondary(
                location.new(parent.path, parent.source.name.span),
                "The parent constructor requires "
                  <> int.to_string(list.length(parameters))
                  <> case parameters {
                  [_] -> " argument."
                  _ -> " arguments."
                },
              )
              |> diagnostic.help(
                "Declare new(...) in the subclass and call super.new(...) with the required arguments.",
              ),
            ]
            _ -> []
          }
      }
      list.append(fields, inherited)
    }
  }
}
