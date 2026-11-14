//// Built-in types already have a name on the door.
////
//// Reject nominal declarations that would give an existing type a second
//// meaning. Run this structural check before inference, so the declaration
//// receives one useful error rather than mismatches at its later uses.
////
//// ```pooka
//// class Pid {} // Pid already names the built-in process identifier type.
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import gleam/result
import utilities/location

/// Reserve built-in names for types, without reserving enum variants or members.
///
/// ```pooka
/// class Process {} // Choose a fresh name; annotations may still use Pid.
/// ```
pub fn check(module: ast.Module, path: String) -> List(Diagnostic) {
  list.filter_map(module.declarations, fn(declaration) {
    use name <- result.try(declaration_name(declaration))
    case
      list.contains(
        [
          "Int", "Float", "String", "Bool", "Nil", "BitArray", "UtfCodepoint",
          "Pid", "List", "Option", "Result",
        ],
        name.name,
      )
    {
      False -> Error(Nil)
      True ->
        Ok(
          diagnostic.error(
            "analysis.builtin_type_name",
            "built-in type name redeclared",
          )
          |> diagnostic.primary(
            location.new(path, name.span),
            "`" <> name.name <> "` already names a built-in type",
          )
          |> diagnostic.help(
            "Choose a different declaration name. The built-in type `"
            <> name.name
            <> "` can be used directly in annotations, without declaring or importing it.",
          ),
        )
    }
  })
}

fn declaration_name(declaration: ast.Declaration) -> Result(ast.Name, Nil) {
  case declaration {
    ast.ClassDeclaration(value) -> Ok(value.name)
    ast.ActorDeclaration(value) -> Ok(value.name)
    ast.InterfaceDeclaration(value) -> Ok(value.name)
    ast.EnumDeclaration(value) -> Ok(value.name)
    _ -> Error(Nil)
  }
}
