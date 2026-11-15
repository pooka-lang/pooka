//// Read the envelope, return it, or say plainly that it can be left unopened.

import birdie
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import diagnostics/diagnostic
import gleam/dict
import gleam/list
import gleam/string
import support

fn warnings(body: String) -> List(diagnostic.Diagnostic) {
  let assert Ok(report) =
    module_infer.infer(
      support.parse(
        "module main\nread() -> Result(Nil, String) { Error(\"unread\") }\n"
        <> body,
      ),
      dict.new(),
      unify.new(),
      support.path,
    )
  list.filter(report.diagnostics, fn(value) {
    value.id == "type.discarded_result"
  })
}

pub fn ignored_results_warn_but_explicit_discard_and_tail_returns_do_not_test() {
  assert list.length(warnings("main() { read()\nNil }")) == 1
  assert warnings("main() { let _ = read()\nNil }") == []
  assert warnings("main() { read() }") == []
  assert warnings("main() { let result = read()\nresult }") == []
  assert warnings("main() { match read() { Ok(_) -> Nil\nError(_) -> Nil } }")
    == []
}

pub fn nested_closures_methods_and_blocks_use_their_own_tail_positions_test() {
  assert list.length(warnings(
      "class Reader { run() { read()\nNil } }\nmain() { let f = fn() { read()\nNil }\nf() }",
    ))
    == 2
  assert list.length(warnings("main() { { read() }\nNil }")) == 1
  assert warnings("main() { fn() { read() } }") == []
}

pub fn generic_identity_calls_are_inspected_after_constraints_settle_test() {
  let found =
    warnings(
      "identity(value: a) -> a { value }\nmain() { identity(read())\nNil }",
    )
  let assert [warning] = found
  assert warning.severity == diagnostic.WarningSeverity
  let assert [label] = warning.labels
  assert label.location.span.start.line == 4
}

pub fn warnings_do_not_fail_execution_or_disappear_on_a_cached_check_test() {
  use directory <- support.with_directory("discarded_result_cli")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nread() -> Result(Nil, String) { Error(\"unread\") }\nmain() { read()\nNil }\n",
  )
  let env = command.plain(directory)
  list.each([["check"], ["check"], ["run"]], fn(arguments) {
    let report = support.cli_main(arguments, env)
    assert report.status == 0
    assert string.contains(report.stderr, "discarded Result")
  })
  let json = support.cli_main(["check", "--json"], env)
  assert json.status == 0
  assert string.contains(json.stdout, "type.discarded_result")
  assert string.contains(json.stdout, "warning")
}

pub fn discarded_result_warning_snapshot_test() {
  use directory <- support.with_directory("discarded_result_snapshot")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nread() -> Result(Nil, String) { Error(\"unread\") }\nmain() { read()\nNil }\n",
  )
  let report = support.cli_main(["check"], command.plain(directory))
  support.diagnostics(report.stderr) |> birdie.snap("discarded Result warning")
}
