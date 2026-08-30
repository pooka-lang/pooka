//// Seal the parcel only after checking its contents.
////
//// Publication builds the production source set, exports portable Erlang in
//// memory, and prepares both archives before any request leaves the machine.
//// The same preview feeds dry runs and the interactive confirmation.
////
//// ```sh
//// pooka publish --dry-run
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import builder/docs
import builder/native
import diagnostics/diagnostic
import filepath
import gleam/list
import gleam/result
import gleam/string
import project/config
import project/dependency
import project/hex
import project/project
import project/project_error
import project/semver
import project/spdx
import project/template
import simplifile

pub type Report {
  Report(
    name: String,
    version: String,
    package: String,
    documentation: String,
    files: List(String),
    requirements: List(#(String, String)),
  )
}

pub type Upload =
  fn(String, String, BitArray) -> Result(Nil, String)

/// Keep first publication offline and reviewable. Only upload/4 talks to Hex.
///
/// ```text
/// checked production build -> portable sources + metadata -> two tarballs
/// ```
pub fn prepare(directory: String) -> Result(Report, build.Failure) {
  use root <- result.try(project.find_root(directory) |> project_failure)
  use project <- result.try(project.load(root) |> project_failure)
  let failure = fn(detail) { package_failure(detail) }
  use Nil <- result.try(validate(project) |> result.map_error(failure))
  use built <- result.try(build.build_production(directory))
  use documented <- result.try(docs.generate(directory))
  use generated <- result.try(
    sources(built.directory) |> result.map_error(failure),
  )
  use requirements <- result.try(
    list.try_map(project.dependencies, fn(dep) {
      let assert dependency.Hex(name, requirement, optional) = dep
      use app <- result.try(
        dependency_application(project, dep, built.checked.packages, hex.fetch)
        |> project_failure,
      )
      Ok(#(name, app, requirement, optional))
    }),
  )
  let links =
    config.documentation_links(project.config)
    |> list.map(fn(link) { #(link.title, link.href) })
  use paths <- result.try(
    archive(
      project.root,
      documented.directory,
      project.name,
      project.version,
      project.config.description,
      project.config.licences,
      links,
      requirements,
      list.map(project.config.pages, fn(page) { page.source }),
      [#("rebar.config", rebar_config(requirements)), ..generated],
      ["pooka", "rebar3"],
      True,
    )
    |> result.map_error(failure),
  )
  Ok(Report(
    project.name,
    project.version,
    paths.0,
    paths.1,
    paths.2,
    list.map(requirements, fn(r) { #(r.0, r.2) }),
  ))
}

/// Optional dependencies may be absent from the selected graph. Read their
/// release metadata rather than guessing that the Hex and OTP names are equal.
///
/// ```text
/// Hex package alias -> {app, actual_otp_name} in release metadata
/// ```
pub fn dependency_application(
  root: project.Project,
  dep: dependency.Dependency,
  packages: List(project.Project),
  fetch: hex.Fetch,
) -> Result(String, project_error.ProjectError) {
  case list.find(packages, fn(p) { p.name == dep.name }) {
    Ok(package) -> Ok(native.application(package))
    Error(_) -> {
      let assert dependency.Hex(name, requirement, _) = dep
      use candidates <- result.try(hex.candidates(
        root,
        name,
        requirement,
        [],
        False,
        fetch,
      ))
      optional_application(
        candidates,
        project_error.DependencyProblem(
          "pooka.toml",
          "No usable Hex release for " <> name,
        ),
      )
    }
  }
}

fn optional_application(
  candidates: List(fn() -> Result(project.Project, project_error.ProjectError)),
  last: project_error.ProjectError,
) -> Result(String, project_error.ProjectError) {
  case candidates {
    [] -> Error(last)
    [candidate, ..rest] ->
      case candidate() {
        Ok(package) -> Ok(native.application(package))
        Error(error) -> optional_application(rest, error)
      }
  }
}

fn validate(project: project.Project) -> Result(Nil, String) {
  use version <- result.try(
    semver.parse(project.version)
    |> result.map_error(fn(_) {
      "Package versions must be semantic versions, such as 1.2.3."
    }),
  )
  let _ = version
  let core =
    project.version
    |> string.split("+")
    |> list.first
    |> result.unwrap("")
    |> string.split("-")
    |> list.first
    |> result.unwrap("")
  use Nil <- result.try(
    case
      list.length(string.split(core, ".")) == 3
      && string.trim(project.version) == project.version
    {
      True -> Ok(Nil)
      False ->
        Error(
          "Package versions must include major, minor and patch numbers, such as 1.2.3.",
        )
    },
  )
  use Nil <- result.try(
    case
      string.trim(project.config.description) != ""
      && project.config.licences != []
    {
      True -> Ok(Nil)
      False ->
        Error(
          "Set a non-empty `description` and `licences = [\"Apache-2.0\"]` (or your SPDX licences) in pooka.toml before publishing.",
        )
    },
  )
  use Nil <- result.try(
    list.try_each(project.config.licences, fn(id) {
      case spdx.valid(id) {
        True -> Ok(Nil)
        False -> Error("Unknown SPDX licence identifier: " <> id)
      }
    }),
  )
  use readme <- result.try(
    simplifile.read(filepath.join(project.root, "README.md"))
    |> result.map_error(fn(_) {
      "Add a README.md describing this package before publishing."
    }),
  )
  use Nil <- result.try(
    case
      string.trim(readme) == ""
      || normalize(readme) == normalize(template.readme(project.name))
    {
      True ->
        Error(
          "Replace the empty or generated README.md with package documentation before publishing.",
        )
      False -> Ok(Nil)
    },
  )
  use Nil <- result.try(case project.natives {
    [] -> Ok(Nil)
    _ ->
      Error(
        "Publishing native components is not supported yet; a portable package must not depend on a machine-local native build.",
      )
  })
  list.try_each(project.dependencies, fn(dep) {
    case dep {
      dependency.Hex(_, _, _) -> Ok(Nil)
      _ ->
        Error(
          "Published dependencies must come from Hex; replace local and Git dependencies before publishing.",
        )
    }
  })
}

fn normalize(text: String) -> String {
  text
  |> string.replace("\r", "")
  |> string.replace("\n", "")
  |> string.replace("\t", "")
  |> string.replace(" ", "")
}

fn rebar_config(requirements: List(#(String, String, String, Bool))) -> String {
  // Names and requirements were validated by the manifest/registry decoders;
  // OTP app names may differ from their Hex package names.
  let dependencies =
    requirements
    |> list.filter(fn(r) { !r.3 })
    |> list.map(fn(r) {
      "{" <> r.1 <> ", \"" <> r.2 <> "\", {pkg, " <> r.0 <> "}}"
    })
    |> string.join(", ")
  "{erl_opts, [debug_info]}.\n{deps, [" <> dependencies <> "]}.\n"
}

pub fn preview(report: Report) -> String {
  "\nFiles:\n"
  <> {
    report.files |> list.map(fn(file) { "  " <> file <> "\n" }) |> string.concat
  }
  <> "\nPackage: "
  <> report.name
  <> "\nVersion: "
  <> report.version
  <> "\nDependencies:\n"
  <> case report.requirements {
    [] -> "  none\n"
    requirements ->
      requirements
      |> list.map(fn(r) { "  " <> r.0 <> " " <> r.1 <> "\n" })
      |> string.concat
  }
  <> case string.starts_with(report.version, "0.") {
    True -> "\nThis is a 0.x release; its public API may still change.\n"
    False -> ""
  }
  <> "\nPrepared "
  <> report.package
  <> "\nPrepared "
  <> report.documentation
  <> "\n"
}

pub fn upload(
  report: Report,
  key: String,
  send: Upload,
) -> Result(Nil, String) {
  upload_with_options(report, key, False, False, send)
}

/// A docs-only retry never sends the package again. A replacement explicitly
/// opts into Hex's server-enforced replacement window.
pub fn upload_with_options(
  report: Report,
  key: String,
  replace: Bool,
  docs_only: Bool,
  send: Upload,
) -> Result(Nil, String) {
  use Nil <- result.try(case string.trim(key) {
    "" ->
      Error(
        "Set HEX_API_KEY (or HEXPM_API_KEY) to publish. Use --dry-run to inspect archives without uploading.",
      )
    _ -> Ok(Nil)
  })
  use documentation <- result.try(
    simplifile.read_bits(report.documentation)
    |> result.map_error(simplifile.describe_error),
  )
  use Nil <- result.try(case docs_only {
    True -> Ok(Nil)
    False -> {
      use package <- result.try(
        simplifile.read_bits(report.package)
        |> result.map_error(simplifile.describe_error),
      )
      send(
        "https://hex.pm/api/publish"
          <> case replace {
          True -> "?replace=true"
          False -> ""
        },
        key,
        package,
      )
    }
  })
  send(
    "https://hex.pm/api/packages/"
      <> report.name
      <> "/releases/"
      <> report.version
      <> "/docs",
    key,
    documentation,
  )
  |> result.map_error(fn(error) {
    case docs_only {
      True -> error
      False ->
        "Package published, but documentation upload failed: "
        <> error
        <> "\nRetry with `pooka publish --docs-only`."
    }
  })
}

fn package_failure(detail: String) -> build.Failure {
  build.Failure(Error(Nil), [
    diagnostic.error("publish.package", "package could not be prepared")
    |> diagnostic.conclusion(detail),
  ])
}

fn project_failure(
  result: Result(a, project_error.ProjectError),
) -> Result(a, build.Failure) {
  result
  |> result.map_error(fn(error) {
    build.Failure(Error(Nil), [project_error.to_diagnostic(error)])
  })
}

@external(erlang, "pooka_publish_ffi", "archive")
fn archive(
  root: String,
  docs: String,
  name: String,
  version: String,
  description: String,
  licences: List(String),
  links: List(#(String, String)),
  requirements: List(#(String, String, String, Bool)),
  page_sources: List(String),
  generated: List(#(String, String)),
  tools: List(String),
  include_sources: Bool,
) -> Result(#(String, String, List(String)), String)

@external(erlang, "pooka_publish_ffi", "sources")
fn sources(ebin: String) -> Result(List(#(String, String)), String)

@external(erlang, "pooka_publish_ffi", "post")
pub fn post(url: String, key: String, body: BitArray) -> Result(Nil, String)

@external(erlang, "pooka_publish_ffi", "api_key")
pub fn api_key() -> String

@external(erlang, "pooka_publish_ffi", "confirm")
pub fn confirm(preview: String) -> Bool
