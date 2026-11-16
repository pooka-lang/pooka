//// Keep the compiler's workshop out of someone else's crash report.
//// Exercise the actual VM logger and supervisor, plus the BEAM metadata that
//// an external tool can inspect without going through Pooka's CLI formatter.

import birdie
import builder/escript
import cli/command
import compiler/codegen/beam
import gleam/list
import gleam/string
import simplifile
import support

@external(erlang, "runtime_crash_test_ffi", "source")
fn probe_source() -> String

@external(erlang, "runtime_crash_test_ffi", "runtime_details")
fn runtime_details(binary: BitArray) -> #(List(String), List(String))

@external(erlang, "runtime_crash_test_ffi", "preserves_foreign_frames")
fn preserves_foreign_frames() -> Bool

@external(erlang, "shipment_test_ffi", "run_escript")
fn execute(
  path: String,
  arguments: List(String),
  directory: String,
) -> #(Int, String)

pub fn generated_runtime_source_metadata_is_portable_test() {
  let assert Ok(binary) = beam.runtime_binary_for("portable")
  let #(files, keys) = runtime_details(binary)
  assert files == ["pooka_runtime_ffi.erl"]
  assert !list.contains(keys, "source")
  assert !list.contains(keys, "options")
  birdie.snap(
    "Files: "
      <> string.join(files, ", ")
      <> "\nCompile keys: "
      <> string.join(keys, ", "),
    "runtime portable source metadata",
  )
}

pub fn cleaning_a_stack_keeps_all_valid_foreign_frame_shapes_test() {
  assert preserves_foreign_frames()
}

fn project(directory: String, body: String) -> command.Environment {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/ffi/runtime_crash_test_ffi.erl", probe_source())
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Probe from erlang \"runtime_crash_test_ffi\" { observe(pid: Pid, crash: fn() -> Nil) -> String\nsupervised(pid: Pid, crash: fn() -> Nil) -> String\ninitial(start: fn() -> Nil) -> String\nfail() -> Nil\ncurrent() -> Pid }\n"
      <> body,
  )
  command.plain(directory)
}

fn clean(output: String) {
  assert !string.contains(output, "pooka_runtime_ffi.erl")
  assert !string.contains(output, "@@runtime")
  assert !string.contains(output, "_gleam_artefacts")
}

const kettle =
  "actor Kettle {\npid() -> Pid { Probe.current() }\nbe crack() { panic as \"the kettle cracked\" }\n}\n"

pub fn actor_and_supervisor_reports_keep_the_panic_but_not_runtime_frames_test() {
  list.each(["observe", "supervised"], fn(mode) {
    use directory <- support.with_directory("actor_crash_" <> mode)
    let env =
      project(
        directory,
        kettle
          <> "main() {\nlet kettle = Kettle()\necho Probe."
          <> mode
          <> "(kettle.pid(), fn() { kettle.crack() })\n}\n",
      )
    let report = support.cli_main(["run"], env)
    assert report.status == 0
    let text = report.stdout <> report.stderr
    assert string.contains(text, "pooka_panic")
    assert string.contains(text, "the kettle cracked")
    assert string.contains(text, "src/main.pooka")
    clean(text)
    case mode {
      "supervised" -> {
        assert string.contains(text, "child_terminated")
      }
      _ -> Nil
    }
  })
}

pub fn actor_foreign_failure_keeps_its_native_source_frame_test() {
  use directory <- support.with_directory("actor_native_crash")
  let env =
    project(
      directory,
      "actor Kettle {\npid() -> Pid { Probe.current() }\nbe crack() { Probe.fail() }\n}\nmain() { let kettle = Kettle()\necho Probe.observe(kettle.pid(), fn() { kettle.crack() }) }\n",
    )
  let report = support.cli_main(["run"], env)
  assert report.status == 0
  let text = report.stdout <> report.stderr
  assert string.contains(text, "foreign_failure")
  assert string.contains(text, "runtime_crash_test_ffi.erl")
  clean(text)
}

pub fn actor_initializer_failure_also_has_a_clean_exit_stack_test() {
  use directory <- support.with_directory("actor_init_crash")
  let env =
    project(
      directory,
      "actor Kettle { new() { panic as \"no kettle today\" } }\nmain() { echo Probe.initial(fn() { let _ = Kettle()\nNil }) }\n",
    )
  let report = support.cli_main(["run"], env)
  assert report.status == 0
  let text = report.stdout <> report.stderr
  assert string.contains(text, "pooka_actor_initialization_failed")
  assert string.contains(text, "no kettle today")
  clean(text)
}

pub fn relocated_escript_actor_reports_do_not_borrow_compiler_paths_test() {
  use directory <- support.with_directory("actor_crash_escript")
  let app = directory <> "/original"
  let _ =
    project(
      app,
      kettle
        <> "main() { let kettle = Kettle()\necho Probe.supervised(kettle.pid(), fn() { kettle.crack() }) }\n",
    )
  let assert Ok(exported) = escript.export(app)
  let moved = directory <> "/moved"
  let assert Ok(Nil) = simplifile.copy_file(exported.path, moved)
  let assert Ok(Nil) = simplifile.delete(app)
  let result = execute(moved, [], directory)
  assert result.0 == 0
  assert string.contains(result.1, "the kettle cracked")
  assert string.contains(result.1, "child_terminated")
  clean(result.1)
}
