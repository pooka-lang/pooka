//// Find the manifest before asking the project to explain itself.
////
//// Locate pooka.toml, decode package settings and discover source/test files.
//// Project creation uses the same filename and layout rules that loading expects.
////
//// ```text
//// pooka new app -> app/pooka.toml + src/main.pooka + test/main.spec.pooka
//// ```

// SPDX-License-Identifier: Apache-2.0

import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import project/config
import project/dependency
import project/native_component.{type NativeComponent}
import project/project_error.{type ProjectError}
import project/project_name
import project/template
import simplifile
import tom

pub const manifest = "pooka.toml"

pub const source_extension = ".pooka"

pub const test_extension = ".spec.pooka"

pub type Project {
  Project(
    root: String,
    name: String,
    version: String,
    dependencies: List(dependency.Dependency),
    dev_dependencies: List(dependency.Dependency),
    origin: dependency.Origin,
    kind: dependency.Kind,
    natives: List(NativeComponent),
    config: config.Config,
  )
}

pub type SourceRole {

  Production

  TestSource
}

pub type SourceFile {
  SourceFile(path: String, role: SourceRole)
}

/// Walk upward to the nearest directory containing pooka.toml. Do not infer
/// package identity from the directory name alone.
///
/// ```text
/// src/nested/ -> nearest ancestor with pooka.toml
/// ```
pub fn find_root(start: String) -> Result(String, ProjectError) {
  find_root_loop(start, start)
}

fn find_root_loop(
  directory: String,
  start: String,
) -> Result(String, ProjectError) {
  case simplifile.is_file(filepath.join(directory, manifest)) {
    Ok(True) -> Ok(directory)
    Ok(False) | Error(_) -> {
      let parent = filepath.directory_name(directory)
      case parent == directory || parent == "" {
        True -> Error(project_error.NotInProject(start))
        False -> find_root_loop(parent, start)
      }
    }
  }
}

/// Read and decode the current package manifest with its actual path attached to
/// failures.
///
/// ```text
/// pooka.toml -> package configuration or ProjectError
/// ```
pub fn load(root: String) -> Result(Project, ProjectError) {
  let path = filepath.join(root, manifest)
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(project_error.FileSystemFailed(
      project_error.ReadingFile,
      path,
      _,
    )),
  )
  parse_manifest(text, path, root)
}

/// Decode manifest text independently of filesystem discovery, retaining the
/// supplied root and path.
///
/// ```toml
/// name = "example"
/// version = "1.0.0"
/// ```
pub fn parse_manifest(
  text: String,
  path: String,
  root: String,
) -> Result(Project, ProjectError) {
  use config <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      project_error.ManifestSyntax(path, describe_toml_error(error))
    }),
  )
  use name <- result.try(string_field(config, path, "name"))
  use version <- result.try(string_field(config, path, "version"))
  use Nil <- result.try(
    project_name.validate(name)
    |> result.map_error(project_error.ManifestInvalidName(path, name, _)),
  )
  use dependencies <- result.try(dependency.parse(config, "dependencies", path))
  use development_key <- result.try(
    case
      dict.has_key(config, "dev_dependencies"),
      dict.has_key(config, "dev-dependencies")
    {
      True, True ->
        Error(project_error.ManifestInvalidField(
          path,
          "dev_dependencies",
          "cannot be combined with dev-dependencies; use one spelling",
        ))
      True, False -> Ok("dev_dependencies")
      _, _ -> Ok("dev-dependencies")
    },
  )
  use dev_dependencies <- result.try(dependency.parse(
    config,
    development_key,
    path,
  ))
  use natives <- result.try(native_component.parse(config, path))
  use metadata <- result.try(config.parse(config, path))
  Ok(Project(
    root:,
    name:,
    version:,
    dependencies:,
    dev_dependencies:,
    origin: dependency.LocalOrigin,
    kind: dependency.Pooka,
    natives:,
    config: metadata,
  ))
}

fn string_field(
  config: Dict(String, tom.Toml),
  path: String,
  field: String,
) -> Result(String, ProjectError) {
  tom.get_string(config, [field])
  |> result.map_error(fn(error) {
    case error {
      tom.NotFound(_) -> project_error.ManifestMissingField(path, field)
      tom.WrongType(..) ->
        project_error.ManifestFieldType(path, field, "string")
    }
  })
}

fn describe_toml_error(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "found "
      <> describe_toml_token(got)
      <> " where "
      <> expected
      <> " was expected"
    tom.KeyAlreadyInUse(key) ->
      "the key `" <> string.join(key, ".") <> "` is defined more than once"
  }
}

fn describe_toml_token(got: String) -> String {
  case got {
    "" -> "the end of the file"
    "\n" -> "a line break"
    other -> "`" <> other <> "`"
  }
}

pub fn source_files(
  project: Project,
) -> Result(List(SourceFile), ProjectError) {
  source_files_for(project, True)
}

pub fn production_source_files(
  project: Project,
) -> Result(List(SourceFile), ProjectError) {
  source_files_for(project, False)
}

fn source_files_for(
  project: Project,
  include_tests: Bool,
) -> Result(List(SourceFile), ProjectError) {
  case project.kind {
    dependency.Beam(_, _) -> Ok([])
    dependency.Pooka -> pooka_source_files(project, include_tests)
  }
}

fn pooka_source_files(
  project: Project,
  include_tests: Bool,
) -> Result(List(SourceFile), ProjectError) {
  let source_directory = filepath.join(project.root, "src")
  use exists <- result.try(is_directory(source_directory))
  use Nil <- result.try(case exists {
    True -> Ok(Nil)
    False -> Error(project_error.NoSourceDirectory(project.root))
  })
  use sources <- result.try(discover(project.root, "src"))
  use test_exists <- result.try(case include_tests {
    True -> is_directory(filepath.join(project.root, "test"))
    False -> Ok(False)
  })
  use tests <- result.try(case test_exists {
    True -> discover(project.root, "test")
    False -> Ok([])
  })
  let production =
    sources
    |> list.filter(string.ends_with(_, source_extension))
    |> list.map(SourceFile(_, Production))
  let tests =
    tests
    |> list.filter(string.ends_with(_, test_extension))
    |> list.map(SourceFile(_, TestSource))
  Ok(list.append(production, tests))
}

fn is_directory(path: String) -> Result(Bool, ProjectError) {
  simplifile.is_directory(path)
  |> result.map_error(project_error.FileSystemFailed(
    project_error.InspectingPath,
    path,
    _,
  ))
}

fn discover(
  root: String,
  directory: String,
) -> Result(List(String), ProjectError) {
  let absolute = filepath.join(root, directory)
  use entries <- result.try(
    simplifile.read_directory(absolute)
    |> result.map_error(project_error.FileSystemFailed(
      project_error.ReadingDirectory,
      absolute,
      _,
    )),
  )
  entries
  |> list.filter(fn(entry) { !string.starts_with(entry, ".") })
  |> list.sort(string.compare)
  |> list.try_fold([], fn(found, entry) {
    let relative = directory <> "/" <> entry
    let path = filepath.join(root, relative)
    case simplifile.is_symlink(path), simplifile.is_directory(path) {
      Ok(True), _ -> Ok(found)
      _, Ok(True) -> {
        use inner <- result.try(discover(root, relative))
        Ok(list.append(found, inner))
      }
      _, Ok(False) -> Ok(list.append(found, [relative]))
      _, Error(reason) ->
        Error(project_error.FileSystemFailed(
          project_error.InspectingPath,
          path,
          reason,
        ))
    }
  })
}

pub type Created {
  Created(root: String, files: List(String))
}

/// Create template directories and files only after validating the new package
/// name.
///
/// ```sh
/// pooka new example
/// ```
pub fn create(parent: String, name: String) -> Result(Created, ProjectError) {
  use Nil <- result.try(
    project_name.validate(name)
    |> result.map_error(project_error.InvalidProjectName(name, _)),
  )
  let root = filepath.join(parent, name)
  use Nil <- result.try(case simplifile.link_info(root) {
    Ok(_) -> Error(project_error.ProjectPathExists(root))
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) ->
      Error(project_error.FileSystemFailed(
        project_error.InspectingPath,
        root,
        reason,
      ))
  })
  use Nil <- result.try(
    simplifile.create_directory(root)
    |> result.map_error(project_error.FileSystemFailed(
      project_error.CreatingDirectory,
      root,
      _,
    )),
  )
  case populate(root, name) {
    Ok(files) -> Ok(Created(root:, files:))
    Error(error) -> {
      let _ = simplifile.delete(root)
      Error(error)
    }
  }
}

fn populate(root: String, name: String) -> Result(List(String), ProjectError) {
  use Nil <- result.try(
    list.try_each(template.directories(), fn(directory) {
      let path = filepath.join(root, directory)
      simplifile.create_directory(path)
      |> result.map_error(project_error.FileSystemFailed(
        project_error.CreatingDirectory,
        path,
        _,
      ))
    }),
  )
  let files = template.files(name)
  use Nil <- result.try(
    list.try_each(files, fn(file) {
      let path = filepath.join(root, file.0)
      simplifile.write(path, file.1)
      |> result.map_error(project_error.FileSystemFailed(
        project_error.WritingFile,
        path,
        _,
      ))
    }),
  )
  Ok(list.map(files, fn(file) { file.0 }))
}

pub fn load_package(
  root: String,
  name: String,
) -> Result(Project, ProjectError) {
  case simplifile.is_file(filepath.join(root, manifest)) {
    Ok(True) -> load(root)
    _ -> {
      let path = filepath.join(root, "gleam.toml")
      use text <- result.try(
        simplifile.read(path)
        |> result.map_error(project_error.FileSystemFailed(
          project_error.ReadingFile,
          path,
          _,
        )),
      )
      use package <- result.try(parse_manifest(text, path, root))
      case package.name == name {
        True -> Ok(Project(..package, kind: dependency.Beam(name, ["gleam"])))
        False ->
          Error(project_error.DependencyProblem(
            path,
            "Native package name does not match `" <> name <> "`.",
          ))
      }
    }
  }
}

pub fn application_name(project: Project) -> String {
  case project.kind {
    dependency.Pooka -> project.name
    dependency.Beam(app, _) -> app
  }
}
