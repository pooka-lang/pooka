//// Prepare the parcel before sending it anywhere.
////
//// Inspect source and documentation archives, Hex metadata and configured
//// guide files. Upload callbacks are injected, so these tests do not publish
//// packages. Missing credentials and partial upload failures must retain
//// useful state and explain what completed.

import birdie
import builder/publish
import cli/command
import cli/commands/publish as publish_command
import gleam/bit_array
import gleam/list
import gleam/string
import project/dependency
import project/project
import project/template
import simplifile
import support

@external(erlang, "publish_test_ffi", "inspect_archive")
fn inspect_archive(package: String, documentation: String) -> Bool

// Inspect the archive locally and inject upload callbacks. These assertions
// cover publication behavior without sending a real package to Hex.
pub fn publish_prepares_hex_v3_sources_and_documentation_without_uploading_test() {
  use dir <- support.with_directory("publish_archive")
  support.write(
    dir <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.2.3\"\ndescription = \"Example API\"\nlicences = [\"Apache-2.0\"]\n",
  )
  support.write(
    dir <> "/src/main.pooka",
    "module main\n/// The answer.\nanswer() { 42 }\n",
  )
  support.write(dir <> "/README.md", "# Example API\n")
  support.write(dir <> "/priv/data.txt", "resource")
  support.write(dir <> "/assets/icon.svg", "<svg></svg>")
  support.write(dir <> "/test/invalid.spec.pooka", "invalid")
  support.write(dir <> "/dev/secret", "excluded")
  let assert Ok(report) = publish.prepare(dir)
  assert inspect_archive(report.package, report.documentation)
  assert publish.upload(report, "", fn(_, _, _) { panic })
    |> fn(r) {
      case r {
        Error(e) -> string.contains(e, "HEX_API_KEY")
        _ -> False
      }
    }
  assert publish.upload(report, "test-key", fn(url, key, body) {
      assert key == "test-key"
      assert body != <<>>
      assert string.starts_with(url, "https://hex.pm/api/")
      Ok(publish.Published)
    })
    == Ok([])
  assert publish.upload(report, "test-key", fn(url, _, _) {
      case string.ends_with(url, "/docs") {
        True -> Error("fixture error")
        False -> Ok(publish.Published)
      }
    })
    == Error(
      "Package published, but documentation upload failed: fixture error\nRetry with `pooka publish --docs-only`.",
    )
  let assert Ok(previous) = simplifile.read_bits(report.package)
  support.write(dir <> "/src/bad.pooka", "broken")
  let assert Error(_) = publish.prepare(dir)
  assert simplifile.read_bits(report.package) == Ok(previous)
}

@external(erlang, "publish_test_ffi", "package_metadata")
fn package_metadata(package: String) -> #(List(#(String, String)), List(String))

pub fn publication_preserves_repository_links_and_configured_guide_sources_test() {
  use dir <- support.with_directory("publish_config_metadata")
  support.write(
    dir <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.2.3\"\ndescription = \"Example API\"\nlicences = [\"MIT\"]\nlinks = [{title = \"Website\", href = \"https://example.org\"}]\n[repository]\ntype = \"github\"\nuser = \"example\"\nrepo = \"package\"\n[[documentation.pages]]\ntitle = \"Guide\"\npath = \"guide.html\"\nsource = \"docs/guide.md\"\n",
  )
  support.write(dir <> "/src/main.pooka", "module main\nanswer() { 42 }\n")
  support.write(
    dir <> "/README.md",
    "# A real package\nA useful example library.\n",
  )
  support.write(dir <> "/docs/guide.md", "# A reproducible guide\n")
  let assert Ok(report) = publish.prepare(dir)
  let #(links, files) = package_metadata(report.package)
  assert links
    == [
      #("Repository", "https://github.com/example/package"),
      #("Website", "https://example.org"),
    ]
  assert list.contains(files, "docs/guide.md")
}

@external(erlang, "publish_test_ffi", "package_requirements")
fn package_requirements(
  package: String,
) -> List(#(String, String, String, Bool))

@external(erlang, "publish_test_ffi", "compiles_generated_sources")
fn compiles_generated_sources(package: String) -> Bool

@external(erlang, "publish_test_ffi", "archive_text")
fn archive_text(package: String, path: String) -> String

@external(erlang, "pooka_publish_ffi", "response")
fn hex_response(
  status: Int,
  headers: List(#(String, String)),
  body: String,
) -> Result(publish.UploadState, String)

fn package(dir: String) {
  support.write(
    dir <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\ndescription = \"A useful library\"\nlicences = [\"MIT\"]\n",
  )
  support.write(dir <> "/src/value.pooka", "module value\nanswer() { 42 }")
  support.write(
    dir <> "/README.md",
    "# An actual package\nThis library returns an answer.\n",
  )
}

// Inspect what a foreign tool will compile, including Erlang FFI and shadowed
// BIF names. No precompiled module or duplicate runtime enters the parcel.
pub fn portable_erlang_sources_and_runtime_requirement_test() {
  use dir <- support.with_directory("publish_portable")
  package(dir)
  support.write(
    dir <> "/src/value.pooka",
    "module value\nexternal Ffi from erlang \"answer_ffi\" { answer() -> Int }\nlength(x: Int) { x }\nanswer() { length(Ffi.answer()) }",
  )
  support.write(
    dir <> "/ffi/answer_ffi.erl",
    "-module(answer_ffi).\n-export([answer/0]).\nanswer() -> 42.\n",
  )
  let assert Ok(report) = publish.prepare(dir)
  assert package_requirements(report.package) == []
  assert string.contains(
    archive_text(report.package, "rebar.config"),
    "{deps, []}",
  )
  assert string.contains(
    archive_text(report.package, "src/pooka@app@value.erl"),
    "-compile(no_auto_import).",
  )
  assert string.contains(
    archive_text(report.package, "src/answer_ffi.erl"),
    "answer() ->",
  )
  assert archive_text(report.package, "src/pooka_runtime_ffi.erl") == ""
  assert !list.any(report.files, string.ends_with(_, ".beam"))
  let assert Ok(files) = simplifile.get_files(dir <> "/build/prod/erlang")
  assert !list.any(files, string.ends_with(_, ".erl"))
}

pub fn package_archive_embeds_runtime_source_without_a_hex_dependency_test() {
  use dir <- support.with_directory("publish_embedded_runtime")
  package(dir)
  let assert Ok(report) = publish.prepare(dir)
  assert report.requirements == []
  assert package_requirements(report.package) == []
  assert compiles_generated_sources(report.package)
  assert string.contains(
    archive_text(report.package, "src/pooka@app@@runtime.erl"),
    "-module(pooka@app@@runtime).",
  )
  assert string.contains(
    archive_text(report.package, "src/app.app.src"),
    "pooka@app@@runtime",
  )
  assert !string.contains(
    archive_text(report.package, "src/app.app.src"),
    "pooka_runtime",
  )
  let rejected =
    publish_command.run_with(
      ["--runtime"],
      command.plain(dir),
      fn(_) { panic },
      fn() { panic },
      fn(_, _, _) { panic },
    )
  assert rejected.status == 1
}

pub fn invalid_metadata_readme_and_dependencies_are_rejected_test() {
  use dir <- support.with_directory("publish_validation")
  package(dir)
  let assert Ok(manifest) = simplifile.read(dir <> "/pooka.toml")
  list.each(
    [
      #("version = \"0.1.0\"", "version = \"1.2\""),
      #("MIT", "Not-A-Licence"),
      #("A useful library", ""),
    ],
    fn(change) {
      support.write(
        dir <> "/pooka.toml",
        string.replace(manifest, change.0, change.1),
      )
      let assert Error(_) = publish.prepare(dir)
    },
  )
  support.write(dir <> "/pooka.toml", manifest)
  let assert Ok(Nil) = simplifile.delete_file(dir <> "/README.md")
  let assert Error(_) = publish.prepare(dir)
  support.write(dir <> "/README.md", "  \n\t")
  let assert Error(_) = publish.prepare(dir)
  support.write(dir <> "/README.md", template.readme("app"))
  let assert Error(_) = publish.prepare(dir)
  support.write(dir <> "/README.md", "# A real library")
  support.write(
    dir <> "/pooka.toml",
    manifest <> "[dependencies]\nlocal = {path = \"../local\"}\n",
  )
  let assert Error(_) = publish.prepare(dir)
}

pub fn conflicting_generated_files_preserve_previous_archive_test() {
  use dir <- support.with_directory("publish_conflict")
  package(dir)
  let assert Ok(report) = publish.prepare(dir)
  let assert Ok(previous) = simplifile.read_bits(report.package)
  support.write(dir <> "/src/pooka@app@value.erl", "-module(other).")
  let assert Error(_) = publish.prepare(dir)
  assert simplifile.read_bits(report.package) == Ok(previous)
}

pub fn docs_only_and_replace_are_distinct_uploads_test() {
  use dir <- support.with_directory("publish_retry")
  package(dir)
  let assert Ok(report) = publish.prepare(dir)
  assert publish.upload_with_options(
      report,
      "fake-key",
      False,
      True,
      fn(url, _, _) {
        assert string.ends_with(url, "/docs")
        Ok(publish.Published)
      },
    )
    == Ok([])
  assert publish.upload_with_options(
      report,
      "fake-key",
      True,
      False,
      fn(url, _, _) {
        assert url == "https://hex.pm/api/publish?replace=true"
          || string.ends_with(url, "/docs")
        Ok(publish.Published)
      },
    )
    == Ok([])
}

pub fn hex_errors_preserve_validation_details_and_detect_staging_test() {
  let assert Error(detail) =
    hex_response(
      422,
      [],
      "{\"message\":\"validation failed\",\"errors\":{\"name\":\"already taken\"}}",
    )
  assert string.contains(detail, "422")
  assert string.contains(detail, "name")
  assert string.contains(detail, "already taken")
  let assert Error(otp) =
    hex_response(403, [], "{\"message\":\"two factor required\"}")
  assert string.contains(otp, "HEX_OTP")
  let assert Ok(publish.Staged(staged)) =
    hex_response(
      201,
      [#("location", "https://hex.pm/api/packages/app/releases/1.0.0/staged")],
      "{}",
    )
  assert staged == "https://hex.pm/dashboard/staged-releases"
  let assert Error(safe) = hex_response(400, [], "\u{001b}[31mbad request")
  assert !string.contains(safe, "\u{001b}")
  assert hex_response(201, [], "{}") == Ok(publish.Published)
}

pub fn dry_run_and_declined_publication_never_read_credentials_or_upload_test() {
  use dir <- support.with_directory("publish_consent")
  package(dir)
  let env = command.plain(dir)
  let outcome =
    publish_command.run_with(
      ["--dry-run"],
      env,
      fn(_) { panic },
      fn() { panic },
      fn(_, _, _) { panic },
    )
  assert outcome.status == 0
  assert string.contains(outcome.stdout, "pooka@app@@runtime.erl")
  assert string.contains(outcome.stdout, "0.x release")
  let declined =
    publish_command.run_with(
      [],
      command.Environment(..env, inherit_stdio: True),
      fn(preview) {
        assert string.contains(preview, "Package: app")
        False
      },
      fn() { panic },
      fn(_, _, _) { panic },
    )
  assert declined.status == 0
  assert string.contains(declined.stdout, "Not publishing")
  let captured =
    publish_command.run_with(
      [],
      env,
      fn(_) { panic },
      fn() { panic },
      fn(_, _, _) { panic },
    )
  assert string.contains(captured.stdout, "--yes")
  let sent =
    publish_command.run_with(
      ["--yes"],
      env,
      fn(_) { panic },
      fn() { "fake-key" },
      fn(_, key, _) {
        assert key == "fake-key"
        Ok(publish.Published)
      },
    )
  assert sent.status == 0
  assert string.contains(sent.stdout, "Published app 0.1.0")
  assert string.contains(sent.stdout, "https://app.hexdocs.pm/")
}

pub fn package_preview_snapshot_test() {
  use dir <- support.with_directory("publish_preview_snapshot")
  package(dir)
  let assert Ok(report) = publish.prepare(dir)
  publish.preview(report)
  |> string.replace(dir, "<project>")
  |> birdie.snap(title: "publish package preview")
}

pub fn optional_dependencies_keep_the_actual_otp_application_name_test() {
  use dir <- support.with_directory("publish_optional_app")
  package(dir)
  let assert Ok(root) = project.load(dir)
  let assert Ok(name) =
    publish.dependency_application(
      root,
      dependency.Hex("alias", "~> 1.0", True),
      [],
      fn(url) {
        Ok(
          bit_array.from_string(case string.contains(url, "/releases/") {
            True ->
              "{\"version\":\"1.0.0\",\"checksum\":\""
              <> string.repeat("0", 64)
              <> "\",\"requirements\":{},\"meta\":{\"app\":\"actual_app\",\"build_tools\":[\"rebar3\"]}}"
            False -> "{\"releases\":[{\"version\":\"1.0.0\"}]}"
          }),
        )
      },
    )
  assert name == "actual_app"
}

// Accepted staging must not stop the second upload. Distinct URLs also cover
// servers that keep package and documentation approvals separate.
pub fn staged_package_still_uploads_documentation_test() {
  use dir <- support.with_directory("publish_combined_staging")
  package(dir)
  let assert Ok(report) = publish.prepare(dir)
  let package_url = "https://hex.pm/dashboard/staged-releases/hexpm/app/0.1.0"
  let docs_url = package_url <> "/docs"
  assert publish.upload(report, "fake-key", fn(url, _, _) {
      case string.ends_with(url, "/docs") {
        True -> Ok(publish.Staged(docs_url))
        False -> Ok(publish.Staged(package_url))
      }
    })
    == Ok([package_url, docs_url])
  let assert Error(detail) =
    publish.upload(report, "fake-key", fn(url, _, _) {
      case string.ends_with(url, "/docs") {
        True -> Error("docs rejected")
        False -> Ok(publish.Staged(package_url))
      }
    })
  assert string.contains(detail, "Package staged for approval")
  assert !string.contains(detail, "Package published")
  assert string.contains(detail, "--docs-only")
  assert publish.upload(report, "fake-key", fn(url, _, _) {
      assert !string.ends_with(url, "/docs")
      Error("package rejected")
    })
    == Error("package rejected")
}

pub fn combined_staging_prints_one_approval_and_never_claims_publication_test() {
  use dir <- support.with_directory("publish_staging_output")
  package(dir)
  let approval = "https://hex.pm/dashboard/staged-releases/hexpm/app/0.1.0"
  let outcome =
    publish_command.run_with(
      ["--yes"],
      command.plain(dir),
      fn(_) { panic },
      fn() { "fake-key" },
      fn(_, _, _) { Ok(publish.Staged(approval)) },
    )
  assert outcome.status == 0
  assert outcome.stderr == ""
  assert string.contains(outcome.stdout, "package and documentation.")
  assert !string.contains(outcome.stdout, "Published app")
  assert list.length(string.split(outcome.stdout, approval)) == 2
  let docs =
    publish_command.run_with(
      ["--yes", "--docs-only"],
      command.plain(dir),
      fn(_) { panic },
      fn() { "fake-key" },
      fn(url, _, _) {
        assert string.ends_with(url, "/docs")
        Ok(publish.Staged(approval))
      },
    )
  assert docs.status == 0
  assert string.contains(docs.stdout, "0.1.0 documentation.")
}

pub fn staging_response_body_is_recognised_without_location_header_test() {
  let approval = "https://hex.pm/dashboard/staged-releases/hexpm/app/0.1.0"
  assert hex_response(
      201,
      [],
      "{\"status\":\"staged\",\"html_url\":\"" <> approval <> "\"}",
    )
    == Ok(publish.Staged(approval))
  assert hex_response(
      201,
      [],
      "{\"status\":\"staged\",\"html_url\":\"https://other.invalid/approval\"}",
    )
    == Ok(publish.Staged("https://hex.pm/dashboard/staged-releases"))
}

// Registry strings reach the terminal. A dashboard-looking URL must not carry
// embedded terminal controls or a line break into the approval output.
pub fn staging_approval_links_reject_control_characters_test() {
  assert hex_response(
      201,
      [],
      "{\"status\":\"staged\",\"html_url\":\"https://hex.pm/dashboard/staged-releases/\\u001b[31m\"}",
    )
    == Ok(publish.Staged("https://hex.pm/dashboard/staged-releases"))
}
