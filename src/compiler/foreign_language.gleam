//// Keep the visitors' names in one guest book.
////
//// Translate supported foreign-language names, source extensions and BEAM module
//// conventions. One shared catalogue prevents discovery and diagnostics from
//// disagreeing.
////
//// ```text
//// helper.erl -> Erlang; helper.ex -> Elixir
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast.{type ForeignLanguage}
import gleam/list
import gleam/string
import project/native_component

pub const all = [ast.Erlang, ast.Elixir, ast.Gleam, ast.Lfe]

pub fn name(language: ForeignLanguage) -> String {
  case language {
    ast.Erlang -> "erlang"
    ast.Elixir -> "elixir"
    ast.Gleam -> "gleam"
    ast.Lfe -> "lfe"
    ast.Native -> "native"
  }
}

pub fn from_name(word: String) -> Result(ForeignLanguage, Nil) {
  list.find(all, fn(language) { name(language) == word })
}

pub fn names() -> List(String) {
  list.map(all, name)
}

pub fn beam_module(language: ForeignLanguage, module: String) -> String {
  case language {
    ast.Erlang | ast.Lfe -> module
    ast.Elixir -> "Elixir." <> module
    ast.Gleam -> string.replace(module, "/", "@")
    ast.Native -> native_component.module(module)
  }
}

pub fn extensions(language: ForeignLanguage) -> List(String) {
  case language {
    ast.Erlang -> [".erl"]
    ast.Elixir -> [".ex"]
    ast.Gleam -> [".gleam"]
    ast.Lfe -> [".lfe"]
    ast.Native -> []
  }
}

pub fn of_file(path: String) -> Result(ForeignLanguage, Nil) {
  list.find(all, fn(language) {
    list.any(extensions(language), string.ends_with(path, _))
  })
}
