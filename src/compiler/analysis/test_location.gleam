//// Keep tests on their own labelled shelf.
////
//// A test declaration belongs in a file ending in `.spec.pooka`. Check the
//// original parsed module before production filtering removes test bodies, so
//// exporting a program cannot quietly conceal a misplaced declaration.
//// Ordinary declarations in a spec file remain ordinary declarations.
////
//// ```text
//// src/main.pooka + test declaration -> location diagnostic
//// test/main.spec.pooka + test declaration -> allowed
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import gleam/string
import utilities/location

/// Check the filename independently of whether this build executes tests.
/// The parser still accepts test syntax; this source-aware pass decides where
/// that declaration is permitted and keeps the diagnostic on its original span.
pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  case string.ends_with(path, ".spec.pooka") {
    True -> []
    False ->
      list.filter_map(module.declarations, fn(declaration) {
        case declaration {
          ast.TestDeclaration(test_case) ->
            Ok(
              diagnostic.error(
                "analysis.test_location",
                "test declaration outside a spec file",
              )
              |> diagnostic.primary(
                location.new(path, test_case.span),
                "tests must be declared in a `.spec.pooka` file",
              )
              |> diagnostic.help(
                "Move this test to a `.spec.pooka` file in the test directory.",
              ),
            )
          _ -> Error(Nil)
        }
      })
  }
}
