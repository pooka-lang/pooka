//// Clear the throat before sending a debug print into the world.
////
//// Name resolution tells us whether echo belongs to the builtin or a local
//// binding. Inspect those uses rather than searching source text, so comments,
//// examples and a user's own echo function keep their ordinary meaning.
////
//// ```pooka
//// answer() { echo 42 } // warning at echo; publication is still allowed
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/resolve
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import utilities/location

pub fn check(uses: List(resolve.Use), path: String) -> List(Diagnostic) {
  list.filter_map(uses, fn(use_) {
    case use_.reference {
      resolve.BuiltinReference("echo", span) ->
        Ok(
          diagnostic.warning("publish.echo", "debug output in published code")
          |> diagnostic.primary(
            location.new(path, span),
            "this echo remains in the published package",
          )
          |> diagnostic.help(
            "Remove the debug print before publishing, or keep it intentionally. This warning does not prevent publication.",
          ),
        )
      _ -> Error(Nil)
    }
  })
}
