//// First read the page; then decide what it says.
////
//// Coordinate lexing, parsing and structural analysis for a source file. Type
//// inference and BEAM emission happen later, so this report can still describe a
//// broken or incomplete program.
////
//// ```text
//// source -> tokens -> syntax -> structural diagnostics
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/context
import compiler/analysis/duplicate
import compiler/analysis/import_binding
import compiler/analysis/inheritance
import compiler/analysis/initialization
import compiler/analysis/resolve
import compiler/analysis/test_location
import compiler/analysis/unused
import compiler/lexer/lex_error
import compiler/lexer/lexer
import compiler/parser/ast
import compiler/parser/parse_error
import compiler/parser/parser
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import utilities/location

pub type Checked {
  Checked(
    path: String,
    source: String,
    lexed: lexer.Lexed,
    parsed: parser.Output,
    structural_diagnostics: List(Diagnostic),
    uses: List(resolve.Use),
    diagnostics: List(Diagnostic),
  )
}

/// Run lexical, syntactic and structural checks with tests included. This is not
/// the final typed bundle accepted by code generation.
///
/// ```text
/// source with a syntax error -> Checked report carrying that error
/// ```
pub fn check_source(path: String, source: String) -> Checked {
  check_source_mode(path, source, True)
}

/// Run structural checking while excluding test declarations from the production
/// source view.
///
/// ```text
/// production build -> test declarations do not become application functions
/// ```
pub fn check_production_source(path: String, source: String) -> Checked {
  check_source_mode(path, source, False)
}

fn check_source_mode(
  path: String,
  source: String,
  include_tests: Bool,
) -> Checked {
  let lexed = lexer.lex(source)
  let parsed = parser.parse(lexed.tokens)
  let test_diagnostics = case lexed.errors, parsed.errors {
    [], [] -> test_location.check(parsed.module, path)
    _, _ -> []
  }
  let parsed = case include_tests {
    True -> parsed
    False ->
      parser.Output(
        ..parsed,
        module: ast.Module(
          ..parsed.module,
          declarations: list.filter(parsed.module.declarations, fn(declaration) {
            case declaration {
              ast.TestDeclaration(_) -> False
              _ -> True
            }
          }),
        ),
      )
  }
  let lex_lines =
    list.map(lexed.errors, fn(error) { lex_error.span(error).start.line })
  let lex_diagnostics = list.map(lexed.errors, lex_error.to_diagnostic(_, path))
  let parse_diagnostics =
    parsed.errors
    |> list.filter(fn(error) {
      !list.contains(lex_lines, parse_error.span(error).start.line)
    })
    |> list.map(parse_error.to_diagnostic(_, path))
  let diagnostics =
    [
      lex_diagnostics,
      parse_diagnostics,
      test_diagnostics,
      module_name_diagnostics(path, parsed.module),

      case lexed.errors, parsed.errors {
        [], [] ->
          list.flatten([
            duplicate.check(parsed.module, path),
            context.check(parsed.module, path),
            import_binding.check(parsed.module, path),
            inheritance.check(parsed.module, path),
            initialization.check(parsed.module, path),
          ])
        _, _ -> []
      },
    ]
    |> list.flatten
    |> diagnostic.sort
  with_exports(
    Checked(
      path:,
      source:,
      lexed:,
      parsed:,
      structural_diagnostics: diagnostics,
      uses: [],
      diagnostics:,
    ),
    dict.new(),
  )
  |> with_lints
}

pub fn expected_module_path(path: String) -> Result(String, Nil) {
  case string.starts_with(path, "src/"), string.ends_with(path, ".pooka") {
    True, True ->
      path
      |> string.drop_start(4)
      |> string.drop_end(string.length(".pooka"))
      |> Ok
    _, _ -> Error(Nil)
  }
}

pub fn expected_module_name(path: String) -> Result(String, Nil) {
  use module_path <- result.try(expected_module_path(path))
  list.last(string.split(module_path, "/"))
}

fn module_name_diagnostics(
  path: String,
  module: ast.Module,
) -> List(Diagnostic) {
  case module.header, expected_module_name(path) {
    Some(header), Ok(expected) if header.name.name != expected -> {
      let at = location.new(path, header.name.span)
      [
        diagnostic.error(
          "module.name_mismatch",
          "module name does not match its file",
        )
        |> diagnostic.primary(
          at,
          "this declares module `" <> header.name.name <> "`",
        )
        |> diagnostic.conclusion(
          "`" <> path <> "` must declare `module " <> expected <> "`.",
        )
        |> diagnostic.note(
          "A module is named after its file, without `.pooka`.",
        )
        |> diagnostic.fix(
          at,
          expected,
          "Rename the module",
          diagnostic.Suggested,
        ),
      ]
    }
    Some(_), Ok(_) | Some(_), Error(Nil) | None, _ -> []
  }
}

pub fn with_exports(file: Checked, exports: resolve.Exports) -> Checked {
  let resolved = case file.lexed.errors, file.parsed.errors {
    [], [] ->
      resolve.resolve_with_exports(file.parsed.module, file.path, exports)
    _, _ -> resolve.Resolution([], [])
  }
  Checked(
    ..file,
    uses: resolved.uses,
    diagnostics: list.append(file.structural_diagnostics, resolved.diagnostics)
      |> diagnostic.sort,
  )
}

pub fn with_lints(file: Checked) -> Checked {
  case diagnostic.has_errors(file.diagnostics) {
    True -> file
    False -> {
      let warnings =
        unused.check(file.parsed.module, file.path, file.uses)
        |> list.filter(fn(value) { !list.contains(file.diagnostics, value) })
      Checked(
        ..file,
        diagnostics: list.append(file.diagnostics, warnings) |> diagnostic.sort,
      )
    }
  }
}
