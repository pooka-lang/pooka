//// A debug lantern can travel, but its author should know it was packed.

import birdie
import builder/check
import builder/publish
import cli/command
import cli/commands/publish as publish_command
import cli/publish_session
import gleam/list
import gleam/string
import simplifile
import support

fn package(directory: String, source: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\ndescription = \"A small library\"\nlicences = [\"Apache-2.0\"]\n",
  )
  support.write(
    directory <> "/README.md",
    "# Small library\nA little package with a debug print.\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
}

pub fn publication_warns_for_resolved_builtin_calls_and_references_test() {
  use directory <- support.with_directory("publish_echo_uses")
  package(directory, "main() { echo 1\necho(2)\nlet debug = echo\ndebug(3) }\n")
  let assert Ok(report) = publish.prepare(directory)
  let warnings =
    list.filter(report.diagnostics, fn(value) { value.id == "publish.echo" })
  assert list.length(warnings) == 3
  list.each(warnings, fn(warning) {
    let assert [label] = warning.labels
    assert label.location.path == "src/main.pooka"
  })
}

pub fn strings_comments_and_shadowed_echo_bindings_are_quiet_test() {
  use directory <- support.with_directory("publish_echo_shadowing")
  package(
    directory,
    "// echo 1\necho(value: Int) { value }\nmain() { let text = \"echo 1\"\n#(echo(2), text) }\n",
  )
  let assert Ok(report) = publish.prepare(directory)
  assert !list.any(report.diagnostics, fn(value) { value.id == "publish.echo" })
  package(
    directory,
    "apply(echo: fn(Int) -> Int) { echo(1) }\nmain() { let echo = fn(value) { value }\necho(2) }\n",
  )
  let assert Ok(report) = publish.prepare(directory)
  assert !list.any(report.diagnostics, fn(value) { value.id == "publish.echo" })
}

pub fn test_and_dependency_echo_uses_do_not_belong_to_the_published_package_test() {
  use directory <- support.with_directory("publish_echo_ownership")
  package(directory, "import helper/value\nmain() { value.answer() }\n")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nhelper = { path = \"helper\" }\n",
  )
  support.write(
    directory <> "/helper/pooka.toml",
    "name = \"helper\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/helper/src/helper/value.pooka",
    "module value\nanswer() { echo 42 }\n",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\ntest \"echo\" { echo 1 }\n",
  )
  let assert Ok(checked) = check.check_production(directory)
  assert publish.publication_warnings(checked) == []
}

pub fn dry_runs_keep_echo_warnings_when_the_build_is_cached_test() {
  use directory <- support.with_directory("publish_echo_cache")
  package(directory, "main() { echo 42 }\n")
  list.each([1, 2], fn(_) {
    let result =
      support.cli_main(["publish", "--dry-run"], command.plain(directory))
    assert result.status == 0
    assert string.contains(result.stderr, "debug output in published code")
    assert string.contains(result.stderr, "src/main.pooka:2")
    assert string.contains(result.stdout, "Prepared")
  })
}

pub fn warnings_are_shown_before_confirmation_and_automatic_upload_test() {
  use directory <- support.with_directory("publish_echo_order")
  package(directory, "main() { echo 42 }\n")
  let marker = directory <> "/warning-shown"
  let io =
    publish_session.Interaction(
      fn() { True },
      fn(_) { panic },
      fn(_) { panic },
      fn(text) {
        assert string.contains(text, "debug output in published code")
        support.write(marker, "shown")
      },
    )
  let env = command.Environment(..command.plain(directory), inherit_stdio: True)
  let declined =
    publish_command.run_with_interaction(
      [],
      env,
      fn(_) {
        assert simplifile.is_file(marker) == Ok(True)
        False
      },
      fn() { panic },
      fn() { panic },
      fn(_, _, _, _) { panic },
      io,
    )
  assert declined.status == 0
  let assert Ok(Nil) = simplifile.delete_file(marker)
  let sent =
    publish_command.run_with_interaction(
      ["--yes"],
      env,
      fn(_) { panic },
      fn() { "fake-key" },
      fn() { "" },
      fn(_, _, _, _) {
        assert simplifile.is_file(marker) == Ok(True)
        Ok(publish.Published)
      },
      io,
    )
  assert sent.status == 0
}

pub fn publication_echo_warning_snapshot_test() {
  use directory <- support.with_directory("publish_echo_snapshot")
  package(directory, "main() { echo 42 }\n")
  let result =
    support.cli_main(["publish", "--dry-run"], command.plain(directory))
  birdie.snap(result.stderr, "publication echo warning")
}
