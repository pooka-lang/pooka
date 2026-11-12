//// A spelling becomes useful when we know who it belongs to.
////
//// Resolve references against lexical bindings, module exports and imported
//// aliases. Keep use information for later warnings instead of resolving the same
//// names again.
////
//// ```text
//// an imported alias -> its exported declaration identity
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import utilities/location.{type Span}
import utilities/text

type Owner {
  ModuleOwner
  ClassOwner
  ActorOwner
}

type Phase {
  Ordinary
  Constructing
  InitializingField
}

pub type Exports =
  Dict(String, Set(String))

pub type Reference {
  DeclarationReference(name: String)
  ModuleReference(alias: String)
  ImportedReference(name: String)

  MemberReference(owner: String, name: String)
}

pub type Use {
  Use(owner: Option(String), reference: Reference)
}

pub type Resolution {
  Resolution(diagnostics: List(Diagnostic), uses: List(Use))
}

type Event {
  Issue(Diagnostic)
  Usage(Use)
}

type Scope {
  Scope(
    values: Set(String),
    declared: Set(String),
    imported: Set(String),
    members: Set(String),
    declaration: Option(String),
    types: Set(String),
    type_arities: Dict(String, Int),
    modules: Set(String),
    qualifiers: Set(String),
    identities: Dict(String, String),
    exports: Exports,
    path: String,
    locals: Set(String),
    fields: Dict(String, ast.Field),
    direct_fields: Set(String),
    owner: Owner,
    phase: Phase,
    externals: Dict(String, List(String)),
    natives: Set(String),
    pattern_fields: List(String),
  )
}

/// Resolve a module using the ordinary analysis entrypoint and return reference
/// diagnostics.
///
/// ```text
/// an unbound name -> an unknown-name diagnostic
/// ```
pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  check_with_exports(module, path, dict.new())
}

pub fn check_with_exports(
  module: ast.Module,
  path: String,
  exports: Exports,
) -> List(Diagnostic) {
  resolve_with_exports(module, path, exports).diagnostics
}

/// Resolve names with checked dependency exports and retain use information for
/// later unused checks.
///
/// ```text
/// import alias -> exported identity + recorded use
/// ```
pub fn resolve_with_exports(
  module: ast.Module,
  path: String,
  exports: Exports,
) -> Resolution {
  let core_types = [
    "Int",
    "Float",
    "String",
    "UtfCodepoint",
    "Bool",
    "Nil",
    "BitArray",
    "Pid",
    "List",
    "Option",
    "Result",
  ]
  let declared =
    list.filter_map(module.declarations, ast.declaration_name)
    |> list.map(fn(value) { value.name })
  let types =
    module.declarations
    |> list.filter_map(fn(value) {
      case value {
        ast.ClassDeclaration(value) -> Ok(value.name.name)
        ast.ActorDeclaration(value) -> Ok(value.name.name)
        ast.InterfaceDeclaration(value) -> Ok(value.name.name)
        ast.EnumDeclaration(value) -> Ok(value.name.name)
        ast.FunctionDeclaration(_)
        | ast.ExternalDeclaration(_)
        | ast.TestDeclaration(_) -> Error(Nil)
      }
    })
  let aliases =
    list.filter_map(module.imports, fn(imported) {
      case imported.alias {
        Some(alias) -> Ok(alias.name)
        None -> list.last(imported.module.segments)
      }
    })
  let imported =
    list.flat_map(module.imports, fn(imported) {
      list.map(imported.items, fn(item) {
        case item.alias {
          Some(name) -> name.name
          None -> item.name.name
        }
      })
    })
  let core_arities =
    dict.from_list(
      list.map(core_types, fn(name) {
        #(name, case name {
          "List" | "Option" -> 1
          "Result" -> 2
          _ -> 0
        })
      }),
    )
    |> dict.filter(fn(name, _) { !list.contains(imported, name) })
  let declared_arities =
    module.declarations
    |> list.filter_map(fn(value) {
      case value {
        ast.ClassDeclaration(value) ->
          Ok(#(value.name.name, list.length(value.type_parameters)))
        ast.InterfaceDeclaration(value) ->
          Ok(#(value.name.name, list.length(value.type_parameters)))
        ast.ActorDeclaration(value) ->
          Ok(#(value.name.name, list.length(value.type_parameters)))
        ast.EnumDeclaration(value) -> Ok(#(value.name.name, 0))
        ast.FunctionDeclaration(_)
        | ast.ExternalDeclaration(_)
        | ast.TestDeclaration(_) -> Error(Nil)
      }
    })
    |> dict.from_list
  let identities =
    module.imports
    |> list.filter_map(fn(imported) {
      let alias = case imported.alias {
        Some(alias) -> Ok(alias.name)
        None -> list.last(imported.module.segments)
      }
      case alias {
        Ok(alias) -> Ok(#(alias, string.join(imported.module.segments, "/")))
        Error(Nil) -> Error(Nil)
      }
    })
    |> dict.from_list
  let scope =
    Scope(
      values: set.from_list(
        list.flatten([
          declared,
          aliases,
          imported,
          ["Some", "None", "Ok", "Error", "echo"],
        ]),
      ),
      declared: set.from_list(declared),
      imported: set.from_list(imported),
      members: set.new(),
      declaration: None,
      types: set.from_list(list.flatten([core_types, types, imported])),
      type_arities: dict.merge(core_arities, declared_arities),
      modules: set.from_list(aliases),
      qualifiers: set.from_list(aliases),
      identities:,
      exports:,
      path:,
      locals: set.new(),
      fields: dict.new(),
      direct_fields: set.new(),
      owner: ModuleOwner,
      phase: Ordinary,
      externals: module.declarations
        |> list.filter_map(fn(value) {
          case value {
            ast.ExternalDeclaration(value) ->
              Ok(#(
                value.name.name,
                list.map(value.functions, fn(function) { function.name.name }),
              ))
            _ -> Error(Nil)
          }
        })
        |> dict.from_list,
      natives: module.declarations
        |> list.filter_map(fn(value) {
          case value {
            ast.ExternalDeclaration(value) if value.language == ast.Native ->
              Ok(value.name.name)
            _ -> Error(Nil)
          }
        })
        |> set.from_list,
      pattern_fields: [],
    )
  let classes =
    module.declarations
    |> list.filter_map(fn(value) {
      case value {
        ast.ClassDeclaration(value) -> Ok(#(value.name.name, value))
        _ -> Error(Nil)
      }
    })
    |> dict.from_list
  let events =
    module.declarations |> list.flat_map(declaration(_, scope, classes))
  Resolution(
    issues(events) |> diagnostic.sort,
    events
      |> list.filter_map(fn(event) {
        case event {
          Usage(value) -> Ok(value)
          Issue(_) -> Error(Nil)
        }
      })
      |> list.unique,
  )
}

type ReferenceForm {
  NameOnly
  WholeReference
}

type Namespace {
  ValueName
  TypeName
}

fn unknown(
  name: String,
  span: Span,
  scope: Scope,
  namespace: Namespace,
  form: ReferenceForm,
) -> List(Event) {
  let candidates = case namespace {
    TypeName -> scope.types
    ValueName -> scope.values
  }
  case set.contains(candidates, name) {
    True -> reference(name, namespace, scope)
    False -> {
      let #(kind, noun) = case namespace {
        TypeName -> #("type", "type")
        ValueName -> #("name", "binding")
      }
      let base =
        diagnostic.error("analysis.unknown_" <> kind, "unknown " <> kind)
        |> diagnostic.primary(
          location.new(scope.path, span),
          "`" <> name <> "` is not in scope",
        )
        |> diagnostic.conclusion(
          "No " <> noun <> " named `" <> name <> "` is available here.",
        )
      let value = case
        text.closest(name, set.to_list(candidates) |> list.sort(string.compare))
      {
        None -> base
        Some(suggestion) ->
          base
          |> diagnostic.help("Did you mean `" <> suggestion <> "`?")
          |> fix_suggestion(span, suggestion, scope, form)
      }
      [Issue(value)]
    }
  }
}

// A `todo` compiles, so a program can run around unfinished work, but the
// compiler still leaves a note at every place that will crash if reached.
//
// ```pooka
// later() -> Int { todo as "teach the parser about floats" }
// ```
fn unfinished(span: Span, scope: Scope) -> Diagnostic {
  diagnostic.warning("analysis.todo", "todo found")
  |> diagnostic.primary(
    location.new(scope.path, span),
    "this code will crash if it is run",
  )
  |> diagnostic.conclusion(
    "Be sure to finish it before running or publishing your program.",
  )
}

fn qualifier(name: String, span: Span, scope: Scope) -> List(Event) {
  case set.contains(scope.modules, name) {
    True -> [Usage(Use(scope.declaration, ModuleReference(name)))]
    False -> [
      Issue(
        diagnostic.error(
          "analysis.unknown_module_qualifier",
          "unknown module qualifier",
        )
        |> diagnostic.primary(
          location.new(scope.path, span),
          "no module is imported as `" <> name <> "`",
        )
        |> diagnostic.conclusion(
          "Import the module before using this qualifier.",
        ),
      ),
    ]
  }
}

fn annotation(value: ast.TypeAnnotation, scope: Scope) -> List(Event) {
  case value {
    ast.NamedType(module, name, arguments, span) ->
      list.append(
        case module {
          Some(module) -> qualified(module, name, span, scope, WholeReference)
          None ->
            case dict.has_key(scope.externals, name) {
              True -> [Issue(namespace_misuse(name, span, scope, AsType))]
              False ->
                list.append(
                  unknown(name, span, scope, TypeName, WholeReference),
                  type_arity(name, arguments, span, scope),
                )
            }
        },
        list.flat_map(arguments, annotation(_, scope)),
      )

    ast.TypeVariable(..) -> []
    ast.TupleType(elements, _) -> list.flat_map(elements, annotation(_, scope))
    ast.FunctionType(parameters, result, _) ->
      list.flat_map([result, ..parameters], annotation(_, scope))
  }
}

fn optional_annotation(
  value: option.Option(ast.TypeAnnotation),
  scope: Scope,
) -> List(Event) {
  case value {
    Some(value) -> annotation(value, scope)
    None -> []
  }
}

fn parameters(
  values: List(ast.Parameter),
  scope: Scope,
) -> #(Scope, List(Event)) {
  let annotations =
    list.flat_map(values, fn(value) {
      optional_annotation(value.annotation, scope)
    })
  let names =
    list.filter_map(values, fn(value) {
      case value.name {
        ast.NamedParameter(name) -> Ok(name)
        ast.DiscardedParameter -> Error(Nil)
      }
    })
  #(bind(scope, names), annotations)
}

fn bind(scope: Scope, names: List(String)) -> Scope {
  Scope(
    ..scope,
    values: set.union(scope.values, set.from_list(names)),
    locals: set.union(scope.locals, set.from_list(names)),
    qualifiers: set.difference(scope.qualifiers, set.from_list(names)),
  )
}

fn callable(value: ast.Function, scope: Scope) -> List(Event) {
  let #(locals, parameters) = parameters(value.parameters, scope)
  list.flatten([
    parameters,
    optional_annotation(value.return_type, scope),
    block(value.body, locals),
  ])
}

fn declaration(
  value: ast.Declaration,
  scope: Scope,
  classes: Dict(String, ast.Class),
) -> List(Event) {
  let scope =
    Scope(..scope, declaration: case ast.declaration_name(value) {
      Ok(name) -> Some(name.name)
      Error(Nil) -> None
    })
  case value {
    ast.FunctionDeclaration(value) -> callable(value, scope)
    ast.ExternalDeclaration(value) ->
      list.flat_map(value.functions, fn(function) {
        let #(_, parameters) = parameters(function.parameters, scope)
        list.append(parameters, annotation(function.return_type, scope))
      })
    ast.TestDeclaration(value) -> block(value.body, scope)

    ast.EnumDeclaration(_) -> []
    ast.InterfaceDeclaration(value) ->
      list.flat_map(value.requirements, fn(value) {
        let #(_, parameters) = parameters(value.parameters, scope)
        list.append(parameters, optional_annotation(value.return_type, scope))
      })
    ast.ClassDeclaration(value) -> {
      let members = inherited_members(value, classes, set.new())
      let locals =
        Scope(
          ..scope,
          values: set.union(scope.values, set.from_list(members)),
          members: set.from_list(members),
          qualifiers: set.difference(scope.qualifiers, set.from_list(members)),
          fields: inherited_fields(value, classes, set.new()),
          direct_fields: field_map(value.members) |> dict.keys |> set.from_list,
          owner: ClassOwner,
          pattern_fields: ordered_fields(value, classes, set.new()),
        )

      let superclass = case value.superclass {
        Some(ast.NamedType(None, name, arguments, _)) ->
          list.append(
            reference(name, TypeName, scope),
            list.flat_map(arguments, annotation(_, scope)),
          )
        Some(ast.NamedType(Some(module), _, arguments, _)) ->
          list.append(
            [Usage(Use(scope.declaration, ModuleReference(module)))],
            list.flat_map(arguments, annotation(_, scope)),
          )
        None | Some(_) -> []
      }
      list.flatten([
        superclass,
        list.flat_map(value.interfaces, annotation(_, scope)),
        member_bodies(value.members, locals),
      ])
    }
    ast.ActorDeclaration(value) ->
      list.append(
        list.flat_map(value.interfaces, annotation(_, scope)),
        member_bodies(
          value.members,
          Scope(
            ..scope,
            values: set.union(
              scope.values,
              set.from_list(member_names(value.members)),
            ),
            fields: field_map(value.members),
            direct_fields: field_map(value.members)
              |> dict.keys
              |> set.from_list,
            qualifiers: set.difference(
              scope.qualifiers,
              set.from_list(member_names(value.members)),
            ),
            members: set.from_list(member_names(value.members)),
            owner: ActorOwner,
          ),
        ),
      )
  }
}

fn member_names(values: List(ast.Member)) -> List(String) {
  list.filter_map(values, fn(value) {
    case value {
      ast.FieldMember(value) -> Ok(value.name.name)
      ast.MethodMember(value) | ast.BehaviourMember(value) ->
        Ok(value.name.name)
      ast.ConstructorMember(_) -> Error(Nil)
    }
  })
}

fn inherited_members(
  value: ast.Class,
  classes: Dict(String, ast.Class),
  seen: Set(String),
) -> List(String) {
  case set.contains(seen, value.name.name) {
    True -> []
    False -> {
      let own = member_names(value.members)
      let parent = case value.superclass {
        Some(ast.NamedType(None, name, _, _)) ->
          case dict.get(classes, name) {
            Ok(parent) ->
              inherited_members(
                parent,
                classes,
                set.insert(seen, value.name.name),
              )
              |> list.filter(fn(name) { !string.starts_with(name, "_") })
            Error(Nil) -> []
          }
        _ -> []
      }
      list.append(own, parent)
    }
  }
}

fn member_bodies(values: List(ast.Member), scope: Scope) -> List(Event) {
  list.flat_map(values, fn(value) {
    case value {
      ast.FieldMember(value) ->
        list.append(
          optional_annotation(value.annotation, scope),
          optional(value.value, Scope(..scope, phase: InitializingField)),
        )
      ast.MethodMember(value) | ast.BehaviourMember(value) ->
        callable(value, scope)
      ast.ConstructorMember(value) -> {
        let #(locals, parameters) =
          parameters(value.parameters, Scope(..scope, phase: Constructing))
        list.append(parameters, block(value.body, locals))
      }
    }
  })
}

fn block(value: ast.Block, scope: Scope) -> List(Event) {
  let #(_, diagnostics) =
    list.fold(value.statements, #(scope, []), fn(acc, value) {
      let #(scope, diagnostics) = acc
      case value {
        ast.ExpressionStatement(value) -> #(
          scope,
          list.append(diagnostics, expression(value, scope)),
        )
        ast.LetStatement(pattern:, annotation:, value:, ..) -> {
          let #(locals, pattern) = resolve_pattern(pattern, scope)
          #(
            locals,
            list.flatten([
              diagnostics,
              expression(value, scope),
              optional_annotation(annotation, scope),
              pattern,
            ]),
          )
        }
        ast.LetAssertStatement(pattern:, annotation:, value:, message:, ..) -> {
          let #(locals, pattern) = resolve_pattern(pattern, scope)
          #(
            locals,
            list.flatten([
              diagnostics,
              expression(value, scope),
              optional_annotation(annotation, scope),
              optional(message, scope),
              pattern,
            ]),
          )
        }
      }
    })
  diagnostics
}

fn resolve_pattern(value: ast.Pattern, scope: Scope) -> #(Scope, List(Event)) {
  case value {
    ast.VariablePattern(name, _) -> #(bind(scope, [name]), [])
    ast.DiscardPattern(_)
    | ast.IntPattern(..)
    | ast.FloatPattern(..)
    | ast.StringPattern(..)
    | ast.BoolPattern(..)
    | ast.NilPattern(..) -> #(scope, [])
    ast.TuplePattern(elements, _) -> patterns(elements, scope)
    ast.ListPattern(elements, tail, _) -> {
      let #(scope, diagnostics) = patterns(elements, scope)
      let scope = case tail {
        Some(ast.BoundTail(name, _)) -> bind(scope, [name])
        Some(ast.IgnoredTail(_)) | None -> scope
      }
      #(scope, diagnostics)
    }
    ast.ConstructorPattern(module, name, arguments, span) -> {
      let own = case module, dict.has_key(scope.externals, name) {
        Some(module), _ -> qualified(module, name, span, scope, WholeReference)
        None, True -> [Issue(namespace_misuse(name, span, scope, AsPattern))]
        None, False -> unknown(name, span, scope, ValueName, WholeReference)
      }

      let fields_read = case module, scope.declaration == Some(name) {
        None, True ->
          list.zip(scope.pattern_fields, arguments)
          |> list.flat_map(fn(pair) {
            case pair.1 {
              ast.DiscardPattern(_) -> []
              _ -> private_member_use(pair.0, scope)
            }
          })
        _, _ -> []
      }
      let #(scope, diagnostics) = patterns(arguments, scope)
      #(scope, list.flatten([own, fields_read, diagnostics]))
    }

    ast.EnumPattern(module, enum_name, _, span) -> {
      let own = case module {
        Some(module) ->
          qualified(module, enum_name, span, scope, WholeReference)
        None -> unknown(enum_name, span, scope, ValueName, WholeReference)
      }
      #(scope, own)
    }
    ast.BitArrayPattern(segments, _) ->
      list.fold(segments, #(scope, []), fn(acc, segment) {
        let #(scope, diagnostics) = acc
        let options = segment_options(segment.options, scope)
        let #(scope, value) = resolve_pattern(segment.value, scope)
        #(scope, list.flatten([diagnostics, options, value]))
      })
  }
}

fn patterns(values: List(ast.Pattern), scope: Scope) -> #(Scope, List(Event)) {
  list.fold(values, #(scope, []), fn(acc, value) {
    let #(scope, diagnostics) = acc
    let #(scope, own) = resolve_pattern(value, scope)
    #(scope, list.append(diagnostics, own))
  })
}

fn segment_options(
  values: List(ast.BitArrayOption),
  scope: Scope,
) -> List(Event) {
  list.flat_map(values, fn(value) {
    case value {
      ast.NamedOption(..) -> []
      ast.SizeOption(value, _) | ast.UnitOption(value, _) ->
        expression(value, scope)
    }
  })
}

fn optional(value: option.Option(ast.Expression), scope: Scope) -> List(Event) {
  case value {
    Some(value) -> expression(value, scope)
    None -> []
  }
}

fn expressions(values: List(ast.Expression), scope: Scope) -> List(Event) {
  list.flat_map(values, expression(_, scope))
}

fn expression(value: ast.Expression, scope: Scope) -> List(Event) {
  case value {
    ast.TypeName(name, span) ->
      case dict.has_key(scope.externals, name) {
        True -> [Issue(namespace_misuse(name, span, scope, AsValue))]
        False -> unknown(name, span, scope, ValueName, NameOnly)
      }
    ast.Variable(name, span) -> unknown(name, span, scope, ValueName, NameOnly)
    ast.IntLiteral(..)
    | ast.FloatLiteral(..)
    | ast.StringLiteral(..)
    | ast.BoolLiteral(..)
    | ast.NilLiteral(..)
    | ast.SelfExpression(..)
    | ast.SuperExpression(..)
    | ast.Continue(..) -> []
    ast.ListExpression(elements:, ..) | ast.TupleExpression(elements:, ..) ->
      expressions(elements, scope)
    ast.BlockExpression(value) -> block(value, scope)
    ast.AnonymousFunction(values, return_type, body, _) -> {
      let #(locals, parameters) =
        parameters(values, Scope(..scope, phase: Ordinary))
      list.flatten([
        parameters,
        optional_annotation(return_type, scope),
        block(body, locals),
      ])
    }
    ast.Call(ast.TypeName(name, span), arguments, _) ->
      case dict.has_key(scope.externals, name) {
        True -> [
          Issue(namespace_misuse(name, span, scope, AsConstructor)),
          ..expressions(arguments, scope)
        ]
        False -> expressions([ast.TypeName(name, span), ..arguments], scope)
      }
    ast.Call(callee, arguments, _) -> expressions([callee, ..arguments], scope)
    ast.TupleAccess(subject:, ..) -> expression(subject, scope)
    ast.FieldAccess(subject: ast.TypeName(namespace, _), name:, ..) ->
      case dict.get(scope.externals, namespace) {
        Ok(functions) -> external_member(namespace, functions, name, scope)
        Error(Nil) ->
          expression(ast.TypeName(namespace, ast.expression_span(value)), scope)
      }
    ast.FieldAccess(subject:, name:, ..) ->
      list.append(
        list.append(
          expression(subject, scope),
          private_member_use(name.name, scope),
        ),
        case subject {
          ast.Variable(module, _) ->
            case set.contains(scope.qualifiers, module) {
              True -> qualified(module, name.name, name.span, scope, NameOnly)
              False -> []
            }
          _ -> []
        },
      )
    ast.Unary(operand:, ..) | ast.Propagate(operand:, ..) ->
      expression(operand, scope)
    ast.Binary(left:, right:, ..) -> expressions([left, right], scope)
    ast.Match(subject, branches, _) ->
      list.append(
        expression(subject, scope),
        list.flat_map(branches, fn(branch) {
          let #(locals, pattern) = resolve_pattern(branch.pattern, scope)
          list.flatten([
            pattern,
            optional(branch.guard, locals),
            expression(branch.body, locals),
          ])
        }),
      )
    ast.Loop(iteration, body, _) ->
      case iteration {
        None -> block(body, scope)
        Some(value) -> {
          let #(locals, pattern) = resolve_pattern(value.pattern, scope)
          list.flatten([
            expression(value.iterable, scope),
            pattern,
            block(body, locals),
          ])
        }
      }
    ast.Break(value:, ..) -> optional(value, scope)
    ast.Panic(message:, ..) -> optional(message, scope)
    ast.Todo(message:, span:) -> [
      Issue(unfinished(span, scope)),
      ..optional(message, scope)
    ]
    ast.Assert(condition:, message:, ..) ->
      list.append(expression(condition, scope), optional(message, scope))
    ast.Assignment(target:, value:, ..) ->
      list.append(assignment_target(target, scope), expression(value, scope))
    ast.BitArrayExpression(segments, _) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          expression(segment.value, scope),
          segment_options(segment.options, scope),
        )
      })
  }
}

fn field_map(values: List(ast.Member)) -> Dict(String, ast.Field) {
  values
  |> list.filter_map(fn(value) {
    case value {
      ast.FieldMember(value) -> Ok(#(value.name.name, value))
      ast.MethodMember(_) | ast.BehaviourMember(_) | ast.ConstructorMember(_) ->
        Error(Nil)
    }
  })
  |> dict.from_list
}

fn inherited_fields(
  value: ast.Class,
  classes: Dict(String, ast.Class),
  seen: Set(String),
) -> Dict(String, ast.Field) {
  case set.contains(seen, value.name.name) {
    True -> dict.new()
    False -> {
      let parent = case value.superclass {
        Some(ast.NamedType(None, name, _, _)) ->
          case dict.get(classes, name) {
            Ok(parent) ->
              inherited_fields(
                parent,
                classes,
                set.insert(seen, value.name.name),
              )
              |> dict.filter(fn(name, _) { !string.starts_with(name, "_") })
            Error(Nil) -> dict.new()
          }
        _ -> dict.new()
      }
      dict.merge(parent, field_map(value.members))
    }
  }
}

fn assignment_error(
  scope: Scope,
  name: ast.Name,
  id: String,
  title: String,
  conclusion: String,
) -> Diagnostic {
  diagnostic.error("analysis." <> id, title)
  |> diagnostic.primary(
    location.new(scope.path, name.span),
    "`" <> name.name <> "` cannot be assigned here",
  )
  |> diagnostic.conclusion(conclusion)
}

fn assignment_target(
  target: ast.AssignmentTarget,
  scope: Scope,
) -> List(Event) {
  case target {
    ast.AssignVariable(name) -> {
      let resolution = unknown(name.name, name.span, scope, ValueName, NameOnly)
      case has_errors(resolution), set.contains(scope.locals, name.name) {
        True, _ -> resolution
        False, True -> [
          Issue(assignment_error(
            scope,
            name,
            "immutable_local",
            "assignment to an immutable binding",
            "Parameters and local bindings are immutable. Introduce a new binding in a nested scope instead.",
          )),
        ]
        False, False ->
          case dict.get(scope.fields, name.name) {
            Error(Nil) -> [
              Issue(assignment_error(
                scope,
                name,
                "invalid_assignment_target",
                "invalid assignment target",
                "Only mutable state declared by the enclosing actor may be assigned by name.",
              )),
            ]
            Ok(field) -> {
              let error = case scope.phase, scope.owner, field.mutability {
                Constructing, _, _ ->
                  Some(assignment_error(
                    scope,
                    name,
                    "constructor_assignment_requires_self",
                    "constructor assignment requires self",
                    "Initialize fields with `self."
                      <> name.name
                      <> " = value` in the constructor.",
                  ))
                _, ClassOwner, _ | _, _, ast.Immutable ->
                  Some(assignment_error(
                    scope,
                    name,
                    "immutable_field",
                    "assignment to an immutable field",
                    "Immutable fields are assigned exactly once during construction.",
                  ))
                InitializingField, ActorOwner, ast.Mutable ->
                  Some(assignment_error(
                    scope,
                    name,
                    "state_assignment_in_initializer",
                    "state mutation in a field initializer",
                    "Initialize actor state with a field value or `self` assignment in `new`; mutate it from actor methods and behaviours.",
                  ))
                Ordinary, ActorOwner, ast.Mutable -> None
                _, ModuleOwner, _ ->
                  Some(assignment_error(
                    scope,
                    name,
                    "invalid_assignment_target",
                    "invalid assignment target",
                    "Only the owning actor implementation may mutate actor state.",
                  ))
              }
              case error {
                None -> []
                Some(error) -> [
                  Issue(diagnostic.secondary(
                    error,
                    location.new(scope.path, field.name.span),
                    "field declared here",
                  )),
                ]
              }
            }
          }
      }
    }
    ast.AssignField(subject, name, _) -> {
      let resolved = expression(subject, scope)
      case has_errors(resolved) {
        True -> resolved
        False ->
          case subject, scope.phase {
            ast.SelfExpression(_), Constructing ->
              case
                set.contains(scope.direct_fields, name.name),
                dict.has_key(scope.fields, name.name)
              {
                True, _ -> []
                False, True -> [
                  Issue(assignment_error(
                    scope,
                    name,
                    "inherited_field_initialization",
                    "inherited field initialized directly",
                    "Initialize inherited storage through `super.new`; a constructor initializes only fields declared directly by its type.",
                  )),
                ]
                False, False -> [
                  Issue(assignment_error(
                    scope,
                    name,
                    "unknown_field",
                    "unknown constructor field",
                    "No accessible field named `"
                      <> name.name
                      <> "` is declared by this type.",
                  )),
                ]
              }

            ast.SelfExpression(_), Ordinary
            | ast.SelfExpression(_), InitializingField
            -> []
            _, _ -> [
              Issue(assignment_error(
                scope,
                name,
                "invalid_field_assignment",
                "field assignment outside construction",
                "Initialize fields through `self` in a constructor. Actor state is assigned by name inside its owning actor implementation.",
              )),
            ]
          }
      }
    }
  }
}

fn qualified(
  module: String,
  name: String,
  span: Span,
  scope: Scope,
  form: ReferenceForm,
) -> List(Event) {
  let resolved = qualifier(module, span, scope)
  let identity = case dict.get(scope.identities, module) {
    Ok(value) -> value
    Error(Nil) -> module
  }
  case has_errors(resolved) {
    True -> resolved
    False -> {
      let own = case string.starts_with(name, "_") {
        True -> [
          Issue(
            diagnostic.error(
              "analysis.private_declaration",
              "private module declaration",
            )
            |> diagnostic.primary(
              location.new(scope.path, span),
              "`" <> name <> "` is private to `" <> identity <> "`",
            )
            |> diagnostic.conclusion(
              "Only ordinary-name declarations are accessible through an imported module.",
            ),
          ),
        ]
        False ->
          case dict.get(scope.exports, identity) {
            Error(Nil) -> []
            Ok(exports) ->
              case set.contains(exports, name) {
                True -> []
                False -> {
                  let base =
                    diagnostic.error(
                      "analysis.unknown_module_member",
                      "unknown module declaration",
                    )
                    |> diagnostic.primary(
                      location.new(scope.path, span),
                      "`"
                        <> identity
                        <> "` has no declaration named `"
                        <> name
                        <> "`",
                    )
                    |> diagnostic.conclusion(
                      "Use a public declaration defined by the imported module.",
                    )
                  let value = case
                    text.closest(
                      name,
                      set.to_list(exports) |> list.sort(string.compare),
                    )
                  {
                    None -> base
                    Some(suggestion) ->
                      base
                      |> diagnostic.help(
                        "Did you mean `" <> module <> "." <> suggestion <> "`?",
                      )
                      |> fix_suggestion(span, suggestion, scope, form)
                  }
                  [Issue(value)]
                }
              }
          }
      }
      list.append(resolved, own)
    }
  }
}

fn fix_suggestion(
  value: Diagnostic,
  span: Span,
  suggestion: String,
  scope: Scope,
  form: ReferenceForm,
) -> Diagnostic {
  case form {
    WholeReference -> value
    NameOnly ->
      diagnostic.fix(
        value,
        location.new(scope.path, span),
        suggestion,
        "Use `" <> suggestion <> "`",
        diagnostic.Suggested,
      )
  }
}

fn type_arity(
  name: String,
  arguments: List(ast.TypeAnnotation),
  span: Span,
  scope: Scope,
) -> List(Event) {
  case dict.get(scope.type_arities, name) {
    Error(Nil) -> []
    Ok(expected) ->
      case expected == list.length(arguments) {
        True -> []
        False -> [
          Issue(
            diagnostic.error(
              "analysis.type_arity",
              "wrong number of type arguments",
            )
            |> diagnostic.primary(
              location.new(scope.path, span),
              "`"
                <> name
                <> "` requires "
                <> text.counted(expected, "type argument"),
            )
            |> diagnostic.conclusion(
              "Found "
              <> text.counted(list.length(arguments), "type argument")
              <> "; expected "
              <> int.to_string(expected)
              <> ".",
            ),
          ),
        ]
      }
  }
}

fn issues(events: List(Event)) -> List(Diagnostic) {
  list.filter_map(events, fn(event) {
    case event {
      Issue(value) -> Ok(value)
      Usage(_) -> Error(Nil)
    }
  })
}

fn has_errors(events: List(Event)) -> Bool {
  diagnostic.has_errors(issues(events))
}

fn reference(name: String, namespace: Namespace, scope: Scope) -> List(Event) {
  let local = namespace == ValueName && set.contains(scope.locals, name)
  let member = namespace == ValueName && set.contains(scope.members, name)
  case local, member {
    True, _ -> []

    False, True -> private_member_use(name, scope)
    False, False ->
      case
        set.contains(scope.qualifiers, name),
        set.contains(scope.imported, name),
        set.contains(scope.declared, name)
      {
        True, _, _ if namespace == ValueName -> [
          Usage(Use(scope.declaration, ModuleReference(name))),
        ]
        _, True, _ -> [Usage(Use(scope.declaration, ImportedReference(name)))]
        _, _, True -> [
          Usage(Use(scope.declaration, DeclarationReference(name))),
        ]
        _, _, _ -> []
      }
  }
}

fn private_member_use(name: String, scope: Scope) -> List(Event) {
  case string.starts_with(name, "_"), scope.owner, scope.declaration {
    True, ClassOwner, Some(owner) | True, ActorOwner, Some(owner) -> [
      Usage(Use(scope.declaration, MemberReference(owner, name))),
    ]
    _, _, _ -> []
  }
}

fn ordered_fields(
  value: ast.Class,
  classes: Dict(String, ast.Class),
  seen: Set(String),
) -> List(String) {
  let own =
    list.filter_map(value.members, fn(member) {
      case member {
        ast.FieldMember(field) -> Ok(field.name.name)
        _ -> Error(Nil)
      }
    })
  let inherited = case set.contains(seen, value.name.name), value.superclass {
    False, Some(ast.NamedType(None, name, _, _)) ->
      case dict.get(classes, name) {
        Ok(parent) ->
          ordered_fields(parent, classes, set.insert(seen, value.name.name))
        Error(Nil) -> []
      }
    _, _ -> []
  }
  list.append(inherited, own)
}

type NamespaceMisuse {
  AsValue
  AsConstructor
  AsType
  AsPattern
}

fn namespace_misuse(
  name: String,
  span: Span,
  scope: Scope,
  misuse: NamespaceMisuse,
) -> Diagnostic {
  let kind = case set.contains(scope.natives, name) {
    True -> "native"
    False -> "external"
  }
  let #(id, title, label) = case misuse {
    AsValue -> #(
      "analysis.external_namespace_value",
      kind <> " namespace used as a value",
      "`" <> name <> "` is " <> article(kind) <> " namespace, not a value",
    )
    AsConstructor -> #(
      "analysis.external_namespace_construction",
      kind <> " namespaces cannot be instantiated",
      "`" <> name <> "` has no constructor",
    )
    AsType -> #(
      "analysis.external_namespace_type",
      kind <> " namespace used as a type",
      "`" <> name <> "` is " <> article(kind) <> " namespace, not a type",
    )
    AsPattern -> #(
      "analysis.external_namespace_pattern",
      kind <> " namespace used as a pattern",
      "`" <> name <> "` is " <> article(kind) <> " namespace, not a class",
    )
  }
  diagnostic.error(id, title)
  |> diagnostic.primary(location.new(scope.path, span), label)
  |> diagnostic.conclusion(
    "Only the functions of "
    <> article(kind)
    <> " "
    <> kind
    <> " namespace can be used, as `"
    <> name
    <> ".function(...)`.",
  )
}

fn article(kind: String) -> String {
  case kind {
    "external" -> "an"
    _ -> "a"
  }
}

fn external_member(
  namespace: String,
  functions: List(String),
  name: ast.Name,
  scope: Scope,
) -> List(Event) {
  let used = reference(namespace, ValueName, scope)
  case list.contains(functions, name.name) {
    True -> used
    False -> {
      let base =
        diagnostic.error(
          "analysis.unknown_external_function",
          "unknown external function",
        )
        |> diagnostic.primary(
          location.new(scope.path, name.span),
          "`" <> namespace <> "` declares no function `" <> name.name <> "`",
        )
        |> diagnostic.conclusion(
          "Add a signature for `"
          <> name.name
          <> "` to the external declaration of `"
          <> namespace
          <> "`, or call one it declares.",
        )
      let diagnostic = case
        text.closest(name.name, list.sort(functions, string.compare))
      {
        None -> base
        Some(suggestion) ->
          base
          |> diagnostic.help(
            "Did you mean `" <> namespace <> "." <> suggestion <> "`?",
          )
          |> fix_suggestion(name.span, suggestion, scope, NameOnly)
      }
      [Issue(diagnostic), ..used]
    }
  }
}
