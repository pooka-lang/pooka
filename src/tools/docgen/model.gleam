//// Describe the book before choosing its binding.
////
//// Hold modules, symbols, pages and navigation data for documentation generation.
//// The model keeps checked API information separate from presentation markup.
////
//// ```text
//// module -> classes, methods, functions and attached documentation
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import gleam/option.{type Option}

pub type Module {
  Module(
    name: String,
    path: String,
    documentation: String,
    imports: List(ast.Import),
    entries: List(Entry),
  )
}

pub type Entry {
  Entry(
    name: String,
    kind: String,
    signature: String,
    inferred: Option(String),
    documentation: String,
    line: Int,
    children: List(Entry),
  )
}

pub type Guide {
  Guide(title: String, path: String, documentation: String)
}
