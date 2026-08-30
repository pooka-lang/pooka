//// Arrange checked declarations on the reading table.
////
//// Build the documentation model from public APIs and Markdown pages, then write
//// the site's pages and offline assets. Documentation generation does not need to
//// emit application BEAM files.
////
//// ```text
//// checked public API + README.md -> build/dev/docs/<package>/
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import builder/check
import builder/infer
import diagnostics/diagnostic
import filepath
import gleam/list
import gleam/result
import gleam/string
import project/config
import project/project_error
import simplifile
import tools/docgen/extractor
import tools/docgen/model
import tools/docgen/renderer

pub type Report {
  Report(
    checked: check.Report,
    diagnostics: List(diagnostic.Diagnostic),
    directory: String,
    modules: Int,
  )
}

/// Extract public APIs and attached comments, then emit their pages and offline
/// theme assets.
///
/// ```sh
/// pooka docs
/// ```
pub fn generate(directory: String) -> Result(Report, build.Failure) {
  use checked <- result.try(
    check.check_production(directory)
    |> result.map_error(fn(e) {
      build.Failure(Error(Nil), [project_error.to_diagnostic(e)])
    }),
  )
  use inferred <- result.try(
    infer.preview_report(checked)
    |> result.map_error(fn(e) {
      case e {
        infer.InvalidProgram(report) ->
          build.Failure(Ok(report), check.diagnostics(report))
        infer.ProjectFailed(e) ->
          build.Failure(Ok(checked), [project_error.to_diagnostic(e)])
        infer.UnsupportedSource(path, feature) ->
          build.Failure(Ok(checked), [
            infer.unsupported_diagnostic(path, feature),
          ])
      }
    }),
  )
  use Nil <- result.try(case diagnostic.has_errors(inferred.diagnostics) {
    True -> Error(build.Failure(Ok(checked), inferred.diagnostics))
    False -> Ok(Nil)
  })
  let modules =
    checked.files
    |> list.filter(fn(f) { string.starts_with(f.path, "src/") })
    |> list.filter_map(fn(file) {
      use typed <- result.try(
        list.find(inferred.modules, fn(m) { m.path == file.path }),
      )
      Ok(extractor.extract(file, typed))
    })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  let readme =
    ["README.md", "readme.md", "Readme.md"]
    |> list.find_map(fn(name) {
      simplifile.read(filepath.join(checked.project.root, name))
    })
    |> result.unwrap(case checked.project.config.description {
      "" -> "Package API documentation."
      description -> description
    })
  use guides <- result.try(
    list.try_map(checked.project.config.pages, fn(page) {
      use text <- result.try(
        read_page(checked.project.root, string.split(page.source, "/"))
        |> result.map_error(fn(detail) {
          failure(
            checked,
            "Cannot read documentation page `" <> page.source <> "`: " <> detail,
          )
        }),
      )
      Ok(model.Guide(page.title, page.path, text))
    }),
  )
  let pages =
    renderer.pages(
      checked.project.name,
      checked.project.version,
      checked.project.config.authors,
      readme,
      modules,
      config.documentation_links(checked.project.config),
      guides,
    )
  let destination =
    filepath.join(
      checked.project.root,
      "build/dev/docs/" <> checked.project.name,
    )
  use Nil <- result.try(
    simplifile.create_directory_all(filepath.directory_name(destination))
    |> result.map_error(fn(error) {
      failure(checked, simplifile.describe_error(error))
    }),
  )
  use staging <- result.try(
    temporary(destination) |> result.map_error(failure(checked, _)),
  )
  let prepared =
    pages
    |> list.try_each(fn(page) {
      simplifile.write(filepath.join(staging, page.0), page.1)
      |> result.map_error(fn(e) {
        failure(checked, simplifile.describe_error(e))
      })
    })
  let published =
    prepared
    |> result.try(fn(_) {
      copy_assets(checked.project.root, staging)
      |> result.map_error(failure(checked, _))
    })
    |> result.try(fn(_) {
      publish(staging, destination) |> result.map_error(failure(checked, _))
    })
  let _ = simplifile.delete(staging)
  use Nil <- result.try(published)
  Ok(Report(checked, inferred.diagnostics, destination, list.length(modules)))
}

fn failure(checked: check.Report, message: String) -> build.Failure {
  build.Failure(Ok(checked), [
    diagnostic.error("docs.failed", "documentation generation failed")
    |> diagnostic.conclusion(message),
  ])
}

@external(erlang, "pooka_export_ffi", "temporary_directory")
fn temporary(destination: String) -> Result(String, String)

@external(erlang, "pooka_export_ffi", "publish_directory")
fn publish(staging: String, destination: String) -> Result(Nil, String)

fn read_page(root: String, parts: List(String)) -> Result(String, String) {
  case parts {
    [] -> simplifile.read(root) |> result.map_error(simplifile.describe_error)
    [".", ..rest] | ["", ..rest] -> read_page(root, rest)
    [part, ..rest] -> {
      let path = filepath.join(root, part)
      use symlink <- result.try(
        simplifile.is_symlink(path)
        |> result.map_error(simplifile.describe_error),
      )
      case symlink {
        True ->
          Error("symbolic links are not supported for documentation sources")
        False -> read_page(path, rest)
      }
    }
  }
}

/// Copy package assets into the same relative directory in the staged site.
/// Both Markdown and HTML README images then work offline and on HexDocs.
///
/// ```markdown
/// ![Example](assets/screenshots/example.png)
/// ```
fn copy_assets(root: String, staging: String) -> Result(Nil, String) {
  let source = filepath.join(root, "assets")
  case simplifile.link_info(source) {
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) -> Error(simplifile.describe_error(error))
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.Directory ->
          copy_asset(source, filepath.join(staging, "assets"))
        _ ->
          Error(
            "assets must be a directory of regular files, without symbolic links",
          )
      }
  }
}

fn copy_asset(source: String, destination: String) -> Result(Nil, String) {
  use info <- result.try(
    simplifile.link_info(source) |> result.map_error(simplifile.describe_error),
  )
  case simplifile.file_info_type(info) {
    simplifile.Directory -> {
      use Nil <- result.try(
        simplifile.create_directory_all(destination)
        |> result.map_error(simplifile.describe_error),
      )
      use entries <- result.try(
        simplifile.read_directory(source)
        |> result.map_error(simplifile.describe_error),
      )
      entries
      |> list.filter(fn(name) { !string.starts_with(name, ".") })
      |> list.try_each(fn(name) {
        copy_asset(
          filepath.join(source, name),
          filepath.join(destination, name),
        )
      })
    }
    simplifile.File ->
      simplifile.copy_file(source, destination)
      |> result.map_error(simplifile.describe_error)
    _ ->
      Error(
        "Documentation assets must be regular files or directories; symbolic links are not supported: "
        <> source,
      )
  }
}
