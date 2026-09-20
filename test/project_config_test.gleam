//// A manifest is a notebook, not a command prompt.
////
//// Decode metadata, repositories, documentation pages and namespaced tool
//// settings. Preserve author order and typed nested values while rejecting
//// malformed or active content. Development-dependency spelling must round-
//// trip without disturbing unrelated tools.
////
//// ```toml
//// [tools.example]
//// enabled = true
//// ```

import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import project/config
import project/dependency
import project/edit
import project/project
import project/project_error
import tom

fn parse(extra: String) -> Result(project.Project, project_error.ProjectError) {
  project.parse_manifest(
    "name = \"example\"\nversion = \"1.0.0\"\n" <> extra,
    "pooka.toml",
    "/example",
  )
}

pub fn metadata_defaults_preserve_minimal_projects_test() {
  let assert Ok(project) = parse("")
  assert project.config == config.defaults()
}

pub fn metadata_and_gleam_style_links_are_loaded_in_author_order_test() {
  let assert Ok(project) =
    parse(
      "
description = \"Example package\"
authors = [\"Peregrine Finch\", \"Ada <ada@example.org>\"]
licences = [\"Apache-2.0\", \"MIT\"]
links = [{ title = \"Website\", href = \"https://example.org/?q=a&b=c\" }, { title = \"Sponsor\", href = \"https://example.org/sponsor\" }]
[repository]
type = \"github\"
user = \"example\"
repo = \"package\"
",
    )
  assert project.config.description == "Example package"
  assert project.config.authors == ["Peregrine Finch", "Ada <ada@example.org>"]
  assert project.config.licences == ["Apache-2.0", "MIT"]
  assert config.documentation_links(project.config)
    == [
      config.Link("Repository", "https://github.com/example/package"),
      config.Link("Website", "https://example.org/?q=a&b=c"),
      config.Link("Sponsor", "https://example.org/sponsor"),
    ]
}

pub fn arrays_of_link_tables_and_legacy_link_tables_are_supported_test() {
  let assert Ok(modern) =
    parse("[[links]]\ntitle = \"Home\"\nhref = \"https://example.org\"\n")
  let assert Ok(legacy) = parse("[links]\nHome = \"https://example.org\"\n")
  assert modern.config.links == legacy.config.links
}

pub fn repository_providers_and_self_hosted_links_test() {
  list.each(
    [
      #("gitlab", "https://gitlab.com/example/package"),
      #("codeberg", "https://codeberg.org/example/package"),
      #("sourcehut", "https://git.sr.ht/~example/package"),
      #("bitbucket", "https://bitbucket.org/example/package"),
      #("tangled", "https://tangled.org/example/package"),
    ],
    fn(entry) {
      let assert Ok(project) =
        parse(
          "[repository]\ntype = \""
          <> entry.0
          <> "\"\nuser = \"example\"\nrepo = \"package\"\n",
        )
      assert project.config.repository == Some(config.Repository(entry.1))
    },
  )
  let assert Ok(custom) =
    parse(
      "[repository]\ntype = \"custom\"\nurl = \"https://example.org/src\"\n",
    )
  assert custom.config.repository
    == Some(config.Repository("https://example.org/src"))
  let assert Ok(self_hosted) =
    parse(
      "[repository]\ntype = \"forgejo\"\nhost = \"https://git.example.org/\"\nuser = \"example\"\nrepo = \"package\"\n",
    )
  assert self_hosted.config.repository
    == Some(config.Repository("https://git.example.org/example/package"))
}

pub fn tool_namespaces_preserve_nested_typed_values_test() {
  let assert Ok(project) =
    parse(
      "
[tools.web.build]
minify = true
outdir = \"dist\"
ports = [3000, 3001]
[tools.web.dev]
port = 3000
[tools.pack]
enabled = false
",
    )
  let assert Ok(web) = config.tool(project.config, "web")
  assert tom.get_bool(web, ["build", "minify"]) == Ok(True)
  assert tom.get_array(web, ["build", "ports"])
    == Ok([tom.Int(3000), tom.Int(3001)])
  assert tom.get_int(web, ["dev", "port"]) == Ok(3000)
  assert config.tool(project.config, "absent") == Error(Nil)
  let assert Ok(pack) = config.tool(project.config, "pack")
  assert dict.get(pack, "enabled") == Ok(tom.Bool(False))
}

// Metadata is data even when it contains link or guide syntax. Reject active
// or malformed values instead of handing them to a later renderer unchecked.
pub fn malformed_or_executable_metadata_is_rejected_test() {
  list.each(
    [
      "description = 42", "licences = [true]", "licences = [\"\"]",
      "authors = \"Peregrine Finch\"", "authors = [7]", "authors = [\"\"]",
      "repository = false",
      "[repository]\ntype = \"unknown\"\nuser = \"x\"\nrepo = \"y\"",
      "[repository]\ntype = \"github\"\nuser = \"x\"",
      "links = [{title = \"Bad\", href = \"javascript:alert(1)\"}]",
      "links = [{title = \"Bad\", href = \"//example.org\"}]",
      "links = [{title = \"Bad\", href = \"https://\"}]",
      "links = [{title = \"Bad\", href = \"https://example.org/with space\"}]",
      "links = [{title = \"\", href = \"https://example.org\"}]", "tools = true",
      "[tools]\nweb = 7", "documentation = []",
    ],
    fn(source) {
      let assert Error(project_error.ManifestInvalidField(..)) = parse(source)
    },
  )
}

pub fn pages_validate_paths_duplicates_and_reserved_outputs_test() {
  let page = fn(output, source) {
    "[[documentation.pages]]\ntitle = \"Guide\"\npath = \""
    <> output
    <> "\"\nsource = \""
    <> source
    <> "\"\n"
  }
  let assert Ok(project) = parse(page("guide.html", "./docs/guide.md"))
  assert project.config.pages
    == [config.Page("Guide", "guide.html", "./docs/guide.md")]
  list.each(
    [
      "../escape.html",
      "index.html",
      "Index.html",
      "module-secret.html",
      "MODULE-main.html",
      "nested/guide.html",
      "guide.html?x",
      "%2e%2e.html",
    ],
    fn(output) {
      assert result.is_error(parse(page(output, "guide.md")))
    },
  )
  assert result.is_error(parse(page("guide.html", "../secret.md")))
  assert result.is_error(parse(page("guide.html", "/secret.md")))
  assert result.is_error(parse(
    page("guide.html", "guide.md") <> page("GUIDE.html", "other.md"),
  ))
}

// Accept the alternate dependency-table spelling without renaming an
// unrelated nested tool key that happens to resemble it.
pub fn underscore_development_dependencies_round_trip_without_changing_tools_test() {
  let source =
    "[dev_dependencies]\ncheck = { path = \"../check\" }\n[tools.web]\nport = 3000\n"
  let assert Ok(project) = parse(source)
  assert project.dev_dependencies == [dependency.Local("check", "../check")]
  let updated =
    edit.rewrite(
      "name = \"example\"\nversion = \"1.0.0\"\n" <> source,
      "check",
      Some(#(dependency.Local("check", "../new"), True)),
    )
  assert string.contains(updated, "[dev_dependencies]")
  assert !string.contains(updated, "[dev-dependencies]")
  assert string.contains(updated, "[tools.web]\nport = 3000")
  let assert Ok(project) =
    project.parse_manifest(updated, "pooka.toml", "/example")
  assert project.dev_dependencies == [dependency.Local("check", "../new")]
  let assert Error(_) = parse("[dev_dependencies]\n[dev-dependencies]\n")
}
