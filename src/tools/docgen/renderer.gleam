//// Arrange the public API into pages with familiar signposts.
////
//// Render the documentation model, module navigation and on-page contents. Link
//// targets and filenames come from stable symbol identities, not display headings
//// alone.
////
//// ```text
//// module pooka/list -> its module page and symbol anchors
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import project/config
import project/hexdocs
import tools/docgen/assets
import tools/docgen/markdown as md
import tools/docgen/model
import tools/docgen/versions

pub fn filename(name: String) -> String {
  "module-" <> string.replace(name, "/", "@") <> ".html"
}

fn anchor(name: String) {
  "symbol-" <> name
}

/// Render the package overview, module/guide pages and offline assets from one
/// checked documentation model.
///
/// ```text
/// module introduction -> module-doc section before the API summary
/// ```
pub fn pages(
  name: String,
  version: String,
  authors: List(String),
  readme: String,
  modules: List(model.Module),
  links: List(config.Link),
  guides: List(model.Guide),
) -> List(#(String, String)) {
  let global = index(modules)
  let resolve = fn(key) { dict.get(global, key) |> option }
  let overview =
    heading("Package documentation", name, version)
    <> byline(authors)
    <> "<div class=\"markdown-body\">"
    <> md.render_scoped(readme, resolve, "overview-")
    <> "</div>"
  [
    #(
      "index.html",
      page(
        name,
        version,
        "Overview",
        overview,
        None,
        modules,
        links,
        guides,
        "index.html",
      ),
    ),
    #("style.css", assets.css),
    #("docs.js", assets.javascript <> versions.javascript),
    ..list.map(modules, fn(module) {
      let local_links = local_index(module, global, modules)
      let resolve = fn(key) { dict.get(local_links, key) |> option }
      let body =
        heading("Module", module.name, module.path)
        <> "<div class=\"markdown-body module-doc\">"
        <> md.render_scoped(module.documentation, resolve, "module-")
        <> "</div>"
        <> summary(module.entries)
        <> {
          module.entries
          |> list.map(fn(e) { render_entry(e, "", module.path, resolve) })
          |> string.concat
        }
      #(
        filename(module.name),
        page(
          name,
          version,
          module.name,
          body,
          Some(module),
          modules,
          links,
          guides,
          filename(module.name),
        ),
      )
    })
    |> list.append(
      list.map(guides, fn(guide) {
        let body =
          heading("Guide", guide.title, "")
          <> "<div class=\"markdown-body\">"
          <> md.render_scoped(guide.documentation, resolve, "guide-")
          <> "</div>"
        #(
          guide.path,
          page(
            name,
            version,
            guide.title,
            body,
            None,
            modules,
            links,
            guides,
            guide.path,
          ),
        )
      }),
    )
  ]
}

// Credit the people named in `authors`, in their own order, on the overview
// page. A package without authors renders no byline at all.
fn byline(authors: List(String)) -> String {
  case authors {
    [] -> ""
    _ ->
      "<p class=\"package-authors\">By "
      <> { authors |> list.map(md.escape) |> string.join(", ") }
      <> "</p>\n"
  }
}

fn heading(label: String, title: String, source: String) -> String {
  "<header class=\"page-heading\"><p class=\"eyebrow\">"
  <> md.escape(label)
  <> "</p><h1>"
  <> md.escape(title)
  <> "</h1><span class=\"source\">"
  <> md.escape(source)
  <> "</span></header>\n"
}

fn page(
  name: String,
  version: String,
  title: String,
  body: String,
  current: Option(model.Module),
  modules: List(model.Module),
  links: List(config.Link),
  guides: List(model.Guide),
  active: String,
) -> String {
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\"><title>"
  <> md.escape(title <> " · " <> name)
  <> "</title><script>"
  <> assets.theme_bootstrap
  <> "</script><link rel=\"stylesheet\" href=\"style.css\"><script src=\"docs.js\" defer></script></head><body>\n"
  <> "<a class=\"skip-link\" href=\"#main\">Skip to content</a>"
  <> sidebar(name, version, current, modules, links, guides, active)
  <> "<header class=\"topbar\"><div class=\"breadcrumb\"><span>"
  <> md.escape(name)
  <> "</span><span aria-hidden=\"true\">/</span><strong>"
  <> md.escape(title)
  <> "</strong></div><div class=\"top-actions\">"
  <> "<button type=\"button\" class=\"theme-toggle\" data-theme-toggle aria-label=\"Switch color theme\" aria-pressed=\"false\" hidden>"
  <> moon_icon
  <> "<span class=\"theme-label\">Theme</span></button>"
  <> "<button type=\"button\" class=\"menu-toggle\" data-menu-toggle aria-label=\"Toggle navigation\" aria-controls=\"sidebar\" aria-expanded=\"false\" hidden>"
  <> menu_icon
  <> "</button></div></header>\n"
  <> "<div class=\"layout\"><main id=\"main\" tabindex=\"-1\">"
  <> body
  <> "</main>"
  <> contents(current)
  <> "</div></body></html>\n"
}

fn sidebar(
  name: String,
  version: String,
  current: Option(model.Module),
  modules: List(model.Module),
  links: List(config.Link),
  guides: List(model.Guide),
  active: String,
) -> String {
  "<aside class=\"sidebar\" id=\"sidebar\"><header class=\"project-heading\"><a href=\"index.html\">"
  <> md.escape(name)
  <> "</a><div class=\"project-meta\"><span>Documentation</span><span data-doc-version data-version=\""
  <> md.escape(version)
  <> "\" data-docs-url=\""
  <> md.escape(hexdocs.url(name))
  <> "\"><span class=\"version\" data-version-current>v"
  <> md.escape(version)
  <> "</span><select class=\"version version-select\" data-version-select aria-label=\"Documentation version\" hidden></select></span></div></header>"
  <> "<label class=\"search\"><span class=\"sr-only\">Search modules and APIs</span>"
  <> search_icon
  <> "<input type=\"search\" data-nav-search placeholder=\"Search documentation\" autocomplete=\"off\" aria-controls=\"module-navigation\"><kbd aria-hidden=\"true\">/</kbd></label>"
  <> "<nav class=\"nav-scroll\" aria-label=\"Documentation\"><h2 class=\"nav-label\">Pages</h2><a class=\"page-link\" href=\"index.html\""
  <> case active == "index.html" {
    True -> " aria-current=\"page\""
    False -> ""
  }
  <> ">Overview</a>"
  <> {
    guides
    |> list.map(fn(guide) {
      "<a class=\"page-link\" href=\""
      <> md.escape(guide.path)
      <> "\""
      <> case active == guide.path {
        True -> " aria-current=\"page\""
        False -> ""
      }
      <> ">"
      <> md.escape(guide.title)
      <> "</a>"
    })
    |> string.concat
  }
  <> case links {
    [] -> ""
    _ ->
      "<h2 class=\"nav-label\">Links</h2>"
      <> {
        links
        |> list.map(fn(link) {
          "<a class=\"page-link\" href=\""
          <> md.escape(link.href)
          <> "\" target=\"_blank\" rel=\"noopener noreferrer\">"
          <> md.escape(link.title)
          <> "<span aria-hidden=\"true\">↗</span></a>"
        })
        |> string.concat
      }
  }
  <> "<h2 class=\"nav-label\">Modules</h2><div id=\"module-navigation\">"
  <> { modules |> list.map(fn(m) { module_menu(m, current) }) |> string.concat }
  <> "</div><p class=\"nav-empty\" data-search-empty role=\"status\" hidden>No matching modules or APIs.</p></nav>"
  <> "</aside>\n"
}

fn module_menu(module: model.Module, current: Option(model.Module)) -> String {
  let active = case current {
    Some(m) -> m.name == module.name
    None -> False
  }
  "<details class=\"module-tree\" data-module=\""
  <> md.escape(string.lowercase(module.name))
  <> "\""
  <> case active {
    True -> " data-current open"
    False -> ""
  }
  <> "><summary><a class=\"module-link\" href=\""
  <> md.escape(filename(module.name))
  <> "\""
  <> case active {
    True -> " aria-current=\"page\""
    False -> ""
  }
  <> ">"
  <> md.escape(module.name)
  <> "</a><span class=\"module-count\">"
  <> int.to_string(list.length(module.entries))
  <> "</span></summary><div class=\"module-symbols\">"
  <> {
    [
      #("Types", ["class", "interface", "actor"]),
      #("Functions", ["function"]),
      #("Externals", ["external"]),
      #("Native functions", ["native"]),
    ]
    |> list.map(fn(group) {
      let selected =
        list.filter(module.entries, fn(e) { list.contains(group.1, e.kind) })
      case selected {
        [] -> ""
        _ ->
          "<div data-symbol-group><h3 class=\"symbol-group\">"
          <> group.0
          <> "</h3><ul class=\"symbol-list\">"
          <> {
            selected
            |> list.map(fn(e) { menu_entry(e, "", module.name) })
            |> string.concat
          }
          <> "</ul></div>"
      }
    })
    |> string.concat
  }
  <> "</div></details>\n"
}

fn menu_entry(e: model.Entry, parent: String, module: String) -> String {
  let path = case parent {
    "" -> e.name
    _ -> parent <> "." <> e.name
  }
  "<li data-search=\""
  <> md.escape(string.lowercase(
    module <> " " <> path <> " " <> e.kind <> " " <> e.signature,
  ))
  <> "\"><a class=\"symbol-link\" href=\""
  <> md.escape(filename(module) <> "#" <> anchor(path))
  <> "\">"
  <> "<span class=\"symbol-icon\" aria-hidden=\"true\">"
  <> kind_icon(e.kind)
  <> "</span><span>"
  <> md.escape(e.name)
  <> "</span></a>"
  <> case e.children {
    [] -> ""
    children ->
      "<ul class=\"symbol-children\">"
      <> {
        children
        |> list.map(fn(child) { menu_entry(child, path, module) })
        |> string.concat
      }
      <> "</ul>"
  }
  <> "</li>"
}

fn kind_icon(kind: String) -> String {
  case kind {
    "class" -> "C"
    "interface" -> "I"
    "actor" -> "A"
    "external" -> "E"
    "native" -> "N"
    "field" -> "·"
    "constructor" -> "+"
    _ -> "ƒ"
  }
}

fn summary(entries: List(model.Entry)) -> String {
  case entries {
    [] -> ""
    _ ->
      "<section class=\"api-summary\" aria-label=\"API summary\"><h2>API reference</h2><ul class=\"summary-links\">"
      <> {
        entries
        |> list.map(fn(e) {
          "<li><a href=\"#"
          <> md.escape(anchor(e.name))
          <> "\"><small>"
          <> md.escape(e.kind)
          <> "</small>"
          <> md.escape(e.name)
          <> "</a></li>"
        })
        |> string.concat
      }
      <> "</ul></section>\n"
  }
}

fn contents(current: Option(model.Module)) -> String {
  case current {
    None -> ""
    Some(module) ->
      "<aside class=\"contents\" aria-label=\"On this page\"><h2>On this page</h2><ul>"
      <> {
        module.entries
        |> list.map(fn(e) { contents_entry(e, "") })
        |> string.concat
      }
      <> "</ul></aside>"
  }
}

fn contents_entry(entry: model.Entry, parent: String) -> String {
  let name = case parent {
    "" -> entry.name
    _ -> parent <> "." <> entry.name
  }
  "<li><a href=\"#"
  <> md.escape(anchor(name))
  <> "\">"
  <> md.escape(entry.name)
  <> "</a>"
  <> case entry.children {
    [] -> ""
    children ->
      "<ul>"
      <> {
        children
        |> list.map(fn(child) { contents_entry(child, name) })
        |> string.concat
      }
      <> "</ul>"
  }
  <> "</li>"
}

fn render_entry(
  e: model.Entry,
  parent: String,
  path: String,
  resolve: fn(String) -> Option(String),
) -> String {
  let name = case parent {
    "" -> e.name
    _ -> parent <> "." <> e.name
  }
  let tag = case parent {
    "" -> "h2"
    _ -> "h3"
  }
  "<section class=\"api-entry"
  <> case parent {
    "" -> ""
    _ -> " member"
  }
  <> "\" id=\""
  <> md.escape(anchor(name))
  <> "\">"
  <> "<header class=\"entry-header\"><div class=\"entry-title\"><span class=\"kind-badge\">"
  <> md.escape(e.kind)
  <> "</span><"
  <> tag
  <> ">"
  <> md.escape(e.name)
  <> "</"
  <> tag
  <> ">"
  <> "<a class=\"permalink\" href=\"#"
  <> md.escape(anchor(name))
  <> "\" aria-label=\"Link to "
  <> md.escape(name)
  <> "\">#</a></div><span class=\"source\">"
  <> md.escape(path)
  <> ":"
  <> int.to_string(e.line)
  <> "</span></header>\n"
  <> "<pre class=\"signature\"><code>"
  <> md.linkify(e.signature, resolve)
  <> "</code></pre>\n"
  <> case e.inferred {
    None -> ""
    Some(t) ->
      "<div class=\"inferred\"><span>INFERRED</span><code>"
      <> md.linkify(t, resolve)
      <> "</code></div>\n"
  }
  <> "<div class=\"markdown-body\">"
  <> md.render_scoped(e.documentation, resolve, anchor(name) <> "-")
  <> "</div>"
  <> {
    e.children
    |> list.map(fn(child) { render_entry(child, name, path, resolve) })
    |> string.concat
  }
  <> "</section>\n"
}

const search_icon =
  "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" aria-hidden=\"true\"><circle cx=\"10.5\" cy=\"10.5\" r=\"6.5\"/><path d=\"m16 16 4 4\"/></svg>"

const moon_icon =
  "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" aria-hidden=\"true\"><path d=\"M20 15.5A8.5 8.5 0 0 1 8.5 4a8.5 8.5 0 1 0 11.5 11.5Z\"/></svg>"

const menu_icon =
  "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" aria-hidden=\"true\"><path d=\"M4 6h16M4 12h16M4 18h16\"/></svg>"

fn index(modules: List(model.Module)) -> Dict(String, String) {
  list.fold(modules, dict.new(), fn(found, m) {
    let found = dict.insert(found, m.name, filename(m.name))
    list.fold(m.entries, found, fn(found, e) {
      add_entry(found, m.name <> "." <> e.name, filename(m.name), e.name, e)
    })
  })
}

fn local_index(
  module: model.Module,
  global: Dict(String, String),
  modules: List(model.Module),
) -> Dict(String, String) {
  let found =
    list.fold(module.imports, global, fn(found, imported) {
      let name = imported.module.segments |> string.join("/")
      let alias = case imported.alias {
        Some(a) -> a.name
        None -> imported.module.segments |> list.last |> result_unwrap(name)
      }
      let found =
        list.fold(imported.items, found, fn(found, item) {
          let local = case item.alias {
            Some(a) -> a.name
            None -> item.name.name
          }
          case dict.get(global, name <> "." <> item.name.name) {
            Ok(url) -> dict.insert(found, local, url)
            Error(_) -> found
          }
        })
      case list.find(modules, fn(m) { m.name == name }) {
        Ok(m) ->
          list.fold(
            m.entries,
            dict.insert(found, alias, filename(name)),
            fn(found, e) {
              add_entry(
                found,
                alias <> "." <> e.name,
                filename(name),
                e.name,
                e,
              )
            },
          )
        Error(_) -> found
      }
    })
  list.fold(module.entries, found, fn(found, e) {
    add_entry(found, e.name, filename(module.name), e.name, e)
  })
}

fn add_entry(
  found: Dict(String, String),
  key: String,
  page: String,
  path: String,
  entry: model.Entry,
) -> Dict(String, String) {
  let found = dict.insert(found, key, page <> "#" <> anchor(path))
  list.fold(entry.children, found, fn(found, child) {
    add_entry(
      found,
      key <> "." <> child.name,
      page,
      path <> "." <> child.name,
      child,
    )
  })
}

fn option(value: Result(String, Nil)) {
  case value {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn result_unwrap(value: Result(String, Nil), fallback: String) {
  case value {
    Ok(v) -> v
    Error(_) -> fallback
  }
}
