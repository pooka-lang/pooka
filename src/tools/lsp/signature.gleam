//// Find the active call and read its callable type from editor inference.

// SPDX-License-Identifier: Apache-2.0

import builder/infer
import compiler/lexer/lexer
import compiler/lexer/token
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/lsp/analysis
import tools/lsp/definition

type Call {
  Call(name: String, callee_end: Int, open: Int, argument: Int)
}

type Group {
  Group(close: token.Token, call: Option(Call))
}

pub fn help(
  path: String,
  source: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(#(String, List(String), Int), Nil) {
  use call <- result.try(active_call(source, offset))
  let callable = {
    use #(_, checked) <- result.try(definition.project_report(path, overlays))
    use typed <- result.try(definition.typed_report(checked))
    function_at(typed, path, call.callee_end)
  }
  use #(parameters, returns) <- result.try(
    result.lazy_or(callable, fn() {
      // A call missing its close delimiter may prevent the module from being
      // inferred. Replace the unfinished argument list with an empty call.
      let bytes = <<source:utf8>>
      use before <- result.try(
        bit_array.slice(bytes, 0, call.open) |> result.try(bit_array.to_string),
      )
      use after <- result.try(
        bit_array.slice(bytes, offset, string.byte_size(source) - offset)
        |> result.try(bit_array.to_string),
      )
      let probe = before <> "()" <> after
      let overlays = [
        #(path, probe),
        ..list.filter(overlays, fn(entry) { entry.0 != path })
      ]
      use root <- result.try(analysis.workspace(path))
      use #(_, checked) <- result.try(definition.build_report(root, overlays))
      use typed <- result.try(
        infer.definitions_in_memory(checked) |> result.replace_error(Nil),
      )
      function_at(typed, path, call.callee_end)
    }),
  )
  let #(labels, returns) = monotype.signature(parameters, returns)
  let label =
    call.name <> "(" <> string.join(labels, ", ") <> ") -> " <> returns
  Ok(#(
    label,
    labels,
    int.clamp(call.argument, 0, int.max(0, list.length(labels) - 1)),
  ))
}

fn function_at(report: infer.Report, path: String, offset: Int) {
  use module <- result.try(
    list.find(report.modules, fn(module) {
      definition.absolute_path(report.checked, module.path) == path
    }),
  )
  unify.expression_types(module.inferred.state, module.path)
  |> list.filter(fn(item) { item.1 == offset })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.find_map(fn(item) {
    case item.2 {
      monotype.FunctionType(parameters, returns) -> Ok(#(parameters, returns))
      _ -> Error(Nil)
    }
  })
}

fn active_call(source: String, offset: Int) -> Result(Call, Nil) {
  let #(_, groups) =
    lexer.lex(source).tokens
    |> list.take_while(fn(lexeme) { lexeme.span.end.byte_offset <= offset })
    |> list.fold(#(None, []), fn(state, lexeme) {
      let #(previous, groups) = state
      case lexeme.token {
        token.Comment(_) | token.DocComment(_) | token.ModuleComment(_) -> state
        found -> {
          let next = case found, groups {
            token.LeftParen, _ -> [
              Group(
                token.RightParen,
                call_at(previous, lexeme.span.start.byte_offset),
              ),
              ..groups
            ]
            token.HashLeftParen, _ -> [Group(token.RightParen, None), ..groups]
            token.LeftSquare, _ -> [Group(token.RightSquare, None), ..groups]
            token.LeftBrace, _ -> [Group(token.RightBrace, None), ..groups]
            token.DoubleLess, _ -> [Group(token.DoubleGreater, None), ..groups]
            token.Comma, [Group(close, Some(call)), ..rest] -> [
              Group(close, Some(Call(..call, argument: call.argument + 1))),
              ..rest
            ]
            found, [Group(close, _), ..rest] if found == close -> rest
            _, _ -> groups
          }
          #(Some(lexeme), next)
        }
      }
    })
  list.find_map(groups, fn(group) { option.to_result(group.call, Nil) })
}

fn call_at(previous: Option(token.Lexeme), open: Int) -> Option(Call) {
  case previous {
    Some(token.Lexeme(token: found, span:)) ->
      case found {
        token.Name(_) | token.UpperName(_) | token.New ->
          Some(Call(token.to_source(found), span.end.byte_offset, open, 0))
        _ -> None
      }
    None -> None
  }
}
