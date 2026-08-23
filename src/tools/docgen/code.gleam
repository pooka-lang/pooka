//// An example should be readable before it is admired.
////
//// Escape source safely, highlight recognized language tokens and wrap code
//// examples for the documentation renderer. Highlighting must never turn example
//// text into executable HTML.
////
//// ```text
//// <script> in an example is displayed as text
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/lexer
import compiler/lexer/token
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/docgen/html

/// Render escaped, highlighted code inside the documentation example wrapper.
///
/// ```text
/// a fenced pooka block -> displayable code, never raw executable markup
/// ```
pub fn example(language: Option(String), source: String) -> String {
  let lang = case language {
    Some(lang) -> lang |> string.split(" ") |> list.first |> result.unwrap("")
    None -> "pooka"
  }
  let highlighted = case lang {
    "pooka" | "" -> highlight(source)
    _ -> html.escape(source)
  }
  let label = case lang {
    "pooka" | "" -> "Pooka"
    _ -> lang
  }
  "<div class=\"code-example\"><div class=\"code-toolbar\"><span>"
  <> html.escape(label)
  <> "</span><button type=\"button\" class=\"copy-code\" data-copy-code hidden>Copy code</button></div>"
  <> "<pre><code class=\"language-"
  <> html.escape(lang)
  <> "\">"
  <> highlighted
  <> "</code></pre></div>\n"
}

pub fn highlight(source: String) -> String {
  let #(end, parts) =
    source
    |> lexer.lex
    |> fn(lexed) { lexed.tokens }
    |> list.fold(#(0, []), fn(found, lexeme) {
      let start = lexeme.span.start.byte_offset
      let end = lexeme.span.end.byte_offset
      let text = slice(source, start, end - start) |> html.escape
      let style = case lexeme.token {
        token.String(_) -> "string"
        token.Int(_) | token.Float(_) -> "number"
        token.UpperName(_) -> "type"
        token.Comment(_) | token.DocComment(_) | token.ModuleComment(_) ->
          "comment"
        token.Name("echo") -> "keyword"
        t ->
          case token.is_keyword(t) {
            True -> "keyword"
            False -> ""
          }
      }
      let text = case style {
        "" -> text
        _ -> "<span class=\"syntax-" <> style <> "\">" <> text <> "</span>"
      }
      #(end, [
        text,
        html.escape(slice(source, found.0, start - found.0)),
        ..found.1
      ])
    })
  parts
  |> list.reverse
  |> string.concat
  |> string.append(
    html.escape(slice(source, end, string.byte_size(source) - end)),
  )
}

fn slice(source: String, offset: Int, length: Int) -> String {
  bit_array.from_string(source)
  |> bit_array.slice(offset, length)
  |> result.try(bit_array.to_string)
  |> result.unwrap("")
}
