//// A Result should not leave its error unopened on the floor.
////
//// Inspect completed expression types after module inference has settled.
//// Only non-final expression statements discard their value implicitly;
//// bindings, explicit discards and returned block values keep their meaning.
////
//// ```pooka
//// read()       // warn when another statement follows
//// let _ = read() // an explicit choice; keep quiet
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/blocks
import compiler/parser/ast
import compiler/typesystem/monotype
import compiler/typesystem/unify
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import utilities/location

pub fn check(
  module: ast.Module,
  state: unify.State,
  path: String,
) -> List(Diagnostic) {
  blocks.in_module(module)
  |> list.flat_map(fn(block) {
    block.statements
    |> list.take(list.length(block.statements) - 1)
    |> list.filter_map(fn(statement) {
      case statement {
        ast.ExpressionStatement(value) -> {
          let span = ast.expression_span(value)
          case unify.expression_type(state, path, span) {
            Ok(monotype.ResultType(_, _)) ->
              Ok(
                diagnostic.warning("type.discarded_result", "discarded Result")
                |> diagnostic.primary(
                  location.new(path, span),
                  "this Result is discarded, so its error will go unnoticed",
                )
                |> diagnostic.help(
                  "Handle the Result with match or ?, or write `let _ =` to discard it explicitly.",
                ),
              )
            _ -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    })
  })
}
