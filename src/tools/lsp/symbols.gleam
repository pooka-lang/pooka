//// Build the editor outline from the parser's recovered declarations.

// SPDX-License-Identifier: Apache-2.0

import compiler/compiler
import compiler/parser/ast
import gleam/json
import gleam/list
import utilities/location.{type Span}

pub fn outline(path: String, source: String) -> String {
  compiler.check_source(path, source).parsed.module.declarations
  |> json.array(declaration)
  |> json.to_string
}

fn declaration(value: ast.Declaration) -> json.Json {
  case value {
    ast.FunctionDeclaration(f) -> named(f.name, 12, f.span, [])
    ast.ClassDeclaration(c) ->
      named(c.name, 5, c.span, list.map(c.members, member))
    ast.ActorDeclaration(a) ->
      named(a.name, 5, a.span, list.map(a.members, member))
    ast.InterfaceDeclaration(i) ->
      named(
        i.name,
        11,
        i.span,
        list.map(i.requirements, fn(r) { named(r.name, 6, r.span, []) }),
      )
    ast.EnumDeclaration(e) ->
      named(
        e.name,
        10,
        e.span,
        list.map(e.variants, fn(v) { named(v.name, 22, v.name.span, []) }),
      )
    ast.ExternalDeclaration(e) ->
      named(
        e.name,
        3,
        e.span,
        list.map(e.functions, fn(f) { named(f.name, 12, f.span, []) }),
      )
    ast.TestDeclaration(t) -> symbol(t.name, 12, t.span, t.span, [])
  }
}

fn member(value: ast.Member) -> json.Json {
  case value {
    ast.FieldMember(f) -> named(f.name, 8, f.span, [])
    ast.MethodMember(f) | ast.BehaviourMember(f) -> named(f.name, 6, f.span, [])
    ast.ConstructorMember(c) -> symbol("new", 9, c.span, c.span, [])
  }
}

fn named(
  name: ast.Name,
  kind: Int,
  span: Span,
  children: List(json.Json),
) -> json.Json {
  symbol(name.name, kind, span, name.span, children)
}

fn symbol(
  name: String,
  kind: Int,
  span: Span,
  selection: Span,
  children: List(json.Json),
) -> json.Json {
  json.object([
    #("name", json.string(name)),
    #("kind", json.int(kind)),
    #("range", range(span)),
    #("selectionRange", range(selection)),
    #("children", json.array(children, fn(child) { child })),
  ])
}

fn range(span: Span) -> json.Json {
  json.object([
    #(
      "start",
      json.object([#("byte_offset", json.int(span.start.byte_offset))]),
    ),
    #("end", json.object([#("byte_offset", json.int(span.end.byte_offset))])),
  ])
}
