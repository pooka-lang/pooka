//// Close the small door through which raw HTML could wander.
////
//// Escape text inserted into generated markup. Keep escaping separate from
//// Markdown interpretation so a symbol name cannot become a tag.
////
//// ```text
//// < becomes &lt; in displayed text
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

/// Let README images through a very small door. Rebuild only quoted img
/// attributes and optional paragraph alignment; unknown markup remains text.
///
/// ```html
/// <p align="center"><img src="assets/noxy.png" width="280" /></p>
/// ```
pub fn image_markup(raw: String, allowed_url: fn(String) -> Bool) -> String {
  images(string.trim(raw), allowed_url)
  |> result.unwrap(escape(raw))
}

fn images(raw: String, allowed_url: fn(String) -> Bool) -> Result(String, Nil) {
  case string.trim_start(raw) {
    "" -> Ok("")
    text -> {
      use text <- result.try(case string.starts_with(text, "<") {
        True -> Ok(string.drop_start(text, 1))
        False -> Error(Nil)
      })
      use #(tag, rest) <- result.try(string.split_once(text, ">"))
      use rendered <- result.try(image_tag(string.trim(tag), allowed_url))
      use following <- result.try(images(rest, allowed_url))
      Ok(rendered <> following)
    }
  }
}

fn image_tag(
  tag: String,
  allowed_url: fn(String) -> Bool,
) -> Result(String, Nil) {
  let lower = string.lowercase(tag)
  case lower {
    "/p" -> Ok("</p>")
    _ ->
      case tag_name(lower, "img"), tag_name(lower, "p") {
        True, _ -> {
          let text = tag |> string.drop_start(3) |> string.trim
          let text = case string.ends_with(text, "/") {
            True -> string.drop_end(text, 1)
            False -> text
          }
          use attrs <- result.try(attributes(text, []))
          use Nil <- result.try(
            case
              list.any(attrs, fn(a) { a.0 == "src" })
              && list.all(attrs, fn(a) {
                case a {
                  #("src", value) -> allowed_url(value)
                  #("alt", _) | #("title", _) -> True
                  #("width", value) | #("height", value) ->
                    case int.parse(value) {
                      Ok(n) -> n > 0
                      Error(_) -> False
                    }
                  _ -> False
                }
              })
            {
              True -> Ok(Nil)
              False -> Error(Nil)
            },
          )
          Ok("<img" <> render_attributes(attrs) <> " />")
        }
        _, True -> {
          use attrs <- result.try(attributes(string.drop_start(tag, 1), []))
          case
            list.all(attrs, fn(a) {
              a.0 == "align" && list.contains(["left", "center", "right"], a.1)
            })
          {
            True -> Ok("<p" <> render_attributes(attrs) <> ">")
            False -> Error(Nil)
          }
        }
        _, _ -> Error(Nil)
      }
  }
}

fn tag_name(text: String, name: String) -> Bool {
  text == name
  || list.any([" ", "\n", "\r", "\t"], fn(separator) {
    string.starts_with(text, name <> separator)
  })
}

fn attributes(
  text: String,
  found: List(#(String, String)),
) -> Result(List(#(String, String)), Nil) {
  case string.trim(text) {
    "" -> Ok(list.reverse(found))
    text -> {
      use #(key, tail) <- result.try(string.split_once(text, "="))
      let key = key |> string.trim |> string.lowercase
      use Nil <- result.try(case list.any(found, fn(a) { a.0 == key }) {
        True -> Error(Nil)
        False -> Ok(Nil)
      })
      use #(quote, tail) <- result.try(
        string.pop_grapheme(string.trim_start(tail)),
      )
      use Nil <- result.try(case quote == "\"" || quote == "'" {
        True -> Ok(Nil)
        False -> Error(Nil)
      })
      use #(value, rest) <- result.try(string.split_once(tail, quote))
      attributes(rest, [#(key, value), ..found])
    }
  }
}

fn render_attributes(attrs: List(#(String, String))) -> String {
  attrs
  |> list.map(fn(a) { " " <> a.0 <> "=\"" <> escape(a.1) <> "\"" })
  |> string.concat
}
