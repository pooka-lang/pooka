//// Read the optional rooms in the package manifest.
////
//// Decode package metadata, tool tables and documentation links with explicit
//// defaults and field errors. Unknown tool configuration stays namespaced rather
//// than leaking into compiler settings.
////
//// ```text
//// [tools.example] is distinct from package metadata
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import project/project_error.{type ProjectError, ManifestInvalidField}
import tom

pub type Config {
  Config(
    description: String,
    authors: List(String),
    licences: List(String),
    repository: Option(Repository),
    links: List(Link),
    pages: List(Page),
    tools: Dict(String, tom.Toml),
  )
}

pub type Repository {
  Repository(url: String)
}

pub type Link {
  Link(title: String, href: String)
}

pub type Page {
  Page(title: String, path: String, source: String)
}

pub fn defaults() -> Config {
  Config("", [], [], None, [], [], dict.new())
}

pub fn parse(
  config: Dict(String, tom.Toml),
  path: String,
) -> Result(Config, ProjectError) {
  use description <- result.try(text(config, path, "description", ""))
  use authors <- result.try(strings(config, path, "authors"))
  use licences <- result.try(strings(config, path, "licences"))
  use repository <- result.try(repository(config, path))
  use links <- result.try(links(config, path))
  use documentation <- result.try(table(config, path, "documentation"))
  use pages <- result.try(pages(documentation, path))
  use tools <- result.try(table(config, path, "tools"))
  use Nil <- result.try(
    list.try_each(dict.to_list(tools), fn(entry) {
      case entry.1 {
        tom.Table(_) | tom.InlineTable(_) -> Ok(Nil)
        _ -> Error(invalid(path, "tools." <> entry.0, "must be a table"))
      }
    }),
  )
  Ok(Config(description, authors, licences, repository, links, pages, tools))
}

pub fn tool(
  config: Config,
  name: String,
) -> Result(Dict(String, tom.Toml), Nil) {
  case dict.get(config.tools, name) {
    Ok(tom.Table(values)) | Ok(tom.InlineTable(values)) -> Ok(values)
    _ -> Error(Nil)
  }
}

pub fn documentation_links(config: Config) -> List(Link) {
  case config.repository {
    None -> config.links
    Some(repository) -> [Link("Repository", repository.url), ..config.links]
  }
  |> list.unique
}

fn invalid(path: String, field: String, detail: String) -> ProjectError {
  ManifestInvalidField(path, field, detail)
}

fn text(
  config: Dict(String, tom.Toml),
  path: String,
  key: String,
  default: String,
) -> Result(String, ProjectError) {
  case dict.get(config, key) {
    Error(_) -> Ok(default)
    Ok(tom.String(value)) -> Ok(value)
    _ -> Error(invalid(path, key, "must be a string"))
  }
}

fn required(
  config: Dict(String, tom.Toml),
  path: String,
  key: String,
) -> Result(String, ProjectError) {
  use value <- result.try(text(config, path, key, ""))
  case string.trim(value) {
    "" -> Error(invalid(path, key, "must be a non-empty string"))
    _ -> Ok(value)
  }
}

fn strings(
  config: Dict(String, tom.Toml),
  path: String,
  key: String,
) -> Result(List(String), ProjectError) {
  case dict.get(config, key) {
    Error(_) -> Ok([])
    Ok(tom.Array(values)) ->
      list.try_map(values, fn(value) {
        case value {
          tom.String(value) if value != "" -> Ok(value)
          _ -> Error(invalid(path, key, "must contain non-empty strings"))
        }
      })
    _ -> Error(invalid(path, key, "must be an array of strings"))
  }
}

fn table(
  config: Dict(String, tom.Toml),
  path: String,
  key: String,
) -> Result(Dict(String, tom.Toml), ProjectError) {
  case dict.get(config, key) {
    Error(_) -> Ok(dict.new())
    Ok(tom.Table(values)) | Ok(tom.InlineTable(values)) -> Ok(values)
    _ -> Error(invalid(path, key, "must be a table"))
  }
}

fn web_url(
  url: String,
  path: String,
  field: String,
) -> Result(String, ProjectError) {
  let clean =
    !list.any(string.to_utf_codepoints(url), fn(c) {
      let n = string.utf_codepoint_to_int(c)
      n <= 32 || n == 127
    })
  case uri.parse(url), clean {
    Ok(uri.Uri(scheme: Some(scheme), host: Some(host), ..)), True
      if host != "" && { scheme == "http" || scheme == "https" }
    -> Ok(url)
    _, _ ->
      Error(invalid(
        path,
        field,
        "must be an absolute HTTP or HTTPS URL without whitespace",
      ))
  }
}

fn repository(
  config: Dict(String, tom.Toml),
  path: String,
) -> Result(Option(Repository), ProjectError) {
  case dict.has_key(config, "repository") {
    False -> Ok(None)
    True -> {
      use values <- result.try(table(config, path, "repository"))
      use kind <- result.try(required(values, path, "type"))
      use url <- result.try(case kind {
        "custom" -> required(values, path, "url")
        _ -> {
          use user <- result.try(required(values, path, "user"))
          use repo <- result.try(required(values, path, "repo"))
          use host <- result.try(case kind {
            "github" -> Ok("https://github.com")
            "gitlab" -> Ok("https://gitlab.com")
            "bitbucket" -> Ok("https://bitbucket.org")
            "codeberg" -> Ok("https://codeberg.org")
            "sourcehut" -> Ok("https://git.sr.ht/~")
            "tangled" -> Ok("https://tangled.org")
            "gitea" | "forgejo" -> required(values, path, "host")
            _ ->
              Error(invalid(
                path,
                "repository.type",
                "unsupported repository provider",
              ))
          })
          Ok(
            trim_slashes(host)
            <> case kind {
              "sourcehut" -> user <> "/" <> repo
              _ -> "/" <> user <> "/" <> repo
            },
          )
        }
      })
      use url <- result.try(web_url(url, path, "repository"))
      Ok(Some(Repository(url)))
    }
  }
}

fn link(
  values: Dict(String, tom.Toml),
  path: String,
) -> Result(Link, ProjectError) {
  use title <- result.try(required(values, path, "title"))
  use href <- result.try(required(values, path, "href"))
  use href <- result.try(web_url(href, path, "links.href"))
  Ok(Link(title, href))
}

fn links(
  config: Dict(String, tom.Toml),
  path: String,
) -> Result(List(Link), ProjectError) {
  case dict.get(config, "links") {
    Error(_) -> Ok([])
    Ok(tom.ArrayOfTables(values)) -> list.try_map(values, link(_, path))
    Ok(tom.Array(values)) ->
      list.try_map(values, fn(value) {
        case value {
          tom.InlineTable(values) | tom.Table(values) -> link(values, path)
          _ ->
            Error(invalid(
              path,
              "links",
              "must contain tables with title and href",
            ))
        }
      })

    Ok(tom.Table(values)) | Ok(tom.InlineTable(values)) ->
      values
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.try_map(fn(entry) {
        link(
          dict.from_list([#("title", tom.String(entry.0)), #("href", entry.1)]),
          path,
        )
      })
    _ ->
      Error(invalid(
        path,
        "links",
        "must be an array of link tables or a title-to-URL table",
      ))
  }
}

fn page(
  values: Dict(String, tom.Toml),
  path: String,
) -> Result(Page, ProjectError) {
  use title <- result.try(required(values, path, "title"))
  use output <- result.try(required(values, path, "path"))
  use source <- result.try(required(values, path, "source"))
  let lower = string.lowercase(output)
  let reserved =
    list.contains(["index.html", "style.css", "docs.js"], lower)
    || string.starts_with(lower, "module-")
  use Nil <- result.try(
    case
      safe_relative(source)
      && safe_relative(output)
      && !string.contains(output, "/")
      && string.ends_with(output, ".html")
      && !string.starts_with(output, ".")
      && list.all(string.to_graphemes(output), fn(c) {
        string.contains(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-",
          c,
        )
      })
      && !reserved
    {
      True -> Ok(Nil)
      False ->
        Error(invalid(
          path,
          "documentation.pages",
          "source must stay inside the project; path must be a unique, non-reserved HTML filename",
        ))
    },
  )
  Ok(Page(title, output, source))
}

fn pages(
  config: Dict(String, tom.Toml),
  path: String,
) -> Result(List(Page), ProjectError) {
  use values <- result.try(case dict.get(config, "pages") {
    Error(_) -> Ok([])
    Ok(tom.ArrayOfTables(values)) -> Ok(values)
    Ok(tom.Array(values)) ->
      list.try_map(values, fn(value) {
        case value {
          tom.Table(values) | tom.InlineTable(values) -> Ok(values)
          _ ->
            Error(invalid(
              path,
              "documentation.pages",
              "must contain page tables",
            ))
        }
      })
    _ ->
      Error(invalid(path, "documentation.pages", "must be an array of tables"))
  })
  use pages <- result.try(list.try_map(values, page(_, path)))
  let names = list.map(pages, fn(p) { string.lowercase(p.path) })
  case list.length(list.unique(names)) == list.length(names) {
    True -> Ok(pages)
    False ->
      Error(invalid(
        path,
        "documentation.pages.path",
        "page paths must be unique, including letter case",
      ))
  }
}

fn safe_relative(path: String) -> Bool {
  !string.starts_with(path, "/")
  && !string.contains(path, "\\")
  && !string.contains(path, ":")
  && !list.contains(string.split(path, "/"), "..")
  && !string.contains(path, "\n")
  && !string.contains(path, "\r")
}

fn trim_slashes(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> trim_slashes(string.drop_end(value, 1))
    False -> value
  }
}
