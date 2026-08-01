//// Check a module in dependency order, not merely reading order.
////
//// Prepare recursive function/class groups, infer their bodies and publish
//// validated schemes. Fully annotated helpers keep independent generic signatures
//// while the group's implementation is still being checked.
////
//// ```text
//// class method -> generic factory -> class constructor -> one checked component
//// ```
////
//// Declaration order is not a reliable checking order. A closure near the top
//// may call a function whose pattern mentions a class near the bottom. The
//// function-group graph carries that edge, including pattern-only references.
////
//// For a recursive component, prepare identities and class schemas first, check
//// bodies against provisional or independently quantified signatures next, and
//// publish generalized schemes only after the component's checks have settled.
//// A failed component publishes error types rather than an attractive but invalid
//// signature that would mislead every later caller.
////
//// This is why the class registry distinguishes registered from prepared metadata.
//// An empty field list on an unprepared class is not evidence of a zero-field
//// class, and an annotated generic factory is not a monomorphic capture.

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/function_group
import compiler/parser/ast
import compiler/typesystem/class_infer
import compiler/typesystem/infer
import compiler/typesystem/interface_infer
import compiler/typesystem/monotype.{type Type}
import compiler/typesystem/nominal
import compiler/typesystem/scheme.{type Scheme}
import compiler/typesystem/unify
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import utilities/location

pub type Function {
  Function(name: ast.Name, type_: Type, scheme: Scheme)
}

pub type Module {
  Module(
    functions: List(Function),
    externals: List(Namespace),
    state: unify.State,
    diagnostics: List(Diagnostic),
  )
}

pub type Namespace {
  Namespace(
    name: ast.Name,
    language: ast.ForeignLanguage,
    module: String,
    functions: List(Function),
  )
}

type Progress {
  Progress(
    environment: infer.Environment,
    functions: Dict(String, Function),
    externals: List(Namespace),
    state: unify.State,
    diagnostics: List(Diagnostic),
  )
}

/// Register nominal identities, order declaration components and check each
/// component before publishing the module report.
///
/// ```text
/// source reading order may differ from dependency checking order
/// ```
pub fn infer(
  module: ast.Module,
  environment: infer.Environment,
  state: unify.State,
  path: String,
) -> Result(Module, infer.Unsupported) {
  use Nil <- result.try(
    list.try_each(module.declarations, fn(value) {
      case value {
        ast.ClassDeclaration(_) -> Ok(Nil)
        ast.ActorDeclaration(_) -> Ok(Nil)
        ast.InterfaceDeclaration(_) -> Ok(Nil)
        ast.EnumDeclaration(_) -> Ok(Nil)
        ast.FunctionDeclaration(_)
        | ast.ExternalDeclaration(_)
        | ast.TestDeclaration(_) -> Ok(Nil)
      }
    }),
  )
  let identity = class_infer.module_identity(path)

  let state = register_enums(module, identity, path, state)
  let state = class_infer.register(module, state, path)
  let state = interface_infer.register(module, identity, path, state)
  use state <- result.try(interface_infer.check(identity, path, state))
  let environment =
    list.fold(
      unify.interfaces_in(state, identity),
      environment,
      fn(environment, interface) {
        dict.insert(
          environment,
          interface.source.name.name,
          infer.InterfaceBinding(#(interface.module, interface.source.name.name)),
        )
      },
    )
  let environment =
    list.fold(
      unify.classes_in(state, class_infer.module_identity(path)),
      environment,
      fn(environment, class) {
        dict.insert(
          environment,
          class.source.name.name,
          infer.ClassBinding(#(class.module, class.source.name.name)),
        )
      },
    )
  let environment =
    list.fold(
      unify.enums_in(state, identity),
      environment,
      fn(environment, enum) {
        dict.insert(
          environment,
          enum.source.name.name,
          infer.EnumBinding(nominal.enum_identity(enum)),
        )
      },
    )
  let functions =
    list.filter_map(module.declarations, fn(value) {
      case value {
        ast.FunctionDeclaration(value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  use initial <- result.try(
    list.try_fold(
      module.declarations,
      Progress(environment, dict.new(), [], state, []),
      fn(progress, value) {
        case value {
          ast.ExternalDeclaration(external) -> {
            use #(namespace, state) <- result.try(infer_namespace(
              external,
              progress,
              path,
            ))
            let schemes =
              namespace.functions
              |> list.map(fn(function) {
                #(function.name.name, function.scheme)
              })
              |> dict.from_list
            Ok(
              Progress(
                ..progress,
                environment: dict.insert(
                  progress.environment,
                  external.name.name,
                  infer.NamespaceBinding(external.name.name, schemes),
                ),
                externals: [namespace, ..progress.externals],
                state:,
                diagnostics: list.append(
                  progress.diagnostics,
                  native_types(external, namespace, path),
                ),
              ),
            )
          }
          _ -> Ok(progress)
        }
      },
    ),
  )
  use progress <- result.try(
    list.try_fold(
      function_group.groups(class_infer.entities(module)),
      initial,
      fn(progress, group) {
        let classes =
          list.filter_map(module.declarations, fn(declaration) {
            case declaration {
              ast.ActorDeclaration(actor) -> {
                let class = nominal.actor_class(actor)
                case
                  list.any(group, fn(entity) {
                    entity.name.name == class.name.name
                  })
                {
                  True -> Ok(class)
                  False -> Error(Nil)
                }
              }
              ast.ClassDeclaration(class) ->
                case
                  list.any(group, fn(entity) {
                    entity.name.name == class.name.name
                  })
                {
                  True -> Ok(class)
                  False -> Error(Nil)
                }
              _ -> Error(Nil)
            }
          })
        case classes, group {
          [], _ -> {
            let originals =
              list.filter(functions, fn(function) {
                list.any(group, fn(entity) {
                  entity.name.name == function.name.name
                })
              })
            infer_group(originals, progress, path)
          }
          [class], [_] -> {
            use checked <- result.try(class_infer.check(
              class,
              progress.environment,
              progress.state,
              path,
            ))
            Ok(
              Progress(
                ..progress,
                state: checked.state,
                diagnostics: list.append(
                  progress.diagnostics,
                  checked.diagnostics,
                ),
              ),
            )
          }
          [_, ..], _ -> {
            let originals =
              list.filter(functions, fn(function) {
                list.any(group, fn(entity) {
                  entity.name.name == function.name.name
                })
              })
            infer_nominal_group(classes, originals, progress, path)
          }
        }
      },
    ),
  )
  use progress <- result.try(
    list.try_fold(module.declarations, progress, fn(progress, value) {
      case value {
        ast.TestDeclaration(source_test) -> {
          use report <- result.try(infer.infer_test(
            source_test,
            progress.environment,
            progress.state,
            path,
          ))
          Ok(
            Progress(
              ..progress,
              state: report.state,
              diagnostics: list.append(progress.diagnostics, report.diagnostics),
            ),
          )
        }
        _ -> Ok(progress)
      }
    }),
  )
  let #(state, primitive_errors) =
    unify.settle_primitives(
      progress.state,
      unify.pending_variables(progress.state),
    )
  let progress =
    Progress(
      ..progress,
      state:,
      diagnostics: list.append(progress.diagnostics, primitive_errors),
    )
  let functions =
    list.filter_map(module.declarations, fn(value) {
      use name <- result.try(ast.declaration_name(value))
      dict.get(progress.functions, name.name)
      |> result.map(fn(value) {
        Function(..value, type_: unify.apply(value.type_, progress.state))
      })
    })
  Ok(Module(
    functions,
    list.reverse(progress.externals),
    progress.state,
    diagnostic.sort(progress.diagnostics),
  ))
}

/// Decode and validate the callable contracts declared by a foreign namespace.
///
/// ```text
/// external namespace -> named function schemes
/// ```
fn infer_namespace(
  external: ast.External,
  progress: Progress,
  path: String,
) -> Result(#(Namespace, unify.State), infer.Unsupported) {
  let schemes = infer.environment_schemes(progress.environment)
  use #(functions, state) <- result.try(
    list.try_fold(external.functions, #([], progress.state), fn(acc, function) {
      let #(found, state) = acc
      use report <- result.try(infer.infer_external_function(
        function,
        state,
        path,
      ))
      let generalized = scheme.generalize(report.type_, schemes, report.state)
      Ok(#(
        [Function(function.name, report.type_, generalized), ..found],
        report.state,
      ))
    }),
  )
  Ok(#(
    Namespace(
      external.name,
      external.language,
      external.module,
      list.reverse(functions),
    ),
    state,
  ))
}

/// Check whether native-component signatures fit the supported native-value
/// boundary.
///
/// ```text
/// native signature -> permitted value shapes or diagnostics
/// ```
fn native_types(
  external: ast.External,
  namespace: Namespace,
  path: String,
) -> List(Diagnostic) {
  case external.language {
    ast.Native ->
      list.zip(external.functions, namespace.functions)
      |> list.flat_map(fn(pair) {
        let #(source, function) = pair
        case function.type_ {
          monotype.FunctionType(parameters, result) -> {
            let annotations =
              list.filter_map(source.parameters, fn(parameter) {
                option.to_result(parameter.annotation, Nil)
              })
            list.zip([source.return_type, ..annotations], [result, ..parameters])
            |> list.filter(fn(written) { !native_compatible(written.1) })
            |> list.map(fn(written) {
              diagnostic.error(
                "native.unsupported_type",
                "unsupported native type",
              )
              |> diagnostic.primary(
                location.new(path, ast.type_span(written.0)),
                "`"
                  <> monotype.to_string(written.1)
                  <> "` cannot cross the native boundary",
              )
              |> diagnostic.conclusion(
                "Native functions accept and return `Int`, `Float`, `Bool`, `String`, `BitArray` and `Nil`, and lists and tuples of these.",
              )
              |> diagnostic.help(
                "Convert the value to one of these types on the Pooka side of the call.",
              )
            })
          }
          _ -> []
        }
      })
    _ -> []
  }
}

fn native_compatible(value: Type) -> Bool {
  case value {
    monotype.IntType
    | monotype.FloatType
    | monotype.BoolType
    | monotype.StringType
    | monotype.BitArrayType
    | monotype.NilType
    | monotype.ErrorType -> True
    monotype.ListType(element) -> native_compatible(element)
    monotype.TupleType(elements) -> list.all(elements, native_compatible)
    _ -> False
  }
}

/// Infer a function component whose declarations can refer recursively to one
/// another.
///
/// ```text
/// even -> odd -> even -> one recursive function component
/// ```
fn infer_group(
  group: List(ast.Function),
  progress: Progress,
  path: String,
) -> Result(Progress, infer.Unsupported) {
  infer_group_from(group, progress, path, False)
}

/// Maintain provisional signatures while checking a group, then generalize only
/// after the group's constraints settle.
///
/// ```text
/// recursive uses share provisional types; published schemes are checked afterward
/// ```
fn infer_group_from(
  group: List(ast.Function),
  progress: Progress,
  path: String,
  predeclared: Bool,
) -> Result(Progress, infer.Unsupported) {
  let #(locals, provisional, state) =
    list.fold(
      group,
      #(progress.environment, dict.new(), progress.state),
      fn(acc, function) {
        let #(locals, provisional, state) = acc

        let declared = infer.declared_scheme(function, state, path)
        let #(binding, type_, state) = case declared {
          Some(#(signature, state)) -> {
            let #(type_, state) = scheme.instantiate(signature, state)
            #(signature, type_, state)
          }
          None -> {
            let #(type_, state) = case
              predeclared,
              dict.get(locals, function.name.name)
            {
              True, Ok(infer.Binding(signature, _)) ->
                scheme.instantiate(signature, state)
              _, _ -> unify.fresh(state)
            }
            #(scheme.monomorphic(type_), type_, state)
          }
        }
        #(
          dict.insert(
            locals,
            function.name.name,
            infer.Binding(binding, function.name.span),
          ),
          dict.insert(provisional, function.name.name, type_),
          state,
        )
      },
    )
  use #(state, reports, diagnostics) <- result.try(
    list.try_fold(group, #(state, dict.new(), []), fn(acc, function) {
      let #(state, reports, diagnostics) = acc
      use report <- result.try(infer.infer_function(
        function,
        locals,
        state,
        path,
      ))
      let expected = case dict.get(provisional, function.name.name) {
        Ok(value) -> value
        Error(Nil) -> monotype.ErrorType
      }
      let origin =
        unify.Origin(
          location.new(path, function.name.span),
          location.new(path, function.span),
          "Recursive uses must agree with this function's inferred signature.",
        )
      let #(state, errors) = case
        unify.unify(expected, report.type_, origin, report.state)
      {
        Ok(state) -> #(state, report.diagnostics)
        Error(error) -> #(
          report.state,
          list.append(report.diagnostics, [unify.to_diagnostic(error)]),
        )
      }
      let type_ = case diagnostic.has_errors(errors) {
        True -> monotype.ErrorType
        False -> report.type_
      }
      Ok(#(
        state,
        dict.insert(reports, function.name.name, type_),
        list.append(diagnostics, errors),
      ))
    }),
  )
  use #(state, reports, diagnostics) <- result.try(
    list.try_fold(group, #(state, reports, diagnostics), fn(acc, function) {
      let #(state, reports, diagnostics) = acc
      let actual = case dict.get(reports, function.name.name) {
        Ok(value) -> unify.apply(value, state)
        Error(Nil) -> monotype.ErrorType
      }
      use checked <- result.try(case predeclared {
        True -> Ok(infer.Inferred(actual, state, []))
        False -> infer.validate_signature(function, actual, state, path)
      })
      let actual = case diagnostic.has_errors(checked.diagnostics) {
        True -> monotype.ErrorType
        False -> actual
      }
      Ok(#(
        checked.state,
        dict.insert(reports, function.name.name, actual),
        list.append(diagnostics, checked.diagnostics),
      ))
    }),
  )
  let environment_schemes = infer.environment_schemes(progress.environment)
  let environment_variables =
    list.fold(environment_schemes, set.new(), fn(found, value) {
      set.union(found, scheme.free_variables(value, state))
    })
  let group_variables =
    dict.values(reports)
    |> list.fold(set.new(), fn(found, value) {
      set.union(found, monotype.variables(unify.apply(value, state)))
    })
  let #(state, primitive_errors) =
    unify.settle_primitives(
      state,
      set.difference(group_variables, environment_variables),
    )
  let reports = case
    diagnostic.has_errors(list.append(diagnostics, primitive_errors))
  {
    True -> dict.map_values(reports, fn(_, _) { monotype.ErrorType })
    False -> reports
  }
  let diagnostics = list.append(diagnostics, primitive_errors)
  let #(environment, functions) =
    list.fold(
      group,
      #(progress.environment, progress.functions),
      fn(acc, function) {
        let #(environment, functions) = acc
        let type_ = case dict.get(reports, function.name.name) {
          Ok(value) -> unify.apply(value, state)
          Error(Nil) -> monotype.ErrorType
        }
        let generalized = scheme.generalize(type_, environment_schemes, state)
        #(
          dict.insert(
            environment,
            function.name.name,
            infer.Binding(generalized, function.name.span),
          ),
          dict.insert(
            functions,
            function.name.name,
            Function(function.name, type_, generalized),
          ),
        )
      },
    )
  Ok(Progress(
    environment,
    functions,
    progress.externals,
    state,
    list.append(progress.diagnostics, diagnostics),
  ))
}

/// Prepare participating classes before checking their methods, constructors and
/// recursive functions. Fully annotated factories retain independent quantified
/// schemes.
///
/// ```text
/// Box.map -> make -> Box constructor -> one prepared and checked component
/// ```
fn infer_nominal_group(
  classes: List(ast.Class),
  functions: List(ast.Function),
  outer: Progress,
  path: String,
) -> Result(Progress, infer.Unsupported) {
  let classes =
    list.sort(classes, fn(a, b) {
      let assert Ok(a) = unify.named_class(outer.state, path, "", a.name.name)
      let assert Ok(b) = unify.named_class(outer.state, path, "", b.name.name)
      int.compare(
        list.length(unify.ancestors(outer.state, nominal.identity(a))),
        list.length(unify.ancestors(outer.state, nominal.identity(b))),
      )
    })
  use #(prepared, state) <- result.try(
    list.try_fold(classes, #([], outer.state), fn(acc, source) {
      use #(prepared, state) <- result.try(class_infer.prepare(
        source,
        acc.1,
        path,
      ))
      let assert Ok(class) =
        unify.named_class(state, path, "", source.name.name)
      Ok(#(
        list.append(acc.0, [#(source, prepared)]),
        unify.register_class(state, nominal.Class(..class, ready: True)),
      ))
    }),
  )
  let #(environment, state) =
    list.fold(functions, #(outer.environment, state), fn(acc, function) {
      let #(signature, state) = case
        infer.declared_scheme(function, acc.1, path)
      {
        Some(value) -> value
        None -> {
          let #(type_, state) = unify.fresh(acc.1)
          #(scheme.monomorphic(type_), state)
        }
      }
      #(
        dict.insert(
          acc.0,
          function.name.name,
          infer.Binding(signature, function.name.span),
        ),
        state,
      )
    })

  let environment =
    list.fold(classes, environment, fn(environment, source) {
      let assert Ok(class) =
        unify.named_class(state, path, "", source.name.name)
      let types = [
        class.constructor,
        ..list.append(
          list.map(class.fields, fn(field) { field.type_ }),
          list.map(class.methods, fn(method) { method.type_ }),
        )
      ]
      dict.insert(
        environment,
        "$recursive@" <> source.name.name,
        infer.Binding(
          scheme.monomorphic(monotype.TupleType(types)),
          source.name.span,
        ),
      )
    })
  use progress <- result.try(
    list.try_fold(
      prepared,
      Progress(..outer, state:, environment:),
      fn(progress, item) {
        use report <- result.try(class_infer.check_prepared(
          item.0,
          item.1,
          progress.environment,
          progress.state,
          path,
          True,
        ))
        Ok(
          Progress(
            ..progress,
            state: report.state,
            diagnostics: list.append(progress.diagnostics, report.diagnostics),
          ),
        )
      },
    ),
  )
  use progress <- result.try(infer_group_from(functions, progress, path, True))
  let schemas =
    list.map(classes, fn(source) {
      let assert Ok(class) =
        unify.named_class(progress.state, path, "", source.name.name)
      class
    })
  let storage =
    list.flat_map(schemas, fn(class) {
      list.map(class.fields, fn(field) { scheme.monomorphic(field.type_) })
    })
  let outer_schemes =
    list.append(infer.environment_schemes(outer.environment), storage)
  let captured =
    list.fold(outer_schemes, set.new(), fn(found, signature) {
      set.union(found, scheme.free_variables(signature, progress.state))
    })
  let all_types =
    list.flatten([
      list.flat_map(schemas, fn(class) {
        [
          class.constructor,
          ..list.append(
            list.map(class.fields, fn(field) { field.type_ }),
            list.map(class.methods, fn(method) { method.type_ }),
          )
        ]
      }),
      list.filter_map(functions, fn(source) {
        dict.get(progress.functions, source.name.name)
        |> result.map(fn(function) { function.type_ })
      }),
    ])
  let variables =
    list.fold(all_types, set.new(), fn(found, type_) {
      set.union(found, monotype.variables(unify.apply(type_, progress.state)))
    })
  let #(state, primitive_errors) =
    unify.settle_primitives(progress.state, set.difference(variables, captured))
  let generalization_environment =
    list.index_fold(
      storage,
      outer.environment,
      fn(environment, signature, index) {
        dict.insert(
          environment,
          "$storage@" <> int.to_string(index),
          infer.Binding(signature, case classes {
            [first, ..] -> first.name.span
            [] -> panic
          }),
        )
      },
    )
  let published =
    list.fold(
      schemas,
      class_infer.Report(state, primitive_errors),
      fn(acc, class) {
        let report =
          class_infer.publish(
            class,
            generalization_environment,
            acc.state,
            path,
          )
        class_infer.Report(
          report.state,
          list.append(acc.diagnostics, report.diagnostics),
        )
      },
    )
  let class_parameters =
    list.flat_map(schemas, fn(class) {
      list.map(class.parameters, fn(parameter) { parameter.0 })
    })
  use #(environment, inferred_functions, state, signature_errors) <- result.try(
    list.try_fold(
      functions,
      #(outer.environment, progress.functions, published.state, []),
      fn(acc, source) {
        let assert Ok(function) = dict.get(progress.functions, source.name.name)

        let #(mapping, state) =
          list.fold(class_parameters, #(dict.new(), acc.2), fn(acc, id) {
            let #(variable, state) = unify.fresh(acc.1)
            #(dict.insert(acc.0, id, variable), state)
          })
        let type_ =
          monotype.replace_rigids(unify.apply(function.type_, state), mapping)
        use checked <- result.try(infer.validate_signature(
          source,
          type_,
          state,
          path,
        ))
        let signature = scheme.generalize(type_, outer_schemes, checked.state)
        Ok(#(
          dict.insert(
            acc.0,
            source.name.name,
            infer.Binding(signature, source.name.span),
          ),
          dict.insert(
            acc.1,
            source.name.name,
            Function(source.name, type_, signature),
          ),
          checked.state,
          list.append(acc.3, checked.diagnostics),
        ))
      },
    ),
  )

  let component_errors =
    list.flatten([
      list.drop(progress.diagnostics, list.length(outer.diagnostics)),
      published.diagnostics,
      signature_errors,
    ])
  let #(environment, inferred_functions, state) = case
    diagnostic.has_errors(component_errors)
  {
    False -> #(environment, inferred_functions, state)
    True -> {
      let state =
        list.fold(schemas, state, fn(state, class) {
          let assert Ok(current) = unify.class(state, nominal.identity(class))
          unify.register_class(
            state,
            nominal.Class(
              ..current,
              constructor: monotype.ErrorType,
              fields: list.map(current.fields, fn(field) {
                nominal.Field(..field, type_: monotype.ErrorType)
              }),
              methods: list.map(current.methods, fn(method) {
                nominal.Method(..method, type_: monotype.ErrorType)
              }),
            ),
          )
        })
      let #(environment, inferred_functions) =
        list.fold(
          functions,
          #(environment, inferred_functions),
          fn(acc, source) {
            let signature = scheme.monomorphic(monotype.ErrorType)
            #(
              dict.insert(
                acc.0,
                source.name.name,
                infer.Binding(signature, source.name.span),
              ),
              dict.insert(
                acc.1,
                source.name.name,
                Function(source.name, monotype.ErrorType, signature),
              ),
            )
          },
        )
      #(environment, inferred_functions, state)
    }
  }
  Ok(
    Progress(
      ..progress,
      environment:,
      functions: inferred_functions,
      state:,
      diagnostics: list.flatten([
        progress.diagnostics,
        published.diagnostics,
        signature_errors,
      ]),
    ),
  )
}

/// Register enum identities and visible type bindings before expression inference
/// needs their variants.
///
/// ```text
/// enum Order -> resolvable Order identity before checking Order.Less
/// ```
fn register_enums(
  module: ast.Module,
  identity: String,
  path: String,
  state: unify.State,
) -> unify.State {
  list.fold(module.declarations, state, fn(state, declaration) {
    case declaration {
      ast.EnumDeclaration(source) -> {
        let enum = nominal.Enum(identity, path, source)
        state
        |> unify.register_enum(enum)
        |> unify.bind_type(
          path,
          "",
          source.name.name,
          nominal.enum_identity(enum),
        )
      }
      _ -> state
    }
  })
}
