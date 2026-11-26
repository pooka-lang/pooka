//// Connect resolved call sites to their enclosing and invoked callables.

// SPDX-License-Identifier: Apache-2.0

import builder/check
import compiler/lexer/token
import compiler/parser/ast
import gleam/dict
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import tools/lsp/definition
import tools/lsp/references.{type Site, Site}
import utilities/location.{type Span}

pub type Callable {
  Callable(name: String, kind: Int, site: Site, range: Span)
}

pub type Calls {
  Calls(callable: Callable, sites: List(Site))
}

type Edge {
  Edge(caller: Callable, callee: Callable, site: Site)
}

pub fn prepare(
  path: String,
  offset: Int,
  overlays: List(#(String, String)),
) -> Result(Callable, Nil) {
  use #(checked, uses) <- result.try(references.workspace_index(path, overlays))
  let callables = callables(checked)
  list.find(callables, fn(item) { inside(item.site, path, offset) })
  |> result.lazy_or(fn() {
    use use_ <- result.try(
      list.find(uses, fn(use_) { inside(use_.site, path, offset) }),
    )
    list.find(callables, fn(item) { item.site == use_.target })
  })
}

pub fn calls(
  origin: String,
  path: String,
  offset: Int,
  incoming: Bool,
  overlays: List(#(String, String)),
) -> List(Calls) {
  case references.workspace_index(origin, overlays) {
    Error(_) -> []
    Ok(#(checked, uses)) -> {
      let callables = callables(checked)
      let edges = edges(checked, callables, uses)
      edges
      |> list.filter_map(fn(edge) {
        let #(selected, other) = case incoming {
          True -> #(edge.callee, edge.caller)
          False -> #(edge.caller, edge.callee)
        }
        case inside(selected.site, path, offset) {
          True -> Ok(#(other, edge.site))
          False -> Error(Nil)
        }
      })
      |> list.group(fn(pair) { pair.0 })
      |> dict.to_list
      |> list.map(fn(pair) {
        Calls(pair.0, list.map(pair.1, fn(site) { site.1 }) |> list.unique)
      })
      |> list.sort(fn(a, b) { string.compare(a.callable.name, b.callable.name) })
    }
  }
}

fn edges(
  checked: check.Report,
  callables: List(Callable),
  uses: List(references.Occurrence),
) -> List(Edge) {
  let call_sites =
    checked.files
    |> list.flat_map(fn(file) {
      let path = definition.absolute_path(checked, file.path)
      let tokens = file.lexed.tokens
      list.zip(tokens, list.drop(tokens, 1))
      |> list.filter_map(fn(pair) {
        case pair.1.token {
          token.LeftParen -> Ok(Site(path, pair.0.span))
          _ -> Error(Nil)
        }
      })
    })
    |> set.from_list
  let by_target =
    callables |> list.map(fn(item) { #(item.site, item) }) |> dict.from_list
  let by_file = list.group(callables, fn(item) { item.site.path })
  uses
  |> list.filter(fn(use_) { set.contains(call_sites, use_.site) })
  |> list.filter_map(fn(use_) {
    use target <- result.try(dict.get(by_target, use_.target))
    use file <- result.try(dict.get(by_file, use_.site.path))
    use caller <- result.try(
      list.find(file, fn(item) {
        item.range.start.byte_offset < use_.site.span.start.byte_offset
        && item.range.end.byte_offset >= use_.site.span.end.byte_offset
      }),
    )
    Ok(Edge(caller, target, use_.site))
  })
}

fn callables(checked: check.Report) -> List(Callable) {
  checked.files
  |> list.flat_map(fn(file) {
    let path = definition.absolute_path(checked, file.path)
    list.flat_map(file.parsed.module.declarations, fn(declaration) {
      case declaration {
        ast.FunctionDeclaration(function) -> [
          Callable(
            function.name.name,
            12,
            Site(path, function.name.span),
            function.span,
          ),
        ]
        ast.ClassDeclaration(class) ->
          members(path, class.name.name, class.members)
        ast.ActorDeclaration(actor) ->
          members(path, actor.name.name, actor.members)
        ast.InterfaceDeclaration(interface) ->
          list.map(interface.requirements, fn(method) {
            Callable(
              interface.name.name <> "." <> method.name.name,
              6,
              Site(path, method.name.span),
              method.span,
            )
          })
        _ -> []
      }
    })
  })
}

fn members(
  path: String,
  owner: String,
  members: List(ast.Member),
) -> List(Callable) {
  list.filter_map(members, fn(member) {
    case member {
      ast.MethodMember(function) | ast.BehaviourMember(function) ->
        Ok(Callable(
          owner <> "." <> function.name.name,
          6,
          Site(path, function.name.span),
          function.span,
        ))
      _ -> Error(Nil)
    }
  })
}

fn inside(site: Site, path: String, offset: Int) -> Bool {
  site.path == path
  && site.span.start.byte_offset <= offset
  && offset < site.span.end.byte_offset
}
