//// Complete the cursor's unfinished name with a synthetic editor token.

// SPDX-License-Identifier: Apache-2.0

import builder/infer
import compiler/analysis/resolve
import compiler/compiler
import compiler/lexer/lexer
import compiler/lexer/token
import compiler/parser/ast
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import tools/lsp/analysis
import tools/lsp/definition

pub fn complete(
  path: String,
  source: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(#(Int, Int, List(String)), Nil) {
  let tokens = lexer.lex(source).tokens
  let #(start, end) = case
    list.find(tokens, fn(lexeme) {
      case lexeme.token {
        token.Name(_) | token.UpperName(_) ->
          lexeme.span.start.byte_offset <= offset
          && offset <= lexeme.span.end.byte_offset
        _ -> False
      }
    })
  {
    Ok(lexeme) -> #(lexeme.span.start.byte_offset, lexeme.span.end.byte_offset)
    Error(_) -> #(offset, offset)
  }
  use before <- result.try(slice(source, 0, start))
  use prefix <- result.try(slice(source, start, offset - start))
  use after <- result.try(slice(source, end, string.byte_size(source) - end))
  let probe = before <> resolve.completion_marker <> after
  let parsed = compiler.check_editor_source(path, probe).parsed.module
  use scope <- result.try(resolve.editor_completion(parsed, path, start))
  use names <- result.try(case scope {
    resolve.VisibleNames(names) -> Ok(names)
    _ -> {
      let overlays = [
        #(path, probe),
        ..list.filter(overlays, fn(entry) { entry.0 != path })
      ]
      use root <- result.try(analysis.workspace(path))
      use #(graph, checked) <- result.try(definition.build_report(
        root,
        overlays,
      ))
      case scope {
        resolve.VisibleNames(names) -> Ok(names)
        resolve.ModuleAlias(alias) -> {
          use imported <- result.try(
            list.find(parsed.imports, fn(imported) {
              definition.module_alias(imported) == Ok(alias)
            }),
          )
          use file <- result.try(definition.imported_file(
            graph,
            checked,
            path,
            imported.span,
          ))
          file.parsed.module.declarations
          |> list.filter_map(ast.declaration_name)
          |> list.map(fn(name) { name.name })
          |> list.filter(fn(name) { !string.starts_with(name, "_") })
          |> Ok
        }
        resolve.MemberReceiver(span) -> {
          use typed <- result.try(
            infer.definitions_in_memory(checked) |> result.replace_error(Nil),
          )
          use module <- result.try(
            list.find(typed.modules, fn(module) {
              definition.absolute_path(checked, module.path) == path
            }),
          )
          let state = module.inferred.state
          use type_ <- result.try(unify.expression_type(
            state,
            module.path,
            span,
          ))
          member_names(state, type_)
        }
      }
    }
  })
  Ok(#(
    start,
    end,
    names
      |> list.filter(fn(name) { string.starts_with(name, prefix) })
      |> list.unique
      |> list.sort(string.compare),
  ))
}

fn member_names(
  state: unify.State,
  type_: monotype.Type,
) -> Result(List(String), Nil) {
  case type_ {
    monotype.Nominal(module, name, monotype.InterfaceKind, _) ->
      unify.interface(state, #(module, name))
      |> result.map(fn(interface) {
        list.map(interface.methods, fn(method) { method.name.name })
      })
    monotype.Nominal(module, name, kind, _)
      if kind == monotype.ClassKind || kind == monotype.ActorKind
    -> {
      use class <- result.try(unify.class(state, #(module, name)))
      let fields = case class.actor {
        True -> []
        False -> list.map(class.fields, fn(field) { field.name.name })
      }
      Ok(
        list.append(
          fields,
          list.map(class.methods, fn(method) { method.name.name }),
        )
        |> list.filter(fn(name) { !string.starts_with(name, "_") }),
      )
    }
    _ -> Error(Nil)
  }
}

fn slice(source: String, start: Int, length: Int) -> Result(String, Nil) {
  <<source:utf8>>
  |> bit_array.slice(start, length)
  |> result.try(bit_array.to_string)
}
