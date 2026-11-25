//// Rename lexical symbols with versioned edits and conservative capture checks.

// SPDX-License-Identifier: Apache-2.0

import builder/check
import compiler/analysis/resolve
import compiler/lexer/lexer
import compiler/lexer/token
import compiler/parser/ast
import diagnostics/diagnostic
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import project/package
import tools/lsp/definition
import tools/lsp/references.{type Site}
import utilities/location.{type Span}

type Plan {
  Plan(selection: Span, name: String, sites: List(Site), function: Bool)
}

pub fn prepare(
  path: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(#(Int, Int, String), String) {
  use plan <- result.try(plan(path, offset, overlays))
  Ok(#(
    plan.selection.start.byte_offset,
    plan.selection.end.byte_offset,
    plan.name,
  ))
}

pub fn edits(
  path: String,
  offset: Int,
  name: String,
  overlays: List(#(String, String)),
) -> Result(List(#(String, Int, Int, String)), String) {
  use plan <- result.try(plan(path, offset, overlays))
  use _ <- result.try(case lexer.lex(name) {
    lexer.Lexed(
      [token.Lexeme(token.Name(parsed), _), token.Lexeme(token.EndOfFile, _)],
      [],
    )
      if parsed == name
    -> Ok(Nil)
    _ -> Error("Enter a valid lower-case Pooka identifier.")
  })
  use _ <- result.try(
    case
      plan.function
      && string.starts_with(plan.name, "_") != string.starts_with(name, "_")
    {
      True -> Error("Rename cannot change a function's visibility.")
      False -> Ok(Nil)
    },
  )
  use #(_, checked) <- result.try(
    definition.project_report(path, overlays)
    |> result.replace_error("Could not read the project."),
  )
  let paths = list.map(plan.sites, fn(site) { site.path })
  let collision =
    list.any(checked.files, fn(file) {
      list.contains(paths, definition.absolute_path(checked, file.path))
      && list.any(file.lexed.tokens, fn(lexeme) {
        lexeme.token == token.Name(name)
      })
    })
  case name == plan.name, collision {
    True, _ -> Ok([])
    False, True ->
      Error(
        "That name already occurs in an affected file. Choose a fresh name.",
      )
    False, False -> {
      let sources = check.sources(checked)
      list.try_map(plan.sites, fn(site) {
        let stored_path = case
          list.find(checked.files, fn(file) {
            definition.absolute_path(checked, file.path) == site.path
          })
        {
          Ok(file) -> file.path
          Error(_) -> site.path
        }
        use source <- result.try(
          dict.get(sources, stored_path)
          |> result.replace_error("Could not read a rename target."),
        )
        Ok(#(
          site.path,
          site.span.start.byte_offset,
          site.span.end.byte_offset,
          source,
        ))
      })
    }
  }
}

fn plan(
  path: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(Plan, String) {
  use lookup <- result.try(
    references.lookup(path, offset, overlays)
    |> result.replace_error("No resolved symbol at the cursor."),
  )
  use #(graph, checked) <- result.try(
    definition.project_report(path, overlays)
    |> result.replace_error("Could not read the project."),
  )
  let project_files =
    list.filter(checked.files, fn(file) {
      package.owner(file.path, graph.root.name) == graph.root.name
    })
  use _ <- result.try(
    case
      list.any(project_files, fn(file) {
        file.lexed.errors != [] || file.parsed.errors != []
      })
    {
      True -> Error("Fix the project's syntax errors before renaming.")
      False -> Ok(Nil)
    },
  )
  use _ <- result.try(case diagnostic.has_errors(check.diagnostics(checked)) {
    True -> Error("Fix project name resolution errors before renaming.")
    False -> Ok(Nil)
  })
  let selected =
    list.find(lookup.occurrences, fn(use_) { at(use_.site, path, offset) })
  let alias = case selected {
    Ok(use_) -> use_.alias
    Error(_) ->
      list.find_map(lookup.occurrences, fn(use_) {
        case use_.alias {
          Some(alias) ->
            case at(alias, path, offset) {
              True -> Ok(alias)
              False -> Error(Nil)
            }
          None -> Error(Nil)
        }
      })
      |> option.from_result
  }
  let #(target, selected_sites) = case alias {
    Some(alias) -> #(
      alias,
      list.filter(lookup.occurrences, fn(use_) { use_.alias == Some(alias) }),
    )
    None -> #(
      lookup.target,
      list.filter(lookup.occurrences, fn(use_) { use_.alias == None }),
    )
  }
  use file <- result.try(
    list.find(project_files, fn(file) {
      definition.absolute_path(checked, file.path) == target.path
    })
    |> result.replace_error("This declaration is outside the project."),
  )
  let function =
    alias == None
    && list.any(file.parsed.module.declarations, fn(declaration) {
      case declaration {
        ast.FunctionDeclaration(function) -> function.name.span == target.span
        _ -> False
      }
    })
  use _ <- result.try(
    case
      alias != None
      || function
      || resolve.editor_binding(file.parsed.module, file.path, target.span)
    {
      True -> Ok(Nil)
      False ->
        Error(
          "Rename supports local bindings, module functions, and selective import aliases.",
        )
    },
  )
  use name <- result.try(
    list.find_map(file.lexed.tokens, fn(lexeme) {
      case lexeme {
        token.Lexeme(token.Name(name), span) if span == target.span -> Ok(name)
        _ -> Error(Nil)
      }
    })
    |> result.replace_error("The declaration has no editable name."),
  )
  let sites =
    [target, ..list.map(selected_sites, fn(use_) { use_.site })] |> list.unique
  let selection =
    selected
    |> result.map(fn(use_) { use_.site.span })
    |> result.unwrap(target.span)
  Ok(Plan(selection, name, sites, function))
}

fn at(site: Site, path: String, offset: Int) -> Bool {
  site.path == path
  && site.span.start.byte_offset <= offset
  && offset < site.span.end.byte_offset
}
