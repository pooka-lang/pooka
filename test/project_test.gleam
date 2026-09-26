//// Set the table for the first program.
////
//// Validate package names, manifests, source discovery and project creation.
//// The template snapshot records every generated file, including the starter
//// spec, live badges and workflow. Creation must not overwrite an existing
//// directory, even when its contents look inviting.
////
//// ```sh
//// pooka new my_app
//// cd my_app
//// pooka test
//// ```

import birdie
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/config
import project/dependency
import project/edit
import project/project
import project/project_error
import project/project_name
import project/template
import simplifile
import support

pub fn valid_names_test() {
  assert project_name.validate("my_app") == Ok(Nil)
  assert project_name.validate("app2") == Ok(Nil)
  assert project_name.validate("a") == Ok(Nil)
}

pub fn invalid_names_test() {
  assert project_name.validate("") == Error(project_name.EmptyName)
  assert project_name.validate("MyApp")
    == Error(project_name.BadFirstCharacter("M"))
  assert project_name.validate("2app")
    == Error(project_name.BadFirstCharacter("2"))
  assert project_name.validate("my-app")
    == Error(project_name.BadCharacter("-", 2))
  assert project_name.validate("class") == Error(project_name.Reserved("class"))
  assert project_name.validate("pooka") == Error(project_name.Reserved("pooka"))
  let assert Error(project_name.TooLong(65)) =
    project_name.validate(string.repeat("a", 65))
}

pub fn name_suggestions_test() {
  assert project_name.suggest("My-App") == Some("my_app")
  assert project_name.suggest("hello world") == Some("hello_world")
  assert project_name.suggest("--app--") == Some("app")
  assert project_name.suggest("my_app") == None
  assert project_name.suggest("123") == None
}

pub fn minimal_manifest_test() {
  let assert Ok(loaded) =
    project.parse_manifest(
      "name = \"hello\"\nversion = \"0.1.0\"\n",
      "pooka.toml",
      "/p",
    )
  assert loaded
    == project.Project(
      root: "/p",
      name: "hello",
      version: "0.1.0",
      dependencies: [],
      dev_dependencies: [],
      origin: dependency.LocalOrigin,
      kind: dependency.Pooka,
      natives: [],
      config: config.defaults(),
    )
}

pub fn manifest_problems_test() {
  let problem = fn(text) {
    let assert Error(error) = project.parse_manifest(text, "pooka.toml", "/p")
    project_error.id(error)
  }
  assert problem("version = \"0.1.0\"") == "project.manifest_missing_field"
  assert problem("name = 1\nversion = \"0.1.0\"")
    == "project.manifest_field_type"
  assert problem("name = \"Bad\"\nversion = \"0.1.0\"")
    == "project.manifest_invalid_name"
  assert problem("name = ") == "project.manifest_syntax"
}

pub fn template_matches_the_toolchain_specification_test() {
  assert template.directories()
    == ["src", "test", ".github", ".github/workflows"]
  assert list.map(template.files("my_app"), fn(file) { file.0 })
    == [
      "pooka.toml",
      "src/main.pooka",
      "test/main.spec.pooka",
      "README.md",
      ".gitignore",
      ".github/workflows/test.yml",
    ]
}

pub fn template_main_module_parses_test() {
  let module = support.parse(template.main_module("my_app"))
  let assert Some(_) = module.header
  let assert [_] = module.declarations
}

pub fn template_snapshot_test() {
  template.files("my_app")
  |> list.map(fn(file) { "--- " <> file.0 <> " ---\n" <> file.1 })
  |> string.join("\n")
  |> birdie.snap(title: "project: files of a new project")
}

pub fn create_test() {
  use directory <- support.with_directory("project_create")
  let assert Ok(created) = project.create(directory, "my_app")
  assert created.root == directory <> "/my_app"
  assert simplifile.is_file(directory <> "/my_app/pooka.toml") == Ok(True)
  assert simplifile.is_file(directory <> "/my_app/src/main.pooka") == Ok(True)
  assert simplifile.read(directory <> "/my_app/test/main.spec.pooka")
    == Ok(template.main_spec())
  assert simplifile.read(directory <> "/my_app/.github/workflows/test.yml")
    == Ok(template.github_workflow())
}

// An existing path belongs to the user even when it contains only one small
// file. Refuse creation before any template write can replace it.
pub fn create_never_overwrites_test() {
  use directory <- support.with_directory("project_create_exists")
  support.write(directory <> "/my_app/keep.txt", "keep")
  let assert Error(project_error.ProjectPathExists(_)) =
    project.create(directory, "my_app")
  assert simplifile.read(directory <> "/my_app/keep.txt") == Ok("keep")
}

pub fn create_rejects_invalid_names_test() {
  use directory <- support.with_directory("project_create_invalid")
  let assert Error(project_error.InvalidProjectName("Bad", _)) =
    project.create(directory, "Bad")
  assert simplifile.is_directory(directory <> "/Bad") == Ok(False)
}

pub fn find_root_searches_parents_test() {
  use directory <- support.with_directory("project_find_root")
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/app/src/web/router.pooka", "module router\n")
  assert project.find_root(directory <> "/app/src/web")
    == Ok(directory <> "/app")
}

pub fn find_root_outside_a_project_test() {
  use directory <- support.with_directory("project_no_root")
  let assert Error(project_error.NotInProject(_)) = project.find_root(directory)
}

// Production discovery accepts ordinary source files; test discovery
// deliberately selects only .spec.pooka files. Hidden and unrelated files
// stay outside the input set.
pub fn source_discovery_test() {
  use directory <- support.with_directory("project_sources")
  let root = directory <> "/app"
  support.write(root <> "/pooka.toml", "name = \"app\"\nversion = \"0.1.0\"\n")
  support.write(root <> "/src/main.pooka", "")
  support.write(root <> "/src/web/router.pooka", "")
  support.write(root <> "/src/notes.txt", "")
  support.write(root <> "/src/.hidden.pooka", "")
  support.write(root <> "/test/web/router.spec.pooka", "")
  support.write(root <> "/test/helper.pooka", "")
  let assert Ok(loaded) = project.load(root)
  let assert Ok(files) = project.source_files(loaded)
  assert files
    == [
      project.SourceFile("src/main.pooka", project.Production),
      project.SourceFile("src/web/router.pooka", project.Production),
      project.SourceFile("test/web/router.spec.pooka", project.TestSource),
    ]
}

pub fn missing_source_directory_test() {
  use directory <- support.with_directory("project_no_src")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  let assert Ok(loaded) = project.load(directory)
  let assert Error(project_error.NoSourceDirectory(_)) =
    project.source_files(loaded)
}

// The starter manifest documents optional metadata as comments. It must
// build unchanged, and every commented example must be valid once enabled.
pub fn template_manifest_defaults_test() {
  let assert Ok(loaded) =
    project.parse_manifest(template.manifest("my_app"), "pooka.toml", "/p")
  assert loaded.name == "my_app"
  assert loaded.version == "1.0.0"
  assert loaded.dependencies
    == [dependency.Hex("pooka_stdlib", ">= 0.1.0 and <= 1.0.0", False)]
  assert loaded.dev_dependencies == []
  assert loaded.config == config.defaults()
}

pub fn template_manifest_examples_are_valid_test() {
  let enabled =
    template.manifest("my_app")
    |> string.split("\n")
    |> list.map(fn(line) {
      case line {
        "# " <> rest ->
          case
            string.contains(rest, " = ")
            || string.starts_with(rest, "[")
            || string.starts_with(rest, "]")
          {
            True -> rest
            False -> line
          }
        _ -> line
      }
    })
    |> string.join("\n")
  let assert Ok(loaded) = project.parse_manifest(enabled, "pooka.toml", "/p")
  assert loaded.config.description == "A Pooka project"
  assert loaded.config.authors == ["Your Name"]
  assert loaded.config.licences == ["Apache-2.0"]
  assert loaded.config.repository
    == Some(config.Repository("https://github.com/your-name/my_app"))
  assert loaded.config.links == [config.Link("Website", "https://example.com")]
  assert loaded.config.pages
    == [config.Page("Guide", "guide.html", "docs/guide.md")]
  assert list.sort(
      list.map(loaded.dependencies, fn(d) { d.name }),
      string.compare,
    )
    == ["helper", "parser", "pooka_stdlib"]
  assert list.contains(
    loaded.dependencies,
    dependency.Git(
      "parser",
      "https://github.com/your-name/parser",
      "tag:v1.0.0",
    ),
  )
  assert loaded.dev_dependencies
    == [dependency.Local("test_helpers", "../test_helpers")]
}

pub fn template_manifest_keeps_comments_when_adding_test() {
  let manifest = template.manifest("my_app")
  let updated =
    edit.rewrite(
      manifest,
      "helper",
      Some(#(dependency.Local("helper", "../helper"), False)),
    )
  assert string.contains(updated, "# A one-line summary")
  assert string.contains(
    updated,
    "[dependencies]\nhelper = { path = \"../helper\" }\npooka_stdlib = \">= 0.1.0 and <= 1.0.0\"\n# Add packages",
  )
  let assert Ok(loaded) = project.parse_manifest(updated, "pooka.toml", "/p")
  assert loaded.dependencies
    == [
      dependency.Local("helper", "../helper"),
      dependency.Hex("pooka_stdlib", ">= 0.1.0 and <= 1.0.0", False),
    ]
  assert edit.rewrite(updated, "helper", None) == manifest
}

pub fn standard_library_template_does_not_depend_on_itself_test() {
  let assert Ok(loaded) =
    project.parse_manifest(
      template.manifest("pooka_stdlib"),
      "pooka.toml",
      "/p",
    )
  assert loaded.dependencies == []
}
