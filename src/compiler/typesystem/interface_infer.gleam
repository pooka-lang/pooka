//// An interface is a list of promises, not an object layout.
////
//// Register interface requirements and check declared implementations against
//// their signatures. Inherited implementations and generic substitutions must
//// agree before dispatch can rely on the contract.
////
//// ```text
//// class User with Named -> User must satisfy name() -> String
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import compiler/typesystem/infer
import compiler/typesystem/monotype as t
import compiler/typesystem/nominal
import compiler/typesystem/scheme
import compiler/typesystem/unify
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import utilities/location

/// Reserve interface identities and their written requirements before
/// implementations are checked.
///
/// ```text
/// Named.name() -> String -> interface requirement metadata
/// ```
pub fn register(
  module: ast.Module,
  identity: String,
  path: String,
  state: unify.State,
) -> unify.State {
  list.fold(module.declarations, state, fn(state, declaration) {
    case declaration {
      ast.InterfaceDeclaration(source) -> {
        let #(parameters, state) =
          list.fold(source.type_parameters, #([], state), fn(acc, name) {
            let #(id, type_, state) = unify.fresh_rigid(name.name, acc.1)
            #(list.append(acc.0, [#(id, type_)]), state)
          })
        let interface =
          nominal.Interface(identity, path, source, parameters, [])
        state
        |> unify.register_interface(interface)
        |> unify.bind_type(path, "", source.name.name, #(
          identity,
          source.name.name,
        ))
      }
      _ -> state
    }
  })
}

/// Resolve registered interface requirements in the module context.
///
/// ```text
/// unknown type inside an interface contract -> annotation diagnostic
/// ```
pub fn check(
  identity: String,
  path: String,
  state: unify.State,
) -> Result(unify.State, infer.Unsupported) {
  list.try_fold(
    unify.interfaces_in(state, identity),
    state,
    fn(state, interface) {
      let generics =
        list.zip(interface.source.type_parameters, interface.parameters)
        |> list.map(fn(pair) { #(pair.0.name, pair.1.1) })
        |> dict.from_list
      use #(methods, state) <- result.try(
        list.try_fold(
          interface.source.requirements,
          #([], state),
          fn(acc, requirement) {
            let names =
              list.flatten([
                variables(requirement.return_type),
                list.flat_map(requirement.parameters, fn(p) {
                  variables(p.annotation)
                }),
              ])
              |> list.unique
            let #(generics, state, quantified) =
              list.fold(names, #(generics, acc.1, []), fn(acc, name) {
                case dict.has_key(acc.0, name) {
                  True -> acc
                  False -> {
                    let #(variable, state) = unify.fresh(acc.1)
                    let assert t.Variable(id) = variable
                    #(dict.insert(acc.0, name, variable), state, [id, ..acc.2])
                  }
                }
              })
            use parameters <- result.try(
              list.try_map(requirement.parameters, fn(parameter) {
                use annotation <- result.try(case parameter.annotation {
                  Some(annotation) -> Ok(annotation)
                  None ->
                    Error(infer.Unsupported(
                      parameter.span,
                      "an interface parameter needs a type annotation",
                    ))
                })
                infer.annotation_type(annotation, generics, state, path)
              }),
            )
            use annotation <- result.try(case requirement.return_type {
              Some(annotation) -> Ok(annotation)
              None ->
                Error(infer.Unsupported(
                  requirement.span,
                  "an interface method needs a return type annotation",
                ))
            })
            use returned <- result.try(infer.annotation_type(
              annotation,
              generics,
              state,
              path,
            ))
            let method =
              nominal.Method(
                requirement.name,
                t.FunctionType(parameters, returned),
                quantified,
                #(identity, interface.source.name.name),
              )
            Ok(#([method, ..acc.0], state))
          },
        ),
      )
      Ok(unify.register_interface(
        state,
        nominal.Interface(..interface, methods: list.reverse(methods)),
      ))
    },
  )
}

fn variables(annotation: Option(ast.TypeAnnotation)) -> List(String) {
  case annotation {
    None -> []
    Some(value) -> type_variables(value)
  }
}

fn type_variables(annotation: ast.TypeAnnotation) -> List(String) {
  case annotation {
    ast.TypeVariable(name, _) -> [name]
    ast.NamedType(arguments: arguments, ..) | ast.TupleType(arguments, _) ->
      list.flat_map(arguments, type_variables)
    ast.FunctionType(parameters, returned, _) ->
      list.flat_map([returned, ..parameters], type_variables)
  }
}

/// Check declared implementations against the required method names, arities and
/// universal signatures.
///
/// ```text
/// User with Named must provide a compatible name() -> String
/// ```
pub fn conformance(
  class: nominal.Class,
  state: unify.State,
  path: String,
) -> List(Diagnostic) {
  list.flat_map(class.interfaces, fn(implemented) {
    let assert t.Nominal(module, name, t.InterfaceKind, arguments) = implemented
    case unify.interface(state, #(module, name)) {
      Error(Nil) -> []
      Ok(interface) -> {
        let missing =
          list.filter(interface.methods, fn(required) {
            !list.any(class.methods, fn(method) {
              method.name.name == required.name.name
              && !list.contains(class.behaviours, method.name.name)
            })
          })
        let missing_errors = case missing {
          [] -> []
          [first, ..] -> [
            issue(
              class,
              interface,
              first,
              path,
              "missing_interface_method",
              "incomplete interface implementation",
            )
            |> diagnostic.conclusion(
              "Missing methods:\n"
              <> string.join(
                list.map(missing, fn(method) {
                  "    "
                  <> method.name.name
                  <> ": "
                  <> t.to_string(nominal.instantiate_interface(
                    method.type_,
                    interface,
                    arguments,
                  ))
                }),
                "\n",
              ),
            ),
          ]
        }
        let incompatible =
          list.flat_map(interface.methods, fn(required) {
            let expected =
              nominal.instantiate_interface(
                required.type_,
                interface,
                arguments,
              )
            case
              list.find(class.methods, fn(method) {
                method.name.name == required.name.name
                && !list.contains(class.behaviours, method.name.name)
              })
            {
              Error(Nil) -> []
              Ok(actual) -> {
                let #(actual_type, trial) =
                  scheme.instantiate(
                    scheme.quantified(
                      unify.apply(actual.type_, state),
                      actual.quantified,
                    ),
                    state,
                  )
                let #(mapping, trial) =
                  list.fold(
                    required.quantified,
                    #(dict.new(), trial),
                    fn(acc, id) {
                      let #(_, rigid, trial) =
                        unify.fresh_rigid("method", acc.1)
                      #(dict.insert(acc.0, id, rigid), trial)
                    },
                  )
                let expected = t.replace(expected, mapping)
                let origin =
                  unify.Origin(
                    location.new(interface.path, required.name.span),
                    location.new(path, actual.name.span),
                    "An implementation must provide the interface method's signature.",
                  )
                case unify.unify(expected, actual_type, origin, trial) {
                  Ok(_) -> []
                  Error(_) -> [
                    diagnostic.error(
                      "type.incompatible_interface_method",
                      "method does not satisfy interface",
                    )
                    |> diagnostic.primary(
                      location.new(path, actual.name.span),
                      "implemented by `" <> class.source.name.name <> "`",
                    )
                    |> diagnostic.secondary(
                      location.new(interface.path, required.name.span),
                      "required by `" <> interface.source.name.name <> "`",
                    )
                    |> diagnostic.conclusion(
                      "Expected: "
                      <> t.to_string(expected)
                      <> "\n   Found: "
                      <> t.to_string(unify.apply(actual_type, trial)),
                    ),
                  ]
                }
              }
            }
          })
        list.append(missing_errors, incompatible)
      }
    }
  })
}

fn issue(
  class: nominal.Class,
  interface: nominal.Interface,
  method: nominal.Method,
  path: String,
  id: String,
  title: String,
) -> Diagnostic {
  diagnostic.error("type." <> id, title)
  |> diagnostic.primary(
    location.new(path, class.source.name.span),
    "`"
      <> class.source.name.name
      <> "` must implement `"
      <> interface.source.name.name
      <> "."
      <> method.name.name
      <> "`",
  )
  |> diagnostic.secondary(
    location.new(interface.path, method.name.span),
    "required method declared here",
  )
}

/// Provide expected interface method types to implementation inference without
/// replacing the final conformance check.
///
/// ```text
/// unannotated implementing method receives its interface's parameter expectations
/// ```
pub fn seed_methods(
  class: nominal.Class,
  state: unify.State,
  path: String,
) -> unify.State {
  list.fold(class.interfaces, state, fn(state, implemented) {
    let assert t.Nominal(module, name, t.InterfaceKind, arguments) = implemented
    case unify.interface(state, #(module, name)) {
      Error(Nil) -> state
      Ok(interface) ->
        list.fold(interface.methods, state, fn(state, required) {
          case
            list.find(class.methods, fn(method) {
              method.name.name == required.name.name
              && !list.contains(class.behaviours, method.name.name)
              && method.owner == nominal.identity(class)
            })
          {
            Error(Nil) -> state
            Ok(method) -> {
              let expected =
                nominal.instantiate_interface(
                  required.type_,
                  interface,
                  arguments,
                )
              let #(expected, trial) =
                scheme.instantiate(
                  scheme.quantified(expected, required.quantified),
                  state,
                )

              case expected, unify.apply(method.type_, trial) {
                t.FunctionType(expected_parameters, _),
                  t.FunctionType(actual_parameters, _)
                -> {
                  let annotations =
                    list.find_map(class.source.members, fn(member) {
                      case member {
                        ast.MethodMember(source)
                          if source.name.name == method.name.name
                        -> Ok(source.parameters)
                        _ -> Error(Nil)
                      }
                    })
                    |> result.unwrap([])
                  list.fold(
                    list.zip(
                      list.zip(expected_parameters, actual_parameters),
                      annotations,
                    ),
                    trial,
                    fn(trial, pair) {
                      case pair.1.annotation {
                        Some(_) -> trial
                        None -> {
                          let origin =
                            unify.Origin(
                              location.new(interface.path, required.name.span),
                              location.new(path, method.name.span),
                              "An interface requirement guides the implementing method's inferred parameter type.",
                            )
                          unify.unify(pair.0.0, pair.0.1, origin, trial)
                          |> result.unwrap(trial)
                        }
                      }
                    },
                  )
                }
                _, _ -> state
              }
            }
          }
        })
    }
  })
}
