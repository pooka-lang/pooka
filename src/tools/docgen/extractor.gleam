//// Pull the public promises out of the checked manuscript.
////
//// Build documentation entries from declarations, attached comments and inferred
//// signatures. Private declarations stay out of the public API model.
////
//// ```text
//// /// Read a value. + public function -> documented API entry
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/infer
import compiler/compiler
import compiler/parser/ast
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/docgen/model
import utilities/location.{type Span, Span}

/// Read module documentation from Module.documentation and declaration
/// documentation from its own attached syntax field. These are separate comment
/// streams.
///
/// ```text
/// //// overview -> module page; /// function note -> API entry
/// ```
pub fn extract(
  file: compiler.Checked,
  typed: infer.TypedModule,
) -> model.Module {
  model.Module(
    typed.identity,
    file.path,
    comments(file.parsed.module.documentation),
    file.parsed.module.imports,
    file.parsed.module.declarations
      |> list.filter_map(fn(declaration) {
        use name <- result.try(ast.declaration_name(declaration))
        case public(name.name) {
          False -> Error(Nil)
          True -> Ok(declaration_entry(file.source, declaration, typed))
        }
      }),
  )
}

fn declaration_entry(
  source: String,
  declaration: ast.Declaration,
  typed: infer.TypedModule,
) -> model.Entry {
  case declaration {
    ast.FunctionDeclaration(f) -> {
      let type_ =
        list.find(typed.inferred.functions, fn(value) {
          value.name.name == f.name.name
        })
        |> result.map(fn(value) { monotype.to_string(value.type_) })
        |> option
      entry(
        f.name.name,
        "function",
        header(source, f.span, f.body.span),
        type_,
        f.documentation,
        f.span,
        [],
      )
    }
    ast.ClassDeclaration(c) ->
      entry(
        c.name.name,
        "class",
        opening(source, c.span),
        None,
        c.documentation,
        c.span,
        members(source, c.members, typed, c.name.name),
      )
    ast.ActorDeclaration(a) ->
      entry(
        a.name.name,
        "actor",
        opening(source, a.span),
        None,
        a.documentation,
        a.span,
        members(source, a.members, typed, a.name.name),
      )
    ast.InterfaceDeclaration(i) ->
      entry(
        i.name.name,
        "interface",
        opening(source, i.span),
        None,
        i.documentation,
        i.span,
        i.requirements
          |> list.filter(fn(r) { public(r.name.name) })
          |> list.map(fn(r) {
            entry(
              r.name.name,
              "method",
              text(source, r.span),
              None,
              r.documentation,
              r.span,
              [],
            )
          }),
      )
    ast.ExternalDeclaration(e) ->
      entry(
        e.name.name,
        case e.language {
          ast.Native -> "native"
          _ -> "external"
        },
        opening(source, e.span),
        None,
        e.documentation,
        e.span,
        e.functions
          |> list.filter(fn(f) { public(f.name.name) })
          |> list.map(fn(f) {
            entry(
              f.name.name,
              "function",
              text(source, f.span),
              None,
              f.documentation,
              f.span,
              [],
            )
          }),
      )
    ast.EnumDeclaration(e) ->
      entry(
        e.name.name,
        "enum",
        opening(source, e.span),
        None,
        e.documentation,
        e.span,
        list.map(e.variants, fn(v) {
          entry(
            v.name.name,
            "variant",
            e.name.name <> "." <> v.name.name,
            None,
            v.documentation,
            v.name.span,
            [],
          )
        }),
      )
    ast.TestDeclaration(_) -> panic as "tests have no API name"
  }
}

fn members(
  source: String,
  values: List(ast.Member),
  typed: infer.TypedModule,
  name: String,
) -> List(model.Entry) {
  let class =
    unify.classes_for_path(typed.inferred.state, typed.path)
    |> list.find(fn(c) { c.source.name.name == name })
  list.filter_map(values, fn(value) {
    case value {
      ast.BehaviourMember(_) -> Error(Nil)
      ast.MethodMember(f) ->
        case public(f.name.name) {
          False -> Error(Nil)
          True -> {
            let type_ =
              class
              |> result.try(fn(c) {
                list.find(c.methods, fn(m) { m.name.name == f.name.name })
              })
              |> result.map(fn(m) {
                monotype.to_string(unify.apply(m.type_, typed.inferred.state))
              })
              |> option
            Ok(
              entry(
                f.name.name,
                "method",
                header(source, f.span, f.body.span),
                type_,
                f.documentation,
                f.span,
                [],
              ),
            )
          }
        }
      ast.FieldMember(f) ->
        case public(f.name.name) {
          False -> Error(Nil)
          True -> {
            let type_ =
              class
              |> result.try(fn(c) {
                list.find(c.fields, fn(v) { v.name.name == f.name.name })
              })
              |> result.map(fn(v) {
                monotype.to_string(unify.apply(v.type_, typed.inferred.state))
              })
              |> option
            let signature =
              text(source, f.span)
              |> string.split("=")
              |> list.first
              |> result.unwrap(f.name.name)
              |> string.trim
            Ok(
              entry(
                f.name.name,
                "field",
                signature,
                type_,
                f.documentation,
                f.span,
                [],
              ),
            )
          }
        }
      ast.ConstructorMember(c) -> {
        let type_ =
          class
          |> result.map(fn(c) {
            monotype.to_string(unify.apply(c.constructor, typed.inferred.state))
          })
          |> option
        Ok(
          entry(
            "new",
            "constructor",
            header(source, c.span, c.body.span),
            type_,
            c.documentation,
            c.span,
            [],
          ),
        )
      }
    }
  })
}

fn entry(
  name: String,
  kind: String,
  signature: String,
  inferred: Option(String),
  docs: List(String),
  span: Span,
  children: List(model.Entry),
) -> model.Entry {
  model.Entry(
    name,
    kind,
    signature,
    inferred,
    comments(docs),
    span.start.line,
    children,
  )
}

fn option(value: Result(String, Nil)) {
  case value {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn public(name: String) {
  !string.starts_with(name, "_")
}

fn comments(lines: List(String)) {
  lines
  |> list.map(fn(line) {
    case line {
      " " <> rest -> rest
      _ -> line
    }
  })
  |> string.join("\n")
}

fn text(source: String, span: Span) {
  location.text(source, span) |> string.trim
}

fn header(source: String, span: Span, body: Span) {
  text(source, Span(span.start, body.start))
}

fn opening(source: String, span: Span) {
  text(source, span)
  |> string.split("{")
  |> list.first
  |> result.unwrap("")
  |> string.trim
}
