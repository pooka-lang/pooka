//// A tail call may leave the room; its source address should stay on the note.

import birdie
import cli/command
import gleam/list
import gleam/string
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
