//// Let the author inspect the parcel before it leaves the porch.
////
//// Dry runs and real publication share preparation and a file/dependency preview.
//// A captured command environment never reads stdin or sends an upload unless
//// --yes was explicitly supplied. Interactive keys live only for one invocation.
////
//// ```sh
//// pooka publish --dry-run
//// pooka publish --docs-only
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/publish
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/build as build_command
import cli/publish_session
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import project/hexdocs

pub const info =
  Info(
    name: "publish",
    arguments: "[options]",
    summary: "Prepare or publish a package and documentation to Hex",
  )

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  run_with_interaction(
    arguments,
    environment,
    publish.confirm,
    publish.api_key,
    publish_session.otp,
    publish_session.post,
    publish_session.system(),
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
  run_with_interaction(
    arguments,
    environment,
    confirm,
    key,
    fn() { "" },
    fn(url, key, _, body) {
      send(url, key, body)
      |> result.map_error(publish_session.TransportFailure)
    },
    publish_session.Interaction(
      fn() { True },
      fn(_) { Error(publish_session.missing_key) },
      fn(_) { False },
      fn(_) { Nil },
    ),
  )
}

/// Keep terminal detection and hidden input injectable alongside the transport.
/// Captured commands, --yes and redirected input never ask for credentials.
pub fn run_with_interaction(
  arguments: List(String),
  environment: Environment,
  confirm: fn(String) -> Bool,
  key: fn() -> String,
  otp: fn() -> String,
  send: publish_session.Transport,
  io: publish_session.Interaction,
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
          let preview =
            publish.preview(report)
            <> case
              list.contains(arguments, "--docs-only"),
              list.contains(arguments, "--replace")
            {
              True, _ ->
                "\nPublication: documentation only; the package is unchanged.\n"
              _, True ->
                "\nPublication: replace this package version and its documentation, if Hex permits it.\n"
              _, _ -> ""
            }
          case list.contains(arguments, "--dry-run") {
            True -> Outcome(preview, "", 0)
            False -> {
              let automatic = list.contains(arguments, "--yes")
              let interactive =
                !automatic && environment.inherit_stdio && io.terminal()
              let approved = automatic || { interactive && confirm(preview) }
              // The interactive confirmation already printed the file preview.
              let output_preview = case interactive {
                True -> ""
                False -> preview
              }
              case approved {
                False ->
                  Outcome(
                    output_preview
                      <> "\nNot publishing. Use --yes for non-interactive publication.\n",
                    "",
                    0,
                  )
                True -> {
                  let docs_only = list.contains(arguments, "--docs-only")
                  case
                    publish_session.start(key(), otp(), interactive, io)
                    |> result.try(fn(session) {
                      publish.upload_with_session(
                        report,
                        session,
                        list.contains(arguments, "--replace"),
                        docs_only,
                        fn(url, session, body) {
                          publish_session.send(url, session, body, send, io)
                        },
                      )
                    })
                  {
                    Error(detail) -> failure(detail, environment)
                    Ok([_, ..] as approvals) ->
                      Outcome(
                        output_preview
                          <> "\nUploaded "
                          <> report.name
                          <> " "
                          <> report.version
                          <> case docs_only {
                          True -> " documentation"
                          False -> " package and documentation"
                        }
                          <> ".\nHex approval is required for the pending files; they are not public yet.\n"
                          <> string.join(approvals, "\n")
                          <> "\n",
                        "",
                        0,
                      )
                    Ok([]) ->
                      Outcome(
                        output_preview
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
