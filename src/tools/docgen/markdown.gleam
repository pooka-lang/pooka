//// Give prose a little structure without surrendering the page.
////
//// Render Markdown, safe links, fenced examples and API references in module
//// scope. Keep raw content escaped and validate link destinations before emitting
//// attributes.
////
//// ```text
//// a fenced pooka example -> highlighted, escaped code block
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import mork
import mork/document as d
import tools/docgen/code
import tools/docgen/html

pub fn escape(text: String) -> String {
  html.escape(text)
}

pub fn render(text: String, resolve: fn(String) -> Option(String)) -> String {
  render_scoped(text, resolve, "doc-")
}

pub fn render_scoped(
  text: String,
  resolve: fn(String) -> Option(String),
  prefix: String,
) -> String {
  let options =
    mork.configure()
    |> mork.tables(True)
    |> mork.tasklists(True)
    |> mork.autolinks(True)
    |> mork.heading_ids(True)
    |> mork.footnotes(False)

  let original = mork.parse_with_options(options, text)
  let definitions =
    references(text, resolve, [])
    |> list.unique
    |> list.filter(fn(pair) {
      !dict.has_key(original.links, string.lowercase(pair.0))
    })
    |> list.map(fn(pair) { "[" <> pair.0 <> "]: " <> pair.1 <> "\n" })
    |> string.concat
  let input = case definitions {
    "" -> text
    _ -> definitions <> "\n" <> text
  }
  let doc = mork.parse_with_options(options, input)
  let headings = heading_index(doc.blocks, prefix) |> dict.from_list
  let context = Context(doc, resolve, headings)
  d.Document(..doc, blocks: blocks(doc.blocks, context, prefix)) |> mork.to_html
}

type Context {
  Context(
    doc: d.Document,
    resolve: fn(String) -> Option(String),
    headings: Dict(String, String),
  )
}

fn references(
  text: String,
  resolve: fn(String) -> Option(String),
  found: List(#(String, String)),
) -> List(#(String, String)) {
  case string.split_once(text, "[") {
    Error(_) -> found
    Ok(#(_, tail)) ->
      case string.split_once(tail, "]") {
        Error(_) -> found
        Ok(#(name, tail)) ->
          case resolve(name) {
            Some(url) -> references(tail, resolve, [#(name, url), ..found])
            None -> references(tail, resolve, found)
          }
      }
  }
}

fn heading_index(
  values: List(d.Block),
  prefix: String,
) -> List(#(String, String)) {
  values
  |> nonempty
  |> list.index_map(fn(block, index) {
    let prefix = prefix <> int.to_string(index) <> "-"
    case block {
      d.Heading(_, id, _, _) -> [
        #(id, prefix <> slug(id)),
        #(slug(id), prefix <> slug(id)),
      ]
      d.BlockQuote(children) -> heading_index(children, prefix)
      d.BulletList(_, items) | d.OrderedList(_, items, _) ->
        items
        |> list.index_map(fn(item, i) {
          heading_index(item.blocks, prefix <> int.to_string(i) <> "-")
        })
        |> list.flatten
      _ -> []
    }
  })
  |> list.flatten
}

fn blocks(
  values: List(d.Block),
  ctx: Context,
  prefix: String,
) -> List(d.Block) {
  values
  |> nonempty
  |> list.index_map(fn(block, index) {
    let prefix = prefix <> int.to_string(index) <> "-"
    case block {
      d.Code(lang, text) -> d.HtmlBlock(code.example(lang, text))
      d.HtmlBlock(raw) -> d.HtmlBlock(html.image_markup(raw, safe_url))
      d.Heading(level, id, raw, values) ->
        d.Heading(level, prefix <> slug(id), raw, inlines(values, ctx))
      d.Paragraph(raw, values) -> d.Paragraph(raw, inlines(values, ctx))
      d.BlockQuote(children) -> d.BlockQuote(blocks(children, ctx, prefix))
      d.BulletList(pack, items) ->
        d.BulletList(pack, list_items(items, ctx, prefix))
      d.OrderedList(pack, items, start) ->
        d.OrderedList(pack, list_items(items, ctx, prefix), start)
      d.Table(header, rows) ->
        d.Table(
          list.map(header, fn(h) {
            d.THead(..h, inlines: inlines(h.inlines, ctx))
          }),
          list.map(rows, fn(row) {
            list.map(row, fn(cell) {
              d.Cell(..cell, inlines: inlines(cell.inlines, ctx))
            })
          }),
        )
      d.Empty | d.Newline | d.ThematicBreak -> block
    }
  })
}

fn list_items(
  items: List(d.ListItem),
  ctx: Context,
  prefix: String,
) -> List(d.ListItem) {
  items
  |> list.index_map(fn(item, i) {
    d.ListItem(
      ..item,
      blocks: blocks(item.blocks, ctx, prefix <> int.to_string(i) <> "-"),
    )
  })
}

fn inlines(values: List(d.Inline), ctx: Context) -> List(d.Inline) {
  list.map(values, fn(value) {
    case value {
      d.CodeSpan(text) ->
        d.RawHtml("<code>" <> linkify(text, ctx.resolve) <> "</code>")
      d.RawHtml(raw) -> d.RawHtml(html.image_markup(raw, safe_url))
      d.InlineHtml(tag, _, children) ->
        d.RawHtml(
          escape("<" <> tag <> ">")
          <> children_text(children)
          <> escape("</" <> tag <> ">"),
        )
      d.Emphasis(v) -> d.Emphasis(inlines(v, ctx))
      d.Strong(v) -> d.Strong(inlines(v, ctx))
      d.Strikethrough(v) -> d.Strikethrough(inlines(v, ctx))
      d.Highlight(v) -> d.Highlight(inlines(v, ctx))
      d.FullLink(v, data) -> link_node(v, data, ctx)
      d.FullImage(v, data) ->
        case allowed(data.dest) {
          True -> d.FullImage(inlines(v, ctx), data)
          False -> d.Text(plain(v))
        }
      d.RefLink(v, label) ->
        case dict.get(ctx.doc.links, label) {
          Ok(data) -> link_node(v, data, ctx)
          Error(_) -> d.Text(plain(v))
        }
      d.RefImage(v, label) ->
        case dict.get(ctx.doc.links, label) {
          Ok(data) ->
            case allowed(data.dest) {
              True -> d.FullImage(inlines(v, ctx), data)
              False -> d.Text(plain(v))
            }
          Error(_) -> d.Text(plain(v))
        }
      d.Autolink(url, text) ->
        case safe_url(url) {
          True -> value
          False ->
            d.Text(case text {
              Some(text) -> text
              None -> url
            })
        }
      d.EmailAutolink(_)
      | d.HardBreak
      | d.SoftBreak
      | d.Text(_)
      | d.Checkbox(_)
      | d.Delim(..)
      | d.Footnote(..)
      | d.InlineFootnote(..) -> value
    }
  })
}

fn link_node(
  values: List(d.Inline),
  data: d.LinkData,
  ctx: Context,
) -> d.Inline {
  case allowed(data.dest) {
    False -> d.InlineHtml("span", dict.new(), inlines(values, ctx))
    True -> {
      let dest = case data.dest {
        d.Anchor(id) ->
          case dict.get(ctx.headings, id) {
            Ok(scoped) -> d.Anchor(scoped)
            Error(_) -> data.dest
          }
        _ -> data.dest
      }
      d.FullLink(inlines(values, ctx), d.LinkData(..data, dest: dest))
    }
  }
}

fn allowed(dest: d.Destination) -> Bool {
  case dest {
    d.Anchor(_) -> True
    d.Absolute(uri) | d.Relative(uri) -> safe_url(uri)
  }
}

fn safe_url(url: String) -> Bool {
  let lower = string.lowercase(url)
  !list.any(string.to_graphemes(url), fn(c) {
    c == "\n" || c == "\r" || c == "\t"
  })
  && {
    string.starts_with(lower, "https://")
    || string.starts_with(lower, "http://")
    || string.starts_with(lower, "mailto:")
    || {
      !string.contains(lower, ":")
      && !string.contains(lower, "%3a")
      && !string.contains(lower, "&")
      && !string.contains(lower, "\\")
      && !string.starts_with(lower, "//")
    }
  }
}

fn plain(values: List(d.Inline)) -> String {
  values
  |> list.map(fn(v) {
    case v {
      d.Text(t) | d.CodeSpan(t) -> t
      _ -> ""
    }
  })
  |> string.concat
}

fn children_text(values: List(d.Inline)) -> String {
  plain(values) |> escape
}

pub fn linkify(text: String, resolve: fn(String) -> Option(String)) -> String {
  scan(string.to_graphemes(text), "", resolve)
}

fn scan(
  chars: List(String),
  word: String,
  resolve: fn(String) -> Option(String),
) -> String {
  case chars {
    [] -> render_word(word, resolve)
    [c, ..rest] ->
      case
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/.",
          c,
        )
      {
        True -> scan(rest, word <> c, resolve)
        False ->
          render_word(word, resolve) <> escape(c) <> scan(rest, "", resolve)
      }
  }
}

fn render_word(text: String, resolve: fn(String) -> Option(String)) {
  case resolve(text) {
    Some(url) -> link(url, escape(text))
    None -> escape(text)
  }
}

fn link(url: String, label: String) -> String {
  "<a href=\"" <> escape(url) <> "\">" <> label <> "</a>"
}

fn slug(id: String) -> String {
  id |> string.lowercase |> string.replace(" ", "-")
}

fn nonempty(values: List(d.Block)) -> List(d.Block) {
  list.filter(values, fn(block) {
    case block {
      d.Empty | d.Newline -> False
      _ -> True
    }
  })
}
