//// A tail call may leave the room; its source address should stay on the note.

import birdie
import builder/escript
import cli/cli as raw_cli
import cli/command
import gleam/list
import gleam/string
import pooka
import simplifile
import support

fn project(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
}

pub fn tail_position_panics_and_todos_keep_the_written_location_test() {
  list.each(["panic", "todo"], fn(keyword) {
    use directory <- support.with_directory("panic_location_" <> keyword)
    project(directory)
    support.write(
      directory <> "/src/main.pooka",
      "module main\n\nexplode() -> Int {\n  "
        <> keyword
        <> " as \"boom\"\n}\n\nforward() -> Int { explode() }\nmain() { echo forward() + 1 }\n",
    )
    let report = support.cli_main(["run"], command.plain(directory))
    assert report.status == 1
    assert string.contains(report.stderr, "panic: boom (src/main.pooka:4)")
    assert !string.contains(report.stderr, "pooka_runtime_ffi.erl")
    assert !string.contains(report.stderr, "pooka@app@@runtime")
  })
}

pub fn test_failures_report_the_panic_expression_location_test() {
  use directory <- support.with_directory("panic_test_location")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexplode() { panic as \"boom\" }\n",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\nimport main\ntest \"a useful address\" { main.explode() }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert string.contains(report.stdout, "panic: boom (src/main.pooka:2)")
  assert !string.contains(
    report.stdout <> report.stderr,
    "pooka_runtime_ffi.erl",
  )
  assert !string.contains(report.stdout, "pooka@app@@runtime")
  birdie.snap(report.stdout, "test runner panic source location")
}

pub fn foreign_callers_can_read_the_structured_panic_reason_test() {
  use directory <- support.with_directory("panic_foreign_reason")
  project(directory)
  support.write(
    directory <> "/ffi/catch_panic.erl",
    "-module(catch_panic).\n-export([capture/1]).\ncapture(F) -> try F(), false catch error:{pooka_panic, <<\"boom\">>, <<\"src/main.pooka\">>, 4} -> true end.\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Capture from erlang \"catch_panic\" { capture(f: fn() -> Int) -> Bool }\nexplode() -> Int {\n  panic as \"boom\"\n}\nmain() { assert Capture.capture(explode) }\n",
  )
  assert support.cli_main(["run"], command.plain(directory)).status == 0
}

fn dependency_project(directory: String, body: String) -> command.Environment {
  support.write(
    directory <> "/tool/pooka.toml",
    "name = \"tool\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/tool/src/tool.pooka", "module tool\n" <> body)
  support.write(
    directory <> "/tool/src/main.pooka",
    "module main\nimport tool\nmain() { tool.greeting() }\n",
  )
  let app = directory <> "/app"
  support.write(
    app <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\ntool = { path = \"../tool\" }\n",
  )
  support.write(
    app <> "/src/main.pooka",
    "module main\nimport tool\nmain() { tool.greeting() }\n",
  )
  command.plain(app)
}

pub fn dependency_echo_and_first_class_echo_keep_the_package_source_address_test() {
  use directory <- support.with_directory("dependency_echo_location")
  let env =
    dependency_project(
      directory,
      "greeting() {\n  let show = echo\n  show(\"hello\")\n}\n",
    )
  list.each([["run"], ["run", "-m", "tool"]], fn(args) {
    let report = raw_cli.main(args, pooka.version, env)
    assert report.status == 0
    assert string.contains(
      report.stdout <> report.stderr,
      "tool: src/tool.pooka:3",
    )
    assert !string.contains(report.stdout <> report.stderr, "$package")
  })
  support.write(
    directory <> "/tool/src/tool.pooka",
    "module tool\ngreeting() { echo \"hello\" }\n",
  )
  let report = raw_cli.main(["run"], pooka.version, env)
  assert report.status == 0
  let text = support.diagnostics(report.stdout <> report.stderr)
  assert string.contains(text, "tool: src/tool.pooka:2")
  assert !string.contains(text, "$package")
  birdie.snap(text, "dependency echo package source location")
}

pub fn dependency_panic_todo_and_assertions_report_the_original_package_test() {
  list.each(["panic as \"boom\"", "todo as \"boom\"", "assert False"], fn(body) {
    use directory <- support.with_directory("dependency_failure_location")
    let env =
      dependency_project(directory, "greeting() {\n  " <> body <> "\n}\n")
    list.each([["run"], ["run", "-m", "tool"]], fn(args) {
      let report = support.cli_main(args, env)
      assert report.status == 1
      case string.starts_with(body, "assert") {
        True -> Nil
        False -> {
          assert string.contains(report.stderr, "tool: src/tool.pooka")
        }
      }
      assert !string.contains(report.stderr, "$package")
    })
    support.write(
      directory <> "/app/test/app.spec.pooka",
      "module app_test\nimport tool\ntest \"dependency address\" { tool.greeting() }\n",
    )
    let outcome = raw_cli.main(["test"], pooka.version, env)
    assert outcome.status == 1
    assert string.contains(outcome.stdout, "tool: src/tool.pooka:3")
    assert !string.contains(outcome.stdout <> outcome.stderr, "$package")
  })
}

pub fn dependency_panic_terms_and_relocated_escripts_keep_portable_locations_test() {
  use directory <- support.with_directory("dependency_panic_term")
  let env =
    dependency_project(
      directory,
      "greeting() -> Int {\n  panic as \"boom\"\n}\n",
    )
  support.write(
    directory <> "/app/ffi/catch_dependency.erl",
    "-module(catch_dependency).\n-export([capture/1]).\ncapture(F) -> try F(), false catch error:{pooka_panic, <<\"boom\">>, <<\"tool: src/tool.pooka\">>, 3} -> true end.\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nimport tool\nexternal Capture from erlang \"catch_dependency\" { capture(f: fn() -> Int) -> Bool }\nmain() { assert Capture.capture(tool.greeting) }\n",
  )
  assert support.cli_main(["run"], env).status == 0
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nimport tool\nmain() { tool.greeting() }\n",
  )
  let assert Ok(exported) = escript.export(directory <> "/app")
  let moved = directory <> "/moved"
  let assert Ok(Nil) = simplifile.copy_file(exported.path, moved)
  let assert Ok(Nil) = simplifile.delete(directory <> "/app")
  let assert Ok(Nil) = simplifile.delete(directory <> "/tool")
  let result = execute_escript(moved, [], directory)
  assert result.0 == 1
  assert string.contains(result.1, "tool: src/tool.pooka:3")
  assert !string.contains(result.1, "$package")
}

@external(erlang, "shipment_test_ffi", "run_escript")
fn execute_escript(
  path: String,
  arguments: List(String),
  directory: String,
) -> #(Int, String)

pub fn dependency_beam_frames_use_the_package_source_file_test() {
  use directory <- support.with_directory("dependency_stack_location")
  let env = dependency_project(directory, "greeting() { 10 / 0 }\n")
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nimport tool\nmain() { let _ = tool.greeting()\nNil }\n",
  )
  let report = support.cli_main(["run"], env)
  assert report.status == 1
  assert string.contains(report.stderr, "tool: src/tool.pooka")
  assert !string.contains(report.stderr, "$package")
}
