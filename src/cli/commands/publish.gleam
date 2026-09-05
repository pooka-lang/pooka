//// Let the author inspect the parcel before it leaves the porch.
////
//// Dry runs and real publication share preparation and a file/dependency preview.
//// A captured command environment never reads stdin or sends an upload unless
//// --yes was explicitly supplied. Credentials remain in environment variables.
////
//// ```sh
//// pooka publish --dry-run
//// pooka publish --docs-only
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/publish
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/build as build_command
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import project/hexdocs

pub const info =
  Info(
    name: "publish",
    arguments: "[options]",
    summary: "Prepare or publish a package and documentation to Hex",
  )

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  run_with(
    arguments,
    environment,
    publish.confirm,
    publish.api_key,
    publish.post,
  )
}

/// Keep consent and transport injectable. Tests can inspect every request
/// without borrowing the author's credentials or contacting the registry.
pub fn run_with(
  arguments: List(String),
  environment: Environment,
  confirm: fn(String) -> Bool,
  key: fn() -> String,
  send: publish.Upload,
) -> Outcome {
  let valid = ["--dry-run", "--yes", "--replace", "--docs-only"]
  case
    list.all(arguments, fn(arg) { list.contains(valid, arg) })
    && list.length(arguments) == list.length(list.unique(arguments))
    && !{
      list.contains(arguments, "--replace")
      && list.contains(arguments, "--docs-only")
    }
  {
    False ->
      failure(
        "Usage: pooka publish [--dry-run] [--yes] [--replace | --docs-only]",
        environment,
      )
    True -> {
      let prepared = publish.prepare(environment.working_directory)
      case prepared {
        Error(error) -> build_command.failure(error, environment)
        Ok(report) -> {
          let preview = publish.preview(report)
          case list.contains(arguments, "--dry-run") {
            True -> Outcome(preview, "", 0)
            False -> {
              let approved =
                list.contains(arguments, "--yes")
                || { environment.inherit_stdio && confirm(preview) }
              case approved {
                False ->
                  Outcome(
                    preview
                      <> "\nNot publishing. Use --yes for non-interactive publication.\n",
                    "",
                    0,
                  )
                True -> {
                  let docs_only = list.contains(arguments, "--docs-only")
                  case
                    publish.upload_with_options(
                      report,
                      key(),
                      list.contains(arguments, "--replace"),
                      docs_only,
                      send,
                    )
                  {
                    Error(detail) -> failure(detail, environment)
                    Ok(Nil) ->
                      Outcome(
                        preview
                          <> "\nPublished "
                          <> report.name
                          <> " "
                          <> report.version
                          <> case docs_only {
                          True -> " documentation"
                          False -> " and documentation"
                        }
                          <> " to Hex.\nhttps://hex.pm/packages/"
                          <> report.name
                          <> "\n"
                          <> hexdocs.url(report.name)
                          <> "\n",
                        "",
                        0,
                      )
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn failure(detail: String, environment: Environment) -> Outcome {
  diagnostic.error("publish.failed", "publication failed")
  |> diagnostic.conclusion(detail)
  |> render.render(dict.new(), environment.stderr)
  |> fn(text) { Outcome("", text, 1) }
}
