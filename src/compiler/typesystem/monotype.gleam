//// Types are the labels on the type checker's jars.
////
//// Describe primitive, container, function and nominal types without
//// quantification. Substitution and formatting walk the same structure while
//// keeping flexible variables distinct from rigid promises.
////
//// ```text
//// List(Variable(0)) with 0 := Int -> List(Int)
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string

pub type NominalKind {
  ClassKind
  InterfaceKind
  ActorKind

  EnumKind
}

pub type Type {
  Variable(id: Int)

  RigidVariable(id: Int, name: String)
  IntType
  FloatType
  StringType
  BoolType
  NilType
  BitArrayType
  PidType
  ListType(element: Type)
  TupleType(elements: List(Type))
  FunctionType(parameters: List(Type), result: Type)
  OptionType(value: Type)
  ResultType(value: Type, error: Type)
  Nominal(
    module: String,
    name: String,
    kind: NominalKind,
    arguments: List(Type),
  )

  ErrorType
}

/// Collect flexible type-variable IDs recursively. Rigid variables are promises
/// with a separate identity and do not belong to this set.
///
/// ```text
/// fn(Variable(0)) -> List(Variable(1)) has variables {0,1}
/// ```
pub fn variables(value: Type) -> Set(Int) {
  case value {
    Variable(id) -> set.from_list([id])
    ListType(value) | OptionType(value) -> variables(value)
    TupleType(elements) | Nominal(arguments: elements, ..) ->
      variables_in(elements)
    FunctionType(parameters, result) -> variables_in([result, ..parameters])
    ResultType(value, error) -> variables_in([value, error])
    RigidVariable(..)
    | IntType
    | FloatType
    | StringType
    | BoolType
    | NilType
    | BitArrayType
    | PidType
    | ErrorType -> set.new()
  }
}

fn variables_in(values: List(Type)) -> Set(Int) {
  list.fold(values, set.new(), fn(found, value) {
    set.union(found, variables(value))
  })
}

/// Apply a supplied flexible-variable substitution structurally, leaving rigid
/// variables untouched.
///
/// ```text
/// {0 -> Int} applied to List(Variable(0)) gives List(Int)
/// ```
pub fn replace(value: Type, replacements: Dict(Int, Type)) -> Type {
  case value {
    Variable(id) ->
      case dict.get(replacements, id) {
        Ok(value) -> value
        Error(Nil) -> value
      }
    ListType(value) -> ListType(replace(value, replacements))
    OptionType(value) -> OptionType(replace(value, replacements))
    TupleType(elements) ->
      TupleType(list.map(elements, replace(_, replacements)))
    FunctionType(parameters, result) ->
      FunctionType(
        list.map(parameters, replace(_, replacements)),
        replace(result, replacements),
      )
    ResultType(value, error) ->
      ResultType(replace(value, replacements), replace(error, replacements))
    Nominal(module, name, kind, arguments) ->
      Nominal(module, name, kind, list.map(arguments, replace(_, replacements)))
    RigidVariable(..)
    | IntType
    | FloatType
    | StringType
    | BoolType
    | NilType
    | BitArrayType
    | PidType
    | ErrorType -> value
  }
}

/// Render a readable type with consistent variable names. Formatting is
/// presentation, never nominal identity.
///
/// ```text
/// FunctionType([IntType], BoolType) -> fn(Int) -> Bool
/// ```
pub fn to_string(value: Type) -> String {
  format(value, dict.new()).0
}

fn format(
  value: Type,
  names: Dict(Int, String),
) -> #(String, Dict(Int, String)) {
  case value {
    Variable(id) ->
      case dict.get(names, id) {
        Ok(name) -> #(name, names)
        Error(Nil) -> {
          let name = variable_name(dict.size(names))
          #(name, dict.insert(names, id, name))
        }
      }
    RigidVariable(_, name) -> #(name, names)
    IntType -> #("Int", names)
    FloatType -> #("Float", names)
    StringType -> #("String", names)
    BoolType -> #("Bool", names)
    NilType -> #("Nil", names)
    BitArrayType -> #("BitArray", names)
    PidType -> #("Pid", names)
    ErrorType -> #("<error>", names)
    ListType(value) -> applied("List", [value], names)
    OptionType(value) -> applied("Option", [value], names)
    ResultType(value, error) -> applied("Result", [value, error], names)
    TupleType(elements) -> {
      let #(elements, names) = format_list(elements, names)
      #("#(" <> string.join(elements, ", ") <> ")", names)
    }
    FunctionType(parameters, result) -> {
      let #(parameters, names) = format_list(parameters, names)
      let #(result, names) = format(result, names)
      #("fn(" <> string.join(parameters, ", ") <> ") -> " <> result, names)
    }
    Nominal(module, name, _, arguments) -> {
      let qualified = case module {
        "" | "$core" -> name
        _ -> module <> "." <> name
      }
      applied(qualified, arguments, names)
    }
  }
}

fn applied(
  name: String,
  arguments: List(Type),
  names: Dict(Int, String),
) -> #(String, Dict(Int, String)) {
  case arguments {
    [] -> #(name, names)
    _ -> {
      let #(arguments, names) = format_list(arguments, names)
      #(name <> "(" <> string.join(arguments, ", ") <> ")", names)
    }
  }
}

fn format_list(
  values: List(Type),
  names: Dict(Int, String),
) -> #(List(String), Dict(Int, String)) {
  let #(reversed, names) =
    list.fold(values, #([], names), fn(state, value) {
      let #(found, names) = state
      let #(value, names) = format(value, names)
      #([value, ..found], names)
    })
  #(list.reverse(reversed), names)
}

fn variable_name(index: Int) -> String {
  let letter =
    string.slice(
      "abcdefghijklmnopqrstuvwxyz",
      int.remainder(index, 26) |> result.unwrap(0),
      1,
    )
  case index < 26 {
    True -> letter
    False -> variable_name(index / 26 - 1) <> letter
  }
}

/// Format expected and found types using one naming context, so the same variable
/// is not given two different names in one error.
///
/// ```text
/// expected fn(a) -> a; found fn(b) -> Int
/// ```
pub fn format_pair(expected: Type, found: Type) -> #(String, String) {
  let #(expected, names) = format(expected, dict.new())
  let #(found, _) = format(found, names)
  #(expected, found)
}

/// Collect universal rigid-variable IDs through the entire type structure.
///
/// ```text
/// List(RigidVariable(7, a)) contributes rigid ID 7
/// ```
pub fn rigids(value: Type) -> Set(Int) {
  case value {
    RigidVariable(id, _) -> set.from_list([id])
    ListType(value) | OptionType(value) -> rigids(value)
    TupleType(elements) | Nominal(arguments: elements, ..) ->
      list.fold(elements, set.new(), fn(found, value) {
        set.union(found, rigids(value))
      })
    FunctionType(parameters, result) ->
      rigids(TupleType([result, ..parameters]))
    ResultType(value, error) -> rigids(TupleType([value, error]))
    Variable(_)
    | IntType
    | FloatType
    | StringType
    | BoolType
    | NilType
    | BitArrayType
    | PidType
    | ErrorType -> set.new()
  }
}

/// Replace only the selected rigid IDs after their universal checks are complete.
/// Unselected rigid promises stay rigid.
///
/// ```text
/// method-local rigid b -> fresh result variable; captured rigid a stays a
/// ```
pub fn replace_rigids(value: Type, replacements: Dict(Int, Type)) -> Type {
  case value {
    RigidVariable(id, _) ->
      case dict.get(replacements, id) {
        Ok(value) -> value
        Error(Nil) -> value
      }
    ListType(value) -> ListType(replace_rigids(value, replacements))
    OptionType(value) -> OptionType(replace_rigids(value, replacements))
    TupleType(elements) ->
      TupleType(list.map(elements, replace_rigids(_, replacements)))
    FunctionType(parameters, result) ->
      FunctionType(
        list.map(parameters, replace_rigids(_, replacements)),
        replace_rigids(result, replacements),
      )
    ResultType(value, error) ->
      ResultType(
        replace_rigids(value, replacements),
        replace_rigids(error, replacements),
      )
    Nominal(module, name, kind, arguments) ->
      Nominal(
        module,
        name,
        kind,
        list.map(arguments, replace_rigids(_, replacements)),
      )
    Variable(_)
    | IntType
    | FloatType
    | StringType
    | BoolType
    | NilType
    | BitArrayType
    | PidType
    | ErrorType -> value
  }
}
