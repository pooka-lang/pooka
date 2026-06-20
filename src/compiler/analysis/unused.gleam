//// Ask gently whether a binding was meant to be forgotten.
////
//// Use resolved references to report unused declarations and local names.
//// Explicitly discarded names carry the programmer's intention and should not
//// become noisy warnings.
////
//// ```text
//// let _ignored = value -> deliberate discard
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/resolve
import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import gleam/string
import utilities/location.{Span}

pub fn check(
  module: ast.Module,
  path: String,
  uses: List(resolve.Use),
) -> List(Diagnostic) {
  let references =
    list.map(uses, fn(value) { value.reference }) |> set.from_list
  let imports =
    list.flat_map(module.imports, import_warning(_, path, references))
  list.flatten([
    imports,
    private_warnings(module, path, uses),
    member_warnings(module, path, references),
  ])
  |> diagnostic.sort
}

fn import_alias(value: ast.Import) -> String {
  case value.alias {
    Some(alias) -> alias.name
    None ->
      case list.last(value.module.segments) {
        Ok(name) -> name
        Error(Nil) -> ""
      }
  }
}

fn item_alias(value: ast.ImportedName) -> String {
  case value.alias {
    Some(alias) -> alias.name
    None -> value.name.name
  }
}

fn import_warning(
  value: ast.Import,
  path: String,
  references: Set(resolve.Reference),
) -> List(Diagnostic) {
  let used =
    set.contains(references, resolve.ModuleReference(import_alias(value)))
    || list.any(value.items, fn(item) {
      set.contains(references, resolve.ImportedReference(item_alias(item)))
    })
  case used {
    False -> [
      diagnostic.warning("analysis.unused_import", "unused import")
      |> diagnostic.primary(
        location.new(path, value.span),
        "`"
          <> string.join(value.module.segments, "/")
          <> "` is never referenced",
      )
      |> diagnostic.conclusion(
        "Remove this import to keep the module's dependencies clear.",
      )
      |> diagnostic.fix(
        location.new(path, value.span),
        "",
        "Remove the unused import",
        diagnostic.Automatic,
      ),
    ]
    True ->
      list.index_fold(value.items, [], fn(found, item, index) {
        let name = item_alias(item)
        case set.contains(references, resolve.ImportedReference(name)) {
          True -> found
          False ->
            list.append(found, [
              diagnostic.warning(
                "analysis.unused_imported_name",
                "unused imported name",
              )
              |> diagnostic.primary(
                location.new(path, item.span),
                "`" <> name <> "` is never referenced",
              )
              |> diagnostic.conclusion(
                "Remove this selectively imported name or use its local alias.",
              )
              |> remove_item(value, index, path),
            ])
        }
      })
  }
}

fn remove_item(
  diagnostic: Diagnostic,
  imported: ast.Import,
  index: Int,
  path: String,
) -> Diagnostic {
  case list.drop(imported.items, index) {
    [] -> diagnostic
    [item, next, ..] ->
      diagnostic.fix(
        diagnostic,
        location.new(path, Span(item.span.start, next.span.start)),
        "",
        "Remove the unused imported name",
        diagnostic.Suggested,
      )
    [item] ->
      case list.drop(imported.items, index - 1), index {
        [previous, ..], count if count > 0 ->
          diagnostic.fix(
            diagnostic,
            location.new(path, Span(previous.span.end, item.span.end)),
            "",
            "Remove the unused imported name",
            diagnostic.Suggested,
          )
        _, _ -> {
          let replacement =
            "import "
            <> string.join(imported.module.segments, "/")
            <> case imported.alias {
              Some(alias) -> " as " <> alias.name
              None -> ""
            }
          diagnostic.fix(
            diagnostic,
            location.new(path, imported.span),
            replacement,
            "Keep the module import without this selected name",
            diagnostic.Suggested,
          )
        }
      }
  }
}

fn private_warnings(
  module: ast.Module,
  path: String,
  uses: List(resolve.Use),
) -> List(Diagnostic) {
  let declarations = list.filter_map(module.declarations, ast.declaration_name)
  let public =
    declarations
    |> list.filter(fn(value) { !string.starts_with(value.name, "_") })
    |> list.map(fn(value) { value.name })
    |> set.from_list
  let #(graph, roots) =
    list.fold(uses, #(dict.new(), public), fn(acc, use_) {
      let #(graph, roots) = acc
      case use_.reference, use_.owner {
        resolve.DeclarationReference(target), Some(owner) -> {
          let dependencies = case dict.get(graph, owner) {
            Ok(values) -> values
            Error(Nil) -> set.new()
          }
          #(dict.insert(graph, owner, set.insert(dependencies, target)), roots)
        }
        resolve.DeclarationReference(target), None -> #(
          graph,
          set.insert(roots, target),
        )
        resolve.ModuleReference(_), _
        | resolve.ImportedReference(_), _
        | resolve.MemberReference(..), _
        -> acc
      }
    })
  let reachable =
    list.fold(set.to_list(roots), set.new(), fn(visited, root) {
      visit(root, graph, visited)
    })
  declarations
  |> list.filter_map(fn(value) {
    case
      string.starts_with(value.name, "_")
      && !set.contains(reachable, value.name)
    {
      False -> Error(Nil)
      True ->
        Ok(
          diagnostic.warning(
            "analysis.unused_private_declaration",
            "unused private declaration",
          )
          |> diagnostic.primary(
            location.new(path, value.span),
            "`"
              <> value.name
              <> "` is not reachable from a public declaration or test",
          )
          |> diagnostic.conclusion(
            "Remove this private declaration or use it from the module's implementation.",
          ),
        )
    }
  })
}

fn visit(
  name: String,
  graph: Dict(String, Set(String)),
  visited: Set(String),
) -> Set(String) {
  case set.contains(visited, name) {
    True -> visited
    False -> {
      let visited = set.insert(visited, name)
      let dependencies = case dict.get(graph, name) {
        Ok(values) -> set.to_list(values)
        Error(Nil) -> []
      }
      list.fold(dependencies, visited, fn(visited, dependency) {
        visit(dependency, graph, visited)
      })
    }
  }
}

fn member_warnings(
  module: ast.Module,
  path: String,
  references: Set(resolve.Reference),
) -> List(Diagnostic) {
  module.declarations
  |> list.flat_map(fn(declaration) {
    case declaration {
      ast.ClassDeclaration(class) -> #(class.name.name, class.members)
      ast.ActorDeclaration(actor) -> #(actor.name.name, actor.members)
      _ -> #("", [])
    }
    |> fn(pair) {
      let #(owner, members) = pair
      list.filter_map(members, fn(member) {
        let name = case member {
          ast.FieldMember(field) -> Ok(#(field.name, "field"))
          ast.MethodMember(method) -> Ok(#(method.name, "method"))
          ast.BehaviourMember(behaviour) -> Ok(#(behaviour.name, "behaviour"))
          ast.ConstructorMember(_) -> Error(Nil)
        }
        case name {
          Ok(#(name, kind)) ->
            case
              string.starts_with(name.name, "_")
              && !set.contains(
                references,
                resolve.MemberReference(owner, name.name),
              )
            {
              True -> Ok(unused_member(owner, name, kind, path))
              False -> Error(Nil)
            }
          Error(Nil) -> Error(Nil)
        }
      })
    }
  })
}

fn unused_member(
  owner: String,
  name: ast.Name,
  kind: String,
  path: String,
) -> Diagnostic {
  diagnostic.warning(
    "analysis.unused_private_member",
    "unused private " <> kind,
  )
  |> diagnostic.primary(
    location.new(path, name.span),
    "`" <> name.name <> "` is never used inside `" <> owner <> "`",
  )
  |> diagnostic.conclusion(
    "Private members are accessible only inside `"
    <> owner
    <> "`, so this one has no effect.",
  )
  |> diagnostic.help(
    "Remove it, or use it from `" <> owner <> "`'s implementation.",
  )
}
