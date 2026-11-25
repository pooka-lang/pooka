//// Classify Pooka declarations and resolved reads for editor highlighting.

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/resolve
import compiler/compiler
import compiler/lexer/token
import compiler/parser/ast
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import utilities/location.{type Span}

pub type Kind {
  Namespace
  Class
  Interface
  Enum
  Function
  Method
  Property
  Parameter
  Variable
  EnumMember
}

pub fn legend() -> List(String) {
  [
    "namespace",
    "class",
    "interface",
    "enum",
    "function",
    "method",
    "property",
    "parameter",
    "variable",
    "enumMember",
  ]
}

pub fn tokens(path: String, source: String) -> List(#(Int, Int, Int, Int)) {
  let file = compiler.check_editor_source(path, source)
  let module = file.parsed.module
  let declarations =
    list.flat_map(module.declarations, declaration)
    |> list.append(
      list.map(resolve.editor_bindings(module, path), fn(span) {
        #(span, Variable)
      }),
      _,
    )
    |> list.append(case module.header {
      Some(header) -> [#(header.name.span, Namespace)]
      None -> []
    })
    |> list.append(
      list.filter_map(module.imports, fn(import_) {
        case import_.alias {
          Some(alias) -> Ok(#(alias.span, Namespace))
          None -> Error(Nil)
        }
      }),
    )
    |> dict.from_list
  let reads =
    resolve.editor_references(module, path)
    |> list.filter_map(fn(pair) {
      case pair.1 {
        resolve.LocalTarget(target) if target != pair.0 ->
          dict.get(declarations, target)
          |> result.map(fn(kind) { #(pair.0, kind) })
        _ -> Error(Nil)
      }
    })
    |> dict.from_list
  // Only whole name tokens carry semantic highlighting. Recovered spans can
  // also represent constructor expressions or synthesized field assignments.
  file.lexed.tokens
  |> list.filter_map(fn(lexeme) {
    case lexeme.token {
      token.Name(_) | token.UpperName(_) -> {
        let span = lexeme.span
        case dict.get(declarations, span), dict.get(reads, span) {
          Ok(kind), _ -> Ok(entry(span, kind, True))
          Error(_), Ok(kind) -> Ok(entry(span, kind, False))
          _, _ -> Error(Nil)
        }
      }
      _ -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
}

fn entry(span: Span, kind: Kind, declaration: Bool) -> #(Int, Int, Int, Int) {
  let index = case kind {
    Namespace -> 0
    Class -> 1
    Interface -> 2
    Enum -> 3
    Function -> 4
    Method -> 5
    Property -> 6
    Parameter -> 7
    Variable -> 8
    EnumMember -> 9
  }
  let readonly = case kind {
    Parameter | Variable -> 2
    _ -> 0
  }
  let modifiers = case declaration {
    True -> 1 + readonly
    False -> readonly
  }
  #(span.start.byte_offset, span.end.byte_offset, index, modifiers)
}

fn declaration(declaration: ast.Declaration) -> List(#(Span, Kind)) {
  case declaration {
    ast.FunctionDeclaration(function) -> [
      #(function.name.span, Function),
      ..parameters(function.parameters)
    ]
    ast.ClassDeclaration(class) -> [
      #(class.name.span, Class),
      ..list.flat_map(class.members, member)
    ]
    ast.ActorDeclaration(actor) -> [
      #(actor.name.span, Class),
      ..list.flat_map(actor.members, member)
    ]
    ast.InterfaceDeclaration(interface) -> [
      #(interface.name.span, Interface),
      ..list.flat_map(interface.requirements, fn(requirement) {
        [#(requirement.name.span, Method), ..parameters(requirement.parameters)]
      })
    ]
    ast.EnumDeclaration(enum) -> [
      #(enum.name.span, Enum),
      ..list.map(enum.variants, fn(variant) { #(variant.name.span, EnumMember) })
    ]
    ast.ExternalDeclaration(external) -> [
      #(external.name.span, Namespace),
      ..list.flat_map(external.functions, fn(function) {
        [#(function.name.span, Function), ..parameters(function.parameters)]
      })
    ]
    ast.TestDeclaration(_) -> []
  }
}

fn member(member: ast.Member) -> List(#(Span, Kind)) {
  case member {
    ast.FieldMember(field) -> [#(field.name.span, Property)]
    ast.MethodMember(method) | ast.BehaviourMember(method) -> [
      #(method.name.span, Method),
      ..parameters(method.parameters)
    ]
    ast.ConstructorMember(constructor) -> parameters(constructor.parameters)
  }
}

fn parameters(parameters: List(ast.Parameter)) -> List(#(Span, Kind)) {
  list.filter_map(parameters, fn(parameter) {
    case parameter.name {
      ast.DiscardedParameter -> Error(Nil)
      ast.NamedParameter(name) -> {
        let start = parameter.span.start
        let end =
          location.Position(
            ..start,
            column: start.column + string.length(name),
            byte_offset: start.byte_offset + string.byte_size(name),
          )
        Ok(#(location.Span(start, end), Parameter))
      }
    }
  })
}
