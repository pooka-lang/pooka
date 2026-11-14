//// Modules may finish out of order. Their artifacts and errors must not.

import builder/build
import builder/layout
import compiler/codegen/beam
import compiler/codegen/forms as f
import gleam/int
import gleam/list
import simplifile
import support

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> Nil

@external(erlang, "parallel_compile_test_ffi", "crash_preserves_mailbox")
fn crash_preserves_mailbox() -> Bool

@external(erlang, "parallel_compile_test_ffi", "workers_are_bounded")
fn workers_are_bounded() -> Bool

fn forms(name: String, value: Int) -> List(f.Term) {
  [
    f.node("attribute", 1, [f.Atom("module"), f.Atom(name)]),
    f.node("attribute", 1, [
      f.Atom("export"),
      f.Sequence([f.Tuple([f.Atom("answer"), f.Integer(0)])]),
    ]),
    f.node("function", 1, [
      f.Atom("answer"),
      f.Integer(0),
      f.Sequence([f.clause([], [f.node("integer", 1, [f.Integer(value)])], 1)]),
    ]),
  ]
}

pub fn parallel_beams_equal_sequential_compilation_and_keep_input_order_test() {
  let sources =
    list.index_map(list.repeat(Nil, 9), fn(_, n) {
      forms("parallel_fixture_" <> int.to_string(n), n)
    })
  let assert Ok(expected) = list.try_map(sources, beam.compile)
  let jobs = list.map(sources, fn(source) { fn() { beam.compile(source) } })
  assert beam.compile_jobs(jobs) == Ok(expected)
}

pub fn first_source_error_wins_even_if_a_later_error_finishes_first_test() {
  let result =
    beam.compile_jobs([
      fn() {
        sleep(20)
        Error("first source")
      },
      fn() { Error("later source") },
      fn() { Ok(3) },
    ])
  assert result == Error("first source")
}

pub fn empty_and_single_job_keep_their_results_test() {
  assert beam.compile_jobs([]) == Ok([])
  assert beam.compile_jobs([fn() { Ok(42) }]) == Ok([42])
  assert beam.compile_jobs([fn() { Error("failed") }]) == Error("failed")
}

pub fn worker_crashes_keep_the_original_exception_and_leave_no_messages_test() {
  assert crash_preserves_mailbox()
}

pub fn compiler_workers_are_bounded_test() {
  assert workers_are_bounded()
}

fn binaries(report: build.Report) -> List(#(String, BitArray)) {
  list.map(report.modules, fn(name) {
    let assert Ok(binary) =
      simplifile.read_bits(layout.beam(report.layout, name))
    #(name, binary)
  })
}

pub fn parallel_project_builds_are_deterministic_and_preserve_cache_reuse_test() {
  use directory <- support.with_directory("parallel_project_artifacts")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  let _ =
    list.index_map(list.repeat(Nil, 12), fn(_, n) {
      let name = "item_" <> int.to_string(n)
      support.write(
        directory <> "/src/" <> name <> ".pooka",
        "module " <> name <> "\nanswer() { " <> int.to_string(n) <> " }",
      )
    })
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport item_0\nimport item_11\nmain() { echo item_0.answer() + item_11.answer() }",
  )
  let assert Ok(first) = build.build(directory)
  let expected = binaries(first)
  assert support.execute(first.directory, "pooka@app@main", []) == Ok("11\n")
  let assert Ok(warm) = build.build(directory)
  assert warm.reused
  assert binaries(warm) == expected
  let assert Ok(Nil) = simplifile.delete(directory <> "/build")
  let assert Ok(fresh) = build.build(directory)
  assert binaries(fresh) == expected
  assert fresh.modules == first.modules
}
