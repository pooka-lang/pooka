//// Run the editor protocol without mixing command output into its stream.

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Environment, type Outcome, Info, Outcome}
import gleam/string

pub const info =
  Info("lsp", "", "Run the language server, to be used by editors")

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments, environment.inherit_stdio {
    [], True -> Outcome("", "", serve())
    [], False ->
      command.failure("error: lsp requires process stdin and stdout\n")
    _, _ ->
      Outcome(
        "",
        "error: unexpected arguments: "
          <> string.join(arguments, " ")
          <> "\n\nUsage: pooka lsp\n",
        2,
      )
  }
}

@external(erlang, "pooka_lsp_ffi", "serve")
fn serve() -> Int
