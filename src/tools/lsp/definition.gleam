//// Follow imports using the same module identities that project checking uses.

// SPDX-License-Identifier: Apache-2.0

import builder/check
import builder/infer
import compiler/analysis/resolve
import compiler/compiler
import compiler/lexer/token
import compiler/parser/ast
import compiler/typesystem/monotype
import compiler/typesystem/unify
import filepath
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import project/package
import project/project
import tools/lsp/analysis
import utilities/location.{type Span}

pub fn target(
  path: String,
  source: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(#(String, Int, Int), Nil) {
  let file = compiler.check_editor_source(path, source)
  case resolve.editor_definition(file.parsed.module, path, offset) {
    Ok(resolve.LocalTarget(span)) ->
      Ok(#(path, span.start.byte_offset, span.end.byte_offset))
    Ok(resolve.ImportTarget(reference)) ->
      cross_file_target(file, path, FromReference(reference), overlays)
    Error(_) ->
      case find_import(file, AtImport(offset)) {
        Ok(_) -> cross_file_target(file, path, AtImport(offset), overlays)
        Error(_) -> typed_member_target(file, path, offset, overlays)
      }
  }
}

/// Read hover information from the same unsaved snapshot used for navigation.
pub fn hover(
  path: String,
  source: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(String, Nil) {
  let file = compiler.check_editor_source(path, source)
  use lexeme <- result.try(
    list.find(file.lexed.tokens, fn(lexeme) {
      case lexeme.token {
        token.Name(_) | token.UpperName(_) -> contains(lexeme.span, offset)
        _ -> False
      }
    }),
  )
  use #(_, checked) <- result.try(project_report(path, overlays))
  use typed <- result.try(typed_report(checked))
  use module <- result.try(
    list.find(typed.modules, fn(module) {
      absolute_path(checked, module.path) == path
    }),
  )
  let state = module.inferred.state
  let start = lexeme.span.start.byte_offset
  let end = lexeme.span.end.byte_offset
  let expression =
    unify.expression_types(state, module.path)
    |> list.filter(fn(item) {
      item.0 <= start && item.1 == end && item.2 != monotype.ErrorType
    })
    |> list.sort(fn(a, b) { int.compare(b.0, a.0) })
    |> list.first
    |> result.map(fn(item) { item.2 })
  let declared =
    list.find(module.inferred.functions, fn(function) {
      function.name.span == lexeme.span
    })
  use type_ <- result.try(
    result.lazy_or(expression, fn() {
      result.map(declared, fn(function) { unify.apply(function.type_, state) })
    }),
  )
  let target = case unify.member_definition(state, offset) {
    Ok(location) ->
      Ok(#(
        absolute_path(checked, location.path),
        location.span.start.byte_offset,
      ))
    Error(_) ->
      case resolve.editor_definition(file.parsed.module, path, offset) {
        Ok(resolve.LocalTarget(span)) -> Ok(#(path, span.start.byte_offset))
        Ok(resolve.ImportTarget(_)) ->
          target(path, source, offset, overlays)
          |> result.map(fn(site) { #(site.0, site.1) })
        Error(_) -> Ok(#(path, start))
      }
  }
  let docs = case target {
    Ok(#(target_path, at)) ->
      checked.files
      |> list.find(fn(file) { absolute_path(checked, file.path) == target_path })
      |> result.map(fn(file) { documentation(file.parsed.module, at) })
      |> result.unwrap([])
    Error(_) -> []
  }
  let signature =
    "```pooka\n"
    <> case lexeme.token {
      token.Name(name) | token.UpperName(name) -> name
      _ -> ""
    }
    <> ": "
    <> monotype.to_string(type_)
    <> "\n```"
  Ok(case docs {
    [] -> signature
    _ -> signature <> "\n\n" <> string.join(docs, "\n")
  })
}

fn documentation(module: ast.Module, offset: Int) -> List(String) {
  module.declarations
  |> list.flat_map(fn(declaration) {
    case declaration {
      ast.FunctionDeclaration(value) -> [#(value.name, value.documentation)]
      ast.ClassDeclaration(value) -> member_documentation(value.members)
      ast.ActorDeclaration(value) -> member_documentation(value.members)
      ast.InterfaceDeclaration(value) ->
        list.map(value.requirements, fn(member) {
          #(member.name, member.documentation)
        })
      _ -> []
    }
  })
  |> list.find(fn(entry) { entry.0.span.start.byte_offset == offset })
  |> result.map(fn(entry) { entry.1 })
  |> result.unwrap([])
}

fn member_documentation(
  members: List(ast.Member),
) -> List(#(ast.Name, List(String))) {
  list.filter_map(members, fn(member) {
    case member {
      ast.MethodMember(value) | ast.BehaviourMember(value) ->
        Ok(#(value.name, value.documentation))
      ast.FieldMember(value) -> Ok(#(value.name, value.documentation))
      ast.ConstructorMember(_) -> Error(Nil)
    }
  })
}

fn typed_member_target(
  file: compiler.Checked,
  path: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(#(String, Int, Int), Nil) {
  // Only a name after a dot can need inference. Unresolved names elsewhere
  // should return immediately while the user is typing.
  let tokens = file.lexed.tokens
  let is_member =
    list.zip(tokens, list.drop(tokens, 1))
    |> list.any(fn(pair) {
      case pair {
        #(
          token.Lexeme(token: token.Dot, ..),
          token.Lexeme(token: token.Name(_), span:),
        ) -> contains(span, offset)
        _ -> False
      }
    })
  use _ <- result.try(case is_member {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  use #(_, checked) <- result.try(project_report(path, overlays))
  use typed <- result.try(typed_report(checked))
  use module <- result.try(
    list.find(typed.modules, fn(module) {
      absolute_path(checked, module.path) == path
    }),
  )
  use target <- result.try(unify.member_definition(
    module.inferred.state,
    offset,
  ))
  Ok(#(
    absolute_path(checked, target.path),
    target.span.start.byte_offset,
    target.span.end.byte_offset,
  ))
}

// The navigation worker owns this cache and clears it when the editor
// revision changes. Never retain a failed read or analysis.
@external(erlang, "pooka_lsp_ffi", "navigation_cache")
fn navigation_cache(
  key: #(String, String),
  compute: fn() -> Result(a, Nil),
) -> Result(a, Nil)

pub fn typed_report(checked: check.Report) {
  navigation_cache(#("typed", checked.project.root), fn() {
    infer.definitions_in_memory(checked) |> result.replace_error(Nil)
  })
}

pub fn project_report(path: String, overlays: List(#(String, String))) {
  use root <- result.try(analysis.workspace(path))
  navigation_cache(#("checked", root), fn() { build_report(root, overlays) })
}

pub fn build_report(root: String, overlays: List(#(String, String))) {
  use loaded <- result.try(project.load(root) |> result.replace_error(Nil))
  use graph <- result.try(
    package.resolve_offline(loaded) |> result.replace_error(Nil),
  )
  use report <- result.try(
    check.check_graph_with_overlays(graph, True, dict.from_list(overlays), True)
    |> result.replace_error(Nil),
  )
  Ok(#(graph, report))
}

type ImportQuery {
  FromReference(resolve.ImportReference)
  AtImport(Int)
}

fn cross_file_target(
  current: compiler.Checked,
  path: String,
  query: ImportQuery,
  overlays: List(#(String, String)),
) -> Result(#(String, Int, Int), Nil) {
  use #(original, member) <- result.try(find_import(current, query))
  use #(graph, report) <- result.try(project_report(path, overlays))
  use target <- result.try(imported_file(graph, report, path, original.span))
  use span <- result.try(target_span(target, member))
  Ok(#(
    absolute_path(report, target.path),
    span.start.byte_offset,
    span.end.byte_offset,
  ))
}

pub fn imported_file(
  graph: package.Graph,
  report: check.Report,
  path: String,
  import_span: Span,
) -> Result(compiler.Checked, Nil) {
  let loaded = graph.root
  use file <- result.try(
    list.find(report.files, fn(file) {
      absolute_path(report, file.path) == path
    }),
  )
  use imported <- result.try(
    list.find(file.parsed.module.imports, fn(imported) {
      imported.span == import_span
    }),
  )
  let owner_name = package.owner(file.path, loaded.name)
  use owner <- result.try(
    list.find(graph.packages, fn(p) { p.name == owner_name }),
  )
  let dependencies = case owner_name == loaded.name {
    True -> list.append(owner.dependencies, owner.dev_dependencies)
    False -> owner.dependencies
  }
  let visible = [owner_name, ..list.map(dependencies, fn(dep) { dep.name })]
  let identity = string.join(imported.module.segments, "/")
  let targets =
    list.filter(report.files, fn(file) {
      case compiler.expected_module_path(file.path) {
        Ok(candidate) -> {
          let name = package.module_owner(identity, loaded.name).1
          case name {
            "main" -> candidate == identity
            _ -> package.module_owner(candidate, loaded.name).1 == name
          }
        }
        Error(_) -> False
      }
    })
  let visible_targets =
    list.filter(targets, fn(target) {
      list.contains(visible, package.owner(target.path, loaded.name))
    })
  case targets, visible_targets {
    [_], [target] -> Ok(target)
    _, _ -> Error(Nil)
  }
}

fn find_import(file: compiler.Checked, query: ImportQuery) {
  let candidates =
    list.flat_map(file.parsed.module.imports, fn(imported) {
      case query {
        FromReference(resolve.QualifiedImport(alias, member, constructor)) ->
          case module_alias(imported) == Ok(alias) {
            True -> [#(imported, Some(#(member, constructor)))]
            False -> []
          }
        FromReference(resolve.SelectiveImport(binding, constructor)) ->
          list.filter_map(imported.items, fn(item) {
            let local = case item.alias {
              Some(alias) -> alias.name
              None -> item.name.name
            }
            case local == binding {
              True -> Ok(#(imported, Some(#(item.name.name, constructor))))
              False -> Error(Nil)
            }
          })
        AtImport(offset) -> {
          let on_module =
            contains(imported.module.span, offset)
            || case imported.alias {
              Some(alias) -> contains(alias.span, offset)
              None -> False
            }
          case on_module {
            True -> [#(imported, None)]
            False ->
              list.filter_map(imported.items, fn(item) {
                case contains(item.span, offset) {
                  True -> Ok(#(imported, Some(#(item.name.name, False))))
                  False -> Error(Nil)
                }
              })
          }
        }
      }
    })
  case candidates {
    [target] -> Ok(target)
    _ -> Error(Nil)
  }
}

pub fn module_alias(imported: ast.Import) -> Result(String, Nil) {
  case imported.alias {
    Some(alias) -> Ok(alias.name)
    None -> list.last(imported.module.segments)
  }
}

fn target_span(
  target: compiler.Checked,
  member: Option(#(String, Bool)),
) -> Result(Span, Nil) {
  case member {
    None ->
      Ok(case target.parsed.module.header {
        Some(header) -> header.name.span
        None -> location.Span(location.start(), location.start())
      })
    Some(#(member, constructor)) -> {
      let constructor = case constructor && !string.starts_with(member, "_") {
        True -> resolve.constructor_span(target.parsed.module, member)
        False -> Error(Nil)
      }
      use <- result.lazy_unwrap(constructor |> result.map(Ok))

      let names =
        list.filter_map(target.parsed.module.declarations, ast.declaration_name)
      case
        list.filter(names, fn(name) {
          name.name == member && !string.starts_with(member, "_")
        })
      {
        [name] -> Ok(name.span)
        _ -> Error(Nil)
      }
    }
  }
}

fn contains(span: Span, offset: Int) -> Bool {
  span.start.byte_offset <= offset && offset < span.end.byte_offset
}

pub fn absolute_path(report: check.Report, path: String) -> String {
  let displayed = check.display_path(report, path)
  case filepath.is_absolute(displayed) {
    True -> displayed
    False -> filepath.join(report.project.root, displayed)
  }
}
