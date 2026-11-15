//// The publishing conversation borrows neither a real key nor a real account.
////
//// Fake transports make rejection and partial success ordinary values. Check
//// that a new key follows the remaining parcel, and that nobody asks a pipe
//// for a password or prints a secret returned by the registry.

import birdie
import builder/publish
import cli/command
import cli/commands/publish as publish_command
import cli/publish_session as session
import gleam/list
import gleam/string
import support

fn quiet() -> session.Interaction {
  session.Interaction(fn() { panic }, fn(_) { panic }, fn(_) { panic }, fn(_) {
    Nil
  })
}

@external(erlang, "pooka_publish_ffi", "api_key_from")
fn select_key(primary: String, fallback: String) -> String

@external(erlang, "pooka_publish_ffi", "detailed_response")
fn response(
  status: Int,
  headers: List(#(String, String)),
  body: String,
) -> Result(publish.UploadState, session.Failure)

pub fn first_nonempty_environment_key_wins_test() {
  assert select_key(" primary ", "fallback") == "primary"
  assert select_key("", "fallback") == "fallback"
  assert select_key(" \n", " fallback ") == "fallback"
  assert select_key("", "") == ""
}

pub fn configured_credentials_need_no_prompt_test() {
  let assert Ok(state) = session.start("key-one", "123456", False, quiet())
  let assert Ok(_) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, key, otp, _) {
        assert key == "key-one"
        assert otp == "123456"
        Ok(publish.Published)
      },
      quiet(),
    )
  assert session.start("", "", False, quiet()) == Error(session.missing_key)
}

pub fn missing_interactive_key_is_read_without_environment_changes_test() {
  let io =
    session.Interaction(..quiet(), secret: fn(prompt) {
      assert string.contains(prompt, "hidden")
      Ok("entered-key")
    })
  let assert Ok(state) = session.start("", "", True, io)
  let assert Ok(_) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, key, _, _) {
        assert key == "entered-key"
        Ok(publish.Published)
      },
      quiet(),
    )
}

pub fn empty_input_eof_and_hidden_input_failure_cancel_test() {
  list.each(
    [
      Ok(""),
      Ok("  "),
      Error("Publication cancelled."),
      Error("Hidden input unavailable."),
    ],
    fn(input) {
      let io = session.Interaction(..quiet(), secret: fn(_) { input })
      let assert Error(_) = session.start("", "", True, io)
    },
  )
}

pub fn rejected_key_is_replaced_once_and_carried_forward_test() {
  let io =
    session.Interaction(..quiet(), confirm: fn(_) { True }, secret: fn(_) {
      Ok("new-key")
    })
  let assert Ok(state) = session.start("old-key", "", True, quiet())
  let transport = fn(_, key, _, _) {
    case key {
      "old-key" -> Error(session.HttpFailure(401, "API key revoked", False))
      "new-key" -> Ok(publish.Published)
      _ -> panic
    }
  }
  let assert Ok(#(_, next)) =
    session.send("package", state, <<>>, transport, io)
  let assert Ok(_) = session.send("docs", next, <<>>, transport, quiet())
  let assert Error(detail) =
    session.send(
      "docs",
      next,
      <<>>,
      fn(_, _, _, _) {
        Error(session.HttpFailure(401, "new-key rejected", False))
      },
      quiet(),
    )
  assert !string.contains(detail, "new-key")
  assert string.contains(detail, "[redacted]")
}

pub fn declining_a_new_key_never_reads_another_secret_test() {
  let assert Ok(state) = session.start("revoked", "", True, quiet())
  let io = session.Interaction(..quiet(), confirm: fn(_) { False })
  let assert Error(detail) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, _, _, _) { Error(session.HttpFailure(401, "revoked key", False)) },
      io,
    )
  assert string.contains(detail, "cancelled")
}

pub fn noninteractive_authentication_failure_never_prompts_test() {
  let assert Ok(state) = session.start("key", "", False, quiet())
  let assert Error(_) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, _, _, _) { Error(session.HttpFailure(401, "unauthorized", False)) },
      quiet(),
    )
}

pub fn verification_requires_an_explicit_challenge_and_has_a_budget_test() {
  let assert Error(session.HttpFailure(403, permission, False)) =
    response(403, [], "{\"message\":\"permission denied\"}")
  assert !string.contains(permission, "HEX_OTP")
  let assert Error(session.HttpFailure(403, _, True)) =
    response(403, [], "{\"message\":\"two factor required\"}")
  let assert Error(session.HttpFailure(401, _, True)) =
    response(401, [#("x-hex-otp", "required")], "{}")
  list.each(["totp_required", "invalid_totp"], fn(code) {
    let assert Error(session.HttpFailure(401, detail, True)) =
      response(
        401,
        [
          #(
            "WWW-Authenticate",
            "Bearer realm=\"hex\", error=\"" <> code <> "\"",
          ),
        ],
        "{}",
      )
    assert string.contains(detail, "HEX_OTP")
    assert !string.contains(detail, "Check HEX_API_KEY")
  })
  let assert Error(session.HttpFailure(429, _, False)) =
    response(
      429,
      [],
      "{\"message\":\"Too many failed two-factor authentication attempts. Please try again later.\"}",
    )
  let io = session.Interaction(..quiet(), secret: fn(_) { Ok("654321") })
  let assert Ok(state) = session.start("key", "", True, quiet())
  let transport = fn(_, _, otp, _) {
    case otp {
      "" -> Error(session.HttpFailure(403, "Verification required", True))
      "654321" -> Ok(publish.Published)
      _ -> panic
    }
  }
  let assert Ok(#(_, next)) = session.send("url", state, <<>>, transport, io)
  let assert Error(detail) =
    session.send(
      "url",
      next,
      <<>>,
      fn(_, _, _, _) { Error(session.HttpFailure(403, "654321 expired", True)) },
      quiet(),
    )
  assert !string.contains(detail, "654321")
  assert string.contains(detail, "HEX_OTP")
}

pub fn permission_and_transport_failures_do_not_retry_test() {
  let assert Ok(state) = session.start("private-key", "", True, quiet())
  let assert Error(permission) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, _, _, _) {
        Error(session.HttpFailure(403, "private-key cannot publish", False))
      },
      quiet(),
    )
  assert string.contains(permission, "permissions")
  assert !string.contains(permission, "private-key")
  let assert Error(timeout) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, _, _, _) {
        Error(session.TransportFailure("timeout for private-key"))
      },
      quiet(),
    )
  assert string.contains(timeout, "uncertain")
  assert !string.contains(timeout, "private-key")
}

pub fn existing_version_guidance_never_changes_upload_mode_test() {
  let assert Ok(state) = session.start("key", "", True, quiet())
  let assert Error(detail) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, _, _, _) {
        Error(session.HttpFailure(422, "version already exists", False))
      },
      quiet(),
    )
  assert string.contains(detail, "--docs-only")
  assert string.contains(detail, "--replace")
}

fn archives(directory: String) -> publish.Report {
  support.write(directory <> "/package.tar", "package")
  support.write(directory <> "/docs.tar.gz", "docs")
  publish.Report(
    "app",
    "1.0.0",
    directory <> "/package.tar",
    directory <> "/docs.tar.gz",
    [],
    [],
  )
}

pub fn docs_authentication_retry_does_not_resend_the_accepted_package_test() {
  use directory <- support.with_directory("publish_session_docs_retry")
  let report = archives(directory)
  let io =
    session.Interaction(..quiet(), confirm: fn(_) { True }, secret: fn(_) {
      Ok("new-key")
    })
  let assert Ok(state) = session.start("old-key", "", True, quiet())
  let transport = fn(url, key, _, _) {
    case string.ends_with(url, "/docs"), key {
      False, "old-key" ->
        Ok(publish.Staged("https://hex.pm/dashboard/staged-releases/one"))
      True, "old-key" -> Error(session.HttpFailure(401, "revoked", False))
      True, "new-key" ->
        Ok(publish.Staged("https://hex.pm/dashboard/staged-releases/one"))
      _, _ -> panic
    }
  }
  assert publish.upload_with_session(
      report,
      state,
      False,
      False,
      fn(url, state, body) { session.send(url, state, body, transport, io) },
    )
    == Ok(["https://hex.pm/dashboard/staged-releases/one"])
}

pub fn package_key_replacement_reaches_documentation_test() {
  use directory <- support.with_directory("publish_session_carry_key")
  let report = archives(directory)
  let io =
    session.Interaction(..quiet(), confirm: fn(_) { True }, secret: fn(_) {
      Ok("new-key")
    })
  let assert Ok(state) = session.start("old-key", "", True, quiet())
  assert publish.upload_with_session(
      report,
      state,
      False,
      False,
      fn(url, state, body) {
        session.send(
          url,
          state,
          body,
          fn(url, key, _, _) {
            case key {
              "new-key" -> Ok(publish.Published)
              _ -> {
                assert !string.ends_with(url, "/docs")
                Error(session.HttpFailure(401, "revoked", False))
              }
            }
          },
          io,
        )
      },
    )
    == Ok([])
}

fn package(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ndescription = \"Small tool\"\nlicences = [\"Apache-2.0\"]\n",
  )
  support.write(
    directory <> "/README.md",
    "# Small tool\nA useful little package.\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nanswer() { 42 }\n",
  )
}

pub fn automatic_and_redirected_commands_never_request_credentials_test() {
  use directory <- support.with_directory("publish_session_automation")
  package(directory)
  let env = command.Environment(..command.plain(directory), inherit_stdio: True)
  let dry =
    publish_command.run_with_interaction(
      ["--dry-run"],
      env,
      fn(_) { panic },
      fn() { panic },
      fn() { panic },
      fn(_, _, _, _) { panic },
      quiet(),
    )
  assert dry.status == 0
  assert string.contains(dry.stdout, "Files:")
  let automatic =
    publish_command.run_with_interaction(
      ["--yes"],
      env,
      fn(_) { panic },
      fn() { "" },
      fn() { "" },
      fn(_, _, _, _) { panic },
      quiet(),
    )
  assert automatic.status == 1
  assert string.contains(automatic.stderr, "HEX_API_KEY")
  let redirected =
    publish_command.run_with_interaction(
      [],
      env,
      fn(_) { panic },
      fn() { panic },
      fn() { panic },
      fn(_, _, _, _) { panic },
      session.Interaction(..quiet(), terminal: fn() { False }),
    )
  assert string.contains(redirected.stdout, "--yes")
}

pub fn interactive_command_uploads_with_a_hidden_invocation_key_test() {
  use directory <- support.with_directory("publish_session_interactive")
  package(directory)
  let io =
    session.Interaction(..quiet(), terminal: fn() { True }, secret: fn(_) {
      Ok("entered-key")
    })
  let output =
    publish_command.run_with_interaction(
      [],
      command.Environment(..command.plain(directory), inherit_stdio: True),
      fn(preview) {
        assert string.contains(preview, "Package: app")
        True
      },
      fn() { "" },
      fn() { "" },
      fn(_, key, _, _) {
        assert key == "entered-key"
        Ok(publish.Published)
      },
      io,
    )
  assert output.status == 0
  assert !string.contains(output.stdout, "Files:")
  assert !string.contains(output.stdout <> output.stderr, "entered-key")
}

pub fn verification_challenges_take_precedence_over_http_401_test() {
  let assert Ok(state) = session.start("key", "", True, quiet())
  let io =
    session.Interaction(..quiet(), secret: fn(prompt) {
      assert string.contains(prompt, "Verification code")
      Ok("123456")
    })
  let assert Ok(_) =
    session.send(
      "url",
      state,
      <<>>,
      fn(_, key, otp, _) {
        assert key == "key"
        case otp {
          "" -> Error(session.HttpFailure(401, "Verification required", True))
          "123456" -> Ok(publish.Published)
          _ -> panic
        }
      },
      io,
    )
}

pub fn rejected_noninteractive_key_has_actionable_redacted_diagnostics_snapshot_test() {
  use directory <- support.with_directory("publish_session_failure_snapshot")
  package(directory)
  let output =
    publish_command.run_with_interaction(
      ["--yes"],
      command.plain(directory),
      fn(_) { panic },
      fn() { "fake-secret" },
      fn() { "" },
      fn(_, _, _, _) {
        Error(session.HttpFailure(
          401,
          "Hex rejected fake-secret: API key revoked.",
          False,
        ))
      },
      quiet(),
    )
  assert output.status == 1
  assert !string.contains(output.stderr, "fake-secret")
  birdie.snap(output.stderr, "publishing rejected key guidance")
}
