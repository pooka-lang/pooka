//// Keep the key in the author's hand, and remember which parcel arrived.
////
//// A session carries ephemeral credentials and bounded retry budgets between
//// package and documentation uploads. Prompting and transport are injected so
//// tests never borrow an account or send a parcel to Hex.
////
//// ```text
//// confirmed publication -> environment key or hidden prompt -> one upload stage
//// 401 -> one new key -> retry that stage -> continue with the same session
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/publish
import gleam/list
import gleam/result
import gleam/string

pub type Failure {
  HttpFailure(status: Int, detail: String, verification: Bool)
  TransportFailure(detail: String)
}

pub type Transport =
  fn(String, String, String, BitArray) -> Result(publish.UploadState, Failure)

pub type Interaction {
  Interaction(
    terminal: fn() -> Bool,
    secret: fn(String) -> Result(String, String),
    confirm: fn(String) -> Bool,
    notice: fn(String) -> Nil,
  )
}

pub opaque type Session {
  Session(
    key: String,
    otp: String,
    interactive: Bool,
    key_retried: Bool,
    otp_retried: Bool,
    secrets: List(String),
  )
}

pub const key_help =
  "Create a Hex API key with API Read and Publish permissions.\nhttps://hex.pm/docs/keys\n"

pub const missing_key =
  "No Hex API key is configured. Set HEX_API_KEY (or HEXPM_API_KEY), or run `pooka publish` in an interactive terminal to enter a key securely."

/// Read credentials only after the author has approved the prepared archives.
/// Entered keys stay inside this session, without changing the environment.
pub fn start(
  key: String,
  otp: String,
  interactive: Bool,
  io: Interaction,
) -> Result(Session, String) {
  let key = string.trim(key)
  use key <- result.try(case key, interactive {
    "", False -> Error(missing_key)
    "", True -> {
      io.notice("No Hex API key is configured.\n" <> key_help)
      read_secret(io, "Hex API key (hidden; Enter cancels): ")
    }
    _, _ -> Ok(key)
  })
  let otp = string.trim(otp)
  Ok(Session(key, otp, interactive, False, False, [key, otp]))
}

/// Retry only explicit authentication challenges, once each per invocation.
/// A connection failure cannot tell us whether Hex accepted the request.
///
/// ```text
/// package succeeds -> docs return 401 -> replace key -> retry docs only
/// ```
pub fn send(
  url: String,
  session: Session,
  body: BitArray,
  transport: Transport,
  io: Interaction,
) -> Result(#(publish.UploadState, Session), String) {
  case transport(url, session.key, session.otp, body) {
    Ok(state) -> Ok(#(state, session))
    Error(HttpFailure(401, detail, False)) -> {
      let detail = redact(detail, session)
      case session.interactive && !session.key_retried {
        False ->
          Error(
            detail
            <> "\nCreate a new publishing key and update HEX_API_KEY (or HEXPM_API_KEY).",
          )
        True -> {
          io.notice(detail <> "\n" <> key_help)
          case io.confirm("Try another key? [y/N] ") {
            False ->
              Error("Publication cancelled; the rejected key was not reused.")
            True -> {
              use key <- result.try(read_secret(
                io,
                "New Hex API key (hidden; Enter cancels): ",
              ))
              io.notice(
                "The new key is used only for this invocation. Update any old environment key before publishing again.\n",
              )
              send(
                url,
                Session(..session, key:, key_retried: True, secrets: [
                  key,
                  ..session.secrets
                ]),
                body,
                transport,
                io,
              )
            }
          }
        }
      }
    }
    Error(HttpFailure(_, detail, True)) -> {
      let detail = redact(detail, session)
      case session.interactive && !session.otp_retried {
        False ->
          Error(
            detail
            <> "\nHex requested verification. Set HEX_OTP to a fresh code and retry.",
          )
        True -> {
          io.notice(detail <> "\nHex requested a verification code.\n")
          use otp <- result.try(read_secret(
            io,
            "Verification code (hidden; Enter cancels): ",
          ))
          send(
            url,
            Session(..session, otp:, otp_retried: True, secrets: [
              otp,
              ..session.secrets
            ]),
            body,
            transport,
            io,
          )
        }
      }
    }
    Error(HttpFailure(status, detail, False)) -> {
      let detail = redact(detail, session)
      Error(case status {
        403 ->
          detail
          <> "\nThe key may lack publishing permission. Check its permissions in your Hex account settings."
        409 | 422 ->
          detail
          <> "\nIf this version already exists, use `pooka publish --docs-only` for documentation, or explicitly request `pooka publish --replace` within Hex's replacement window. Otherwise choose a new version in pooka.toml."
        _ -> detail
      })
    }
    Error(TransportFailure(detail)) ->
      Error(
        redact(detail, session)
        <> "\nThe upload result is uncertain. Inspect the release on hex.pm before resending the package; it may already have been accepted.",
      )
  }
}

fn read_secret(io: Interaction, prompt: String) -> Result(String, String) {
  // Backends report only fixed errors: never include entered text in an error.
  use value <- result.try(io.secret(prompt))
  case string.trim(value) {
    "" -> Error("Publication cancelled; no credential was entered.")
    value -> Ok(value)
  }
}

fn redact(detail: String, session: Session) -> String {
  list.fold(session.secrets, detail, fn(detail, secret) {
    case secret {
      "" -> detail
      _ -> string.replace(detail, secret, "[redacted]")
    }
  })
}

pub fn system() -> Interaction {
  Interaction(terminal, secret, ask, notice)
}

@external(erlang, "pooka_publish_ffi", "terminal")
fn terminal() -> Bool

@external(erlang, "pooka_publish_ffi", "secret")
fn secret(prompt: String) -> Result(String, String)

@external(erlang, "pooka_publish_ffi", "ask")
fn ask(prompt: String) -> Bool

@external(erlang, "pooka_publish_ffi", "notice")
fn notice(message: String) -> Nil

@external(erlang, "pooka_publish_ffi", "request")
pub fn post(
  url: String,
  key: String,
  otp: String,
  body: BitArray,
) -> Result(publish.UploadState, Failure)

@external(erlang, "pooka_publish_ffi", "otp")
pub fn otp() -> String
