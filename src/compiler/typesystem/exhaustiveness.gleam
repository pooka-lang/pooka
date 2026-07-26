//// Before closing a match, check the chairs left empty.
////
//// Use pattern usefulness and constructor signatures to find missing cases and
//// unreachable branches. Unknown guards cannot quietly stand in for unconditional
//// coverage.
////
//// ```text
//// match Bool with only True -> False is still missing
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/literal
import compiler/parser/ast
import compiler/typesystem/bit_array_coverage
import compiler/typesystem/monotype.{type Type}
import compiler/typesystem/nominal
import compiler/typesystem/unify
import diagnostics/diagnostic.{type Diagnostic}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import utilities/location.{type Span}

type Tag {
  Boolean(Bool)
  NilValue
  Tuple(Int)
  EmptyList
  ConsList
  EmptyBits
  ConsBit
  SomeValue
  NoneValue
  OkValue
  ErrorValue
  Integer(String)
  Floating(Float)
  Text(String)
  ClassValue(module: String, name: String)

  EnumValue(module: String, enum: String, variant: String)
  Opaque(String)
}

type Pattern {
  Any
  Constructor(tag: Tag, arguments: List(Pattern))
}

type Signature {
  Signature(tag: Tag, fields: List(Type))
}

/// Check a pattern match without a supplied nominal context through the
/// convenience entrypoint.
///
/// ```text
/// Bool branches True and False -> complete coverage
/// ```
pub fn check(
  subject: Type,
  branches: List(ast.Branch),
  path: String,
  subject_span: Span,
) -> List(Diagnostic) {
  check_in(subject, branches, path, subject_span, unify.new())
}

/// Check usefulness and missing cases with the module's nominal hierarchy
/// available.
///
/// ```text
/// Ref with Tmp and Con -> both concrete alternatives need coverage
/// ```
pub fn check_in(
  subject: Type,
  branches: List(ast.Branch),
  path: String,
  subject_span: Span,
  state: unify.State,
) -> List(Diagnostic) {
  let unsupported_nominal = case subject {
    monotype.Nominal(_, _, monotype.InterfaceKind, _) -> False
    monotype.Nominal(..) -> signature(subject, state) == []
    _ -> False
  }
  case unsupported_nominal, subject {
    True, _ | _, monotype.ErrorType -> []
    False, _ -> {
      let #(matrix, warnings) =
        list.fold(branches, #([], []), fn(acc, branch) {
          let #(matrix, warnings) = acc
          let alternatives = normalize(branch.pattern, state, path)
          let reachable =
            list.any(alternatives, fn(pattern) {
              result.is_ok(useful(matrix, [pattern], [subject], state))
            })
          let warnings = case reachable {
            True -> warnings
            False -> [
              diagnostic.warning(
                "type.unreachable_pattern",
                "unreachable pattern",
              )
                |> diagnostic.primary(
                  location.new(path, ast.pattern_span(branch.pattern)),
                  "earlier unguarded branches already cover this pattern",
                )
                |> diagnostic.conclusion(
                  "This match branch can never be selected.",
                ),
              ..warnings
            ]
          }

          let matrix = case branch.guard {
            None ->
              list.append(
                list.reverse(list.map(alternatives, fn(pattern) { [pattern] })),
                matrix,
              )
            Some(_) -> matrix
          }
          #(matrix, warnings)
        })
      let missing = case useful(matrix, [Any], [subject], state) {
        Error(Nil) -> []
        Ok([witness]) -> [
          diagnostic.error("type.non_exhaustive_match", "non-exhaustive match")
          |> diagnostic.primary(
            location.new(path, subject_span),
            "not every " <> monotype.to_string(subject) <> " value is handled",
          )
          |> diagnostic.conclusion(
            "Every possible value of the matched type must be handled.",
          )
          |> diagnostic.help(
            "Handle `" <> show(witness) <> "` or add a fallback branch.",
          ),
        ]
        Ok(_) -> []
      }
      list.append(list.reverse(warnings), missing) |> diagnostic.sort
    }
  }
}

/// Translate syntax patterns into the coverage representation used by the
/// usefulness algorithm.
///
/// ```text
/// Some(_) -> constructor Some with a wildcard child
/// ```
fn normalize(
  value: ast.Pattern,
  state: unify.State,
  path: String,
) -> List(Pattern) {
  case value {
    ast.VariablePattern(..) | ast.DiscardPattern(..) -> [Any]
    ast.BoolPattern(value, _) -> [Constructor(Boolean(value), [])]
    ast.NilPattern(_) -> [Constructor(NilValue, [])]
    ast.IntPattern(value, _) -> [
      Constructor(
        Integer(case literal.parse_int(value) {
          Ok(value) -> int.to_string(value)
          Error(Nil) -> value
        }),
        [],
      ),
    ]
    ast.FloatPattern(value, _) ->
      case literal.parse_float(value) {
        Ok(value) -> [Constructor(Floating(value), [])]
        Error(Nil) -> [Constructor(Opaque(value), [])]
      }
    ast.StringPattern(value, _) -> [
      Constructor(
        Text(literal.decode_string(value) |> result.unwrap(value)),
        [],
      ),
    ]
    ast.TuplePattern(elements, _) ->
      elements
      |> product(state, path)
      |> list.map(Constructor(Tuple(list.length(elements)), _))
    ast.ListPattern(elements, tail, _) -> {
      let tail = case tail {
        None -> Constructor(EmptyList, [])
        Some(_) -> Any
      }
      product(elements, state, path)
      |> list.map(fn(heads) {
        list.fold(list.reverse(heads), tail, fn(tail, head) {
          Constructor(ConsList, [head, tail])
        })
      })
    }
    ast.EnumPattern(qualifier, name, variant, _) ->
      case unify.named_enum(state, path, option.unwrap(qualifier, ""), name) {
        Ok(enum) -> [
          Constructor(
            EnumValue(enum.module, enum.source.name.name, variant.name),
            [],
          ),
        ]
        Error(Nil) -> [Constructor(Opaque(name <> "." <> variant.name), [])]
      }
    ast.ConstructorPattern(qualifier, name, arguments, _) -> {
      let arguments = product(arguments, state, path)
      case name {
        "Some" -> list.map(arguments, Constructor(SomeValue, _))
        "None" -> list.map(arguments, Constructor(NoneValue, _))
        "Ok" -> list.map(arguments, Constructor(OkValue, _))
        "Error" -> list.map(arguments, Constructor(ErrorValue, _))
        _ ->
          case
            unify.named_class(
              state,
              path,
              case qualifier {
                Some(value) -> value
                None -> ""
              },
              name,
            )
          {
            Ok(class) ->
              list.flat_map(covered(state, class), fn(covered) {
                list.map(arguments, fn(arguments) {
                  let extra =
                    list.length(covered.fields) - list.length(arguments)
                  Constructor(
                    ClassValue(covered.module, covered.source.name.name),
                    list.append(arguments, list.repeat(Any, extra)),
                  )
                })
              })
            Error(Nil) -> list.map(arguments, Constructor(Opaque(name), _))
          }
      }
    }
    ast.BitArrayPattern(segments, span) ->
      case bit_array_coverage.prove(segments) {
        Ok(bit_array_coverage.Layout(impossible: True, ..)) -> []
        Ok(layout) -> {
          let tail = case layout.tail {
            True -> Any
            False -> Constructor(EmptyBits, [])
          }
          [
            list.fold(list.reverse(layout.bits), tail, fn(tail, bit) {
              let head = case bit {
                Some(bit) -> Constructor(Boolean(bit), [])
                None -> Any
              }
              Constructor(ConsBit, [head, tail])
            }),
          ]
        }
        Error(Nil) -> [
          Constructor(
            Opaque("bits@" <> int.to_string(span.start.byte_offset)),
            [],
          ),
        ]
      }
  }
}

fn product(
  values: List(ast.Pattern),
  state: unify.State,
  path: String,
) -> List(List(Pattern)) {
  list.fold(list.reverse(values), [[]], fn(rest, value) {
    list.flat_map(normalize(value, state, path), fn(first) {
      list.map(rest, fn(tail) { [first, ..tail] })
    })
  })
}

fn covered(state: unify.State, class: nominal.Class) -> List(nominal.Class) {
  unify.subtree(state, nominal.identity(class))
  |> list.filter(unify.constructible(state, _))
}

fn signature(value: Type, state: unify.State) -> List(Signature) {
  case value {
    monotype.BoolType -> [
      Signature(Boolean(True), []),
      Signature(Boolean(False), []),
    ]
    monotype.BitArrayType -> [
      Signature(EmptyBits, []),
      Signature(ConsBit, [monotype.BoolType, monotype.BitArrayType]),
    ]
    monotype.NilType -> [Signature(NilValue, [])]
    monotype.TupleType(elements) -> [
      Signature(Tuple(list.length(elements)), elements),
    ]
    monotype.ListType(element) -> [
      Signature(EmptyList, []),
      Signature(ConsList, [element, value]),
    ]
    monotype.OptionType(value) -> [
      Signature(NoneValue, []),
      Signature(SomeValue, [value]),
    ]
    monotype.ResultType(value, error) -> [
      Signature(OkValue, [value]),
      Signature(ErrorValue, [error]),
    ]
    monotype.Nominal(module, name, monotype.ClassKind, arguments) ->
      case unify.class(state, #(module, name)) {
        Ok(class) ->
          list.map(covered(state, class), fn(member) {
            Signature(
              ClassValue(member.module, member.source.name.name),
              list.map(member.fields, fn(field) {
                nominal.instantiate(
                  unify.apply(field.type_, state),
                  member,
                  descendant_arguments(state, member, class, arguments),
                )
              }),
            )
          })
        Error(Nil) -> []
      }
    monotype.Nominal(module, name, monotype.EnumKind, _) ->
      case unify.enum(state, #(module, name)) {
        Ok(enum) ->
          list.map(nominal.variants(enum), fn(variant) {
            Signature(EnumValue(module, name, variant), [])
          })
        Error(Nil) -> []
      }
    monotype.Nominal(..) -> []
    monotype.Variable(_)
    | monotype.RigidVariable(..)
    | monotype.IntType
    | monotype.FloatType
    | monotype.StringType
    | monotype.PidType
    | monotype.FunctionType(..)
    | monotype.ErrorType -> []
  }
}

/// Ask whether a candidate pattern covers any value not already covered by
/// earlier rows of the pattern matrix.
///
/// ```text
/// True after an unconditional wildcard is not useful
/// ```
fn useful(
  matrix: List(List(Pattern)),
  query: List(Pattern),
  types: List(Type),
  state: unify.State,
) -> Result(List(Pattern), Nil) {
  case query {
    [] ->
      case list.any(matrix, fn(row) { row == [] }) {
        True -> Error(Nil)
        False -> Ok([])
      }
    [Constructor(tag, arguments), ..rest] -> {
      let #(head_type, tail_types) = split_type(types)
      let fields = case
        list.find(signature(head_type, state), fn(value) { value.tag == tag })
      {
        Ok(value) -> value.fields
        Error(Nil) -> list.repeat(monotype.ErrorType, list.length(arguments))
      }
      use witness <- result.try(useful(
        specialize(matrix, tag, list.length(arguments)),
        list.append(arguments, rest),
        list.append(fields, tail_types),
        state,
      ))
      Ok([
        Constructor(tag, list.take(witness, list.length(arguments))),
        ..list.drop(witness, list.length(arguments))
      ])
    }
    [Any, ..rest] -> {
      let #(head_type, tail_types) = split_type(types)
      let constructors = signature(head_type, state)
      let seen =
        list.filter_map(matrix, fn(row) {
          case row {
            [Constructor(tag, _), ..] -> Ok(tag)
            _ -> Error(Nil)
          }
        })
        |> list.unique
      let complete =
        constructors != []
        && list.all(constructors, fn(value) { list.contains(seen, value.tag) })
      case complete {
        True -> try_constructors(constructors, matrix, rest, tail_types, state)
        False -> {
          use witness <- result.try(useful(
            defaults(matrix),
            rest,
            tail_types,
            state,
          ))
          let missing = case
            list.find(constructors, fn(value) {
              !list.contains(seen, value.tag)
            })
          {
            Ok(value) ->
              Constructor(
                value.tag,
                list.repeat(Any, list.length(value.fields)),
              )
            Error(Nil) -> Any
          }
          Ok([missing, ..witness])
        }
      }
    }
  }
}

fn descendant_arguments(
  state: unify.State,
  member: nominal.Class,
  ancestor: nominal.Class,
  arguments: List(Type),
) -> List(Type) {
  let viewed =
    unify.upcast(state, nominal.type_(member), nominal.identity(ancestor))
  let mapping = case viewed {
    Ok(monotype.Nominal(arguments: expressions, ..)) ->
      list.zip(expressions, arguments)
      |> list.filter_map(fn(pair) {
        case pair.0 {
          monotype.RigidVariable(id, _) -> Ok(#(id, pair.1))
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
  list.map(member.parameters, fn(parameter) {
    case list.key_find(mapping, parameter.0) {
      Ok(type_) -> type_
      Error(Nil) -> monotype.ErrorType
    }
  })
}

fn split_type(types: List(Type)) -> #(Type, List(Type)) {
  case types {
    [first, ..rest] -> #(first, rest)
    [] -> #(monotype.ErrorType, [])
  }
}

fn try_constructors(
  constructors: List(Signature),
  matrix: List(List(Pattern)),
  rest: List(Pattern),
  tail_types: List(Type),
  state: unify.State,
) -> Result(List(Pattern), Nil) {
  case constructors {
    [] -> Error(Nil)
    [constructor, ..others] -> {
      let arity = list.length(constructor.fields)
      case
        useful(
          specialize(matrix, constructor.tag, arity),
          list.append(list.repeat(Any, arity), rest),
          list.append(constructor.fields, tail_types),
          state,
        )
      {
        Ok(witness) ->
          Ok([
            Constructor(constructor.tag, list.take(witness, arity)),
            ..list.drop(witness, arity)
          ])
        Error(Nil) -> try_constructors(others, matrix, rest, tail_types, state)
      }
    }
  }
}

/// Keep matrix rows compatible with one constructor and expose that constructor's
/// fields as new columns.
///
/// ```text
/// Some(x) -> inspect the column containing x
/// ```
fn specialize(
  matrix: List(List(Pattern)),
  tag: Tag,
  arity: Int,
) -> List(List(Pattern)) {
  list.filter_map(matrix, fn(row) {
    case row {
      [Any, ..rest] -> Ok(list.append(list.repeat(Any, arity), rest))
      [Constructor(found, arguments), ..rest] if found == tag ->
        case list.length(arguments) == arity {
          True -> Ok(list.append(arguments, rest))
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Keep rows whose wildcard-like heads can cover constructors not singled out by
/// the current specialization.
///
/// ```text
/// a wildcard row remains available for an unseen constructor
/// ```
fn defaults(matrix: List(List(Pattern))) -> List(List(Pattern)) {
  list.filter_map(matrix, fn(row) {
    case row {
      [Any, ..rest] -> Ok(rest)
      _ -> Error(Nil)
    }
  })
}

fn show(value: Pattern) -> String {
  case value {
    Any -> "_"
    Constructor(Boolean(True), _) -> "True"
    Constructor(Boolean(False), _) -> "False"
    Constructor(NilValue, _) -> "Nil"
    Constructor(EmptyBits, _) -> "<<>>"
    Constructor(ConsBit, _) -> "<<" <> show_bits(value) <> ">>"
    Constructor(EmptyList, _) -> "[]"
    Constructor(ConsList, _) -> "[" <> show_list(value) <> "]"
    Constructor(Tuple(_), elements) ->
      "#(" <> string.join(list.map(elements, show), ", ") <> ")"
    Constructor(SomeValue, elements) -> application("Some", elements)
    Constructor(NoneValue, _) -> "None"
    Constructor(OkValue, elements) -> application("Ok", elements)
    Constructor(ErrorValue, elements) -> application("Error", elements)

    Constructor(ClassValue(_, name), []) -> name
    Constructor(ClassValue(_, name), elements) -> application(name, elements)
    Constructor(EnumValue(_, enum, variant), _) -> enum <> "." <> variant
    Constructor(Integer(value), _) -> value
    Constructor(Floating(_), _)
    | Constructor(Text(_), _)
    | Constructor(Opaque(_), _) -> "_"
  }
}

fn show_list(value: Pattern) -> String {
  case value {
    Constructor(ConsList, [head, Constructor(EmptyList, [])]) -> show(head)
    Constructor(ConsList, [head, tail]) -> show(head) <> ", " <> show_list(tail)
    Any -> ".."
    _ -> ".."
  }
}

fn application(name: String, arguments: List(Pattern)) -> String {
  name <> "(" <> string.join(list.map(arguments, show), ", ") <> ")"
}

fn show_bits(value: Pattern) -> String {
  case value {
    Any -> "_:bits"
    Constructor(EmptyBits, []) -> ""
    Constructor(ConsBit, [head, tail]) -> {
      let head = case head {
        Constructor(Boolean(True), _) -> "1:1"
        Constructor(Boolean(False), _) -> "0:1"
        _ -> "_:1"
      }
      let rest = show_bits(tail)
      head
      <> case rest {
        "" -> ""
        _ -> ", " <> rest
      }
    }
    _ -> "_:bits"
  }
}
