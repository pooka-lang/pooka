//// Every test gets its own place in the report.
////
//// Check grouped and compact output, colours, failure operands, captured
//// output and skipped tests. A skipped body is still type-checked. Compile
//// failures and a VM that halts early must not produce a misleading successful
//// summary for unfinished work.

import birdie
import cli/command
import gleam/string
import simplifile
import support
import utilities/colour

fn project(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\nmain() { Nil }\n")
}

fn grouped_tests(directory: String) {
  project(directory)

  support.write(
    directory <> "/test/classes2.spec.pooka",
    "module classes_test2\ntest \"generic methods change the stored type 2\" { assert True }\ntest \"class patterns cover every Boolean field 2\" { assert True }\ntest \"imported hierarchies narrow subjects and dispatch methods 2\" { assert True }\n",
  )
  support.write(
    directory <> "/test/classes.spec.pooka",
    "module classes_test\ntest \"generic methods change the stored type\" { assert True }\ntest \"class patterns cover every Boolean field\" { assert True }\ntest \"imported hierarchies narrow subjects and dispatch methods\" { assert True }\n",
  )
}

pub fn default_grouped_output_matches_the_requested_layout_test() {
  use directory <- support.with_directory("runner_default_groups")
  grouped_tests(directory)
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 0
  assert report.stderr == ""
  assert report.stdout
    == "  Running tests...\n\n  • test module: classes_test\n\n  ✓ generic methods change the stored type\n  ✓ class patterns cover every Boolean field\n  ✓ imported hierarchies narrow subjects and dispatch methods\n\n  • test module: classes_test2\n\n  ✓ generic methods change the stored type 2\n  ✓ class patterns cover every Boolean field 2\n  ✓ imported hierarchies narrow subjects and dispatch methods 2\n\n  6 tests, 6 passed\n\n  Finished in 0µs\n"
  report.stdout |> birdie.snap(title: "test runner grouped default output")
}

pub fn terminal_output_uses_the_pooka_palette_test() {
  use directory <- support.with_directory("runner_colour_groups")
  grouped_tests(directory)
  let env = command.plain(directory)
  let report =
    support.cli_main(["test"], command.Environment(..env, stdout: colour.Ansi))
  assert report.status == 0
  assert report.stderr == ""
  assert string.contains(
    report.stdout,
    colour.bold_lantern_orange <> "classes_test",
  )
  assert string.contains(report.stdout, colour.bold_success_green <> "✓")
  assert string.contains(report.stdout, colour.muted <> "0µs")
  report.stdout
  |> support.show_escapes
  |> birdie.snap(title: "test runner grouped terminal output")
}

pub fn verbose_mode_shows_timings_printed_output_and_compilation_test() {
  use directory <- support.with_directory("runner_verbose")
  project(directory)
  support.write(
    directory <> "/test/output.spec.pooka",
    "module output_test\ntest \"prints its progress\" { echo(\"first line\")\necho(\"second line\") }\n",
  )
  let report = support.cli_main(["test", "--verbose"], command.plain(directory))
  assert report.status == 0
  assert string.contains(report.stderr, "Compiling app")
  assert string.contains(report.stdout, "✓ prints its progress (0µs)")
  assert string.contains(
    report.stdout,
    "      test/output.spec.pooka:2\n      \"first line\"\n      test/output.spec.pooka:3\n      \"second line\"\n",
  )
  let snapshot = report.stdout <> "\n--- compilation ---\n" <> report.stderr
  birdie.snap(snapshot, title: "test runner verbose output")
  let quiet = support.cli_main(["test"], command.plain(directory))
  assert quiet.status == 0
  assert quiet.stderr == ""
  assert !string.contains(quiet.stdout, "first line")
  assert !string.contains(quiet.stdout, "(0µs)")
}

pub fn failed_tests_show_inline_details_and_independent_results_test() {
  use directory <- support.with_directory("runner_failure_details")
  project(directory)
  support.write(
    directory <> "/test/failure.spec.pooka",
    "module failure_test\ntest \"fails clearly\" {\n  echo(\"before failure\")\n  assert False as \"expected failure\"\n}\ntest \"passes afterwards\" { assert True }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert report.stderr == ""
  assert string.contains(report.stdout, "✗ fails clearly")
  assert string.contains(report.stdout, "✓ passes afterwards")
  assert !string.contains(report.stdout, "error: test failed")
  assert string.contains(report.stdout, "expected True")
  assert string.contains(report.stdout, "got False")
  assert string.contains(report.stdout, "before failure")
  assert string.contains(report.stdout, "expected failure")
  assert string.contains(report.stdout, "2 tests, 1 passed, 1 failed")
  assert !string.contains(report.stdout, "Stack trace:")
  report.stdout |> birdie.snap(title: "test runner failure output")
  let verbose =
    support.cli_main(["test", "--verbose"], command.plain(directory))
  assert verbose.status == 1
  assert string.contains(verbose.stdout, "Stack trace:")
  let env = command.plain(directory)
  let terminal =
    support.cli_main(["test"], command.Environment(..env, stdout: colour.Ansi))
  assert terminal.status == 1
  assert string.contains(terminal.stdout, colour.bold_scarf <> "✗")
  assert string.contains(terminal.stdout, colour.bold_scarf <> "1 failed")
}

pub fn projects_without_tests_have_a_complete_summary_test() {
  use directory <- support.with_directory("runner_empty")
  project(directory)
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 0
  assert report.stderr == ""
  assert report.stdout
    == "  Running tests...\n\n  0 tests, 0 passed\n\n  Finished in 0µs\n"
}

pub fn nested_modules_and_colliding_labels_remain_distinguishable_test() {
  use directory <- support.with_directory("runner_module_names")
  project(directory)
  support.write(
    directory <> "/test/other.spec.pooka",
    "module main\ntest \"nested spec\" { assert True }\n",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main\ntest \"separate file\" { assert True }\n",
  )
  support.write(
    directory <> "/test/nested/one.spec.pooka",
    "module one_test\ntest \"nested\" { assert True }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 0
  assert report.stderr == ""
  assert string.contains(
    report.stdout,
    "test module: main (test/other.spec.pooka)",
  )
  assert string.contains(
    report.stdout,
    "test module: main (test/main.spec.pooka)",
  )
  assert string.contains(report.stdout, "test module: nested/one_test")
  assert string.contains(report.stdout, "3 tests, 3 passed")
}

pub fn default_mode_preserves_build_warnings_without_activity_logs_test() {
  use directory <- support.with_directory("runner_build_warnings")
  project(directory)
  support.write(
    directory <> "/test/warnings.spec.pooka",
    "module warnings_test\nimport unused\ntest \"passes\" { assert True }\n",
  )
  support.write(directory <> "/src/unused.pooka", "module unused\n")
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 0
  assert string.contains(report.stderr, "warning: unused import")
  assert !string.contains(report.stderr, "Compiling")
  assert string.contains(report.stdout, "1 test, 1 passed")
}

pub fn build_errors_do_not_print_a_successful_test_summary_test() {
  use directory <- support.with_directory("runner_build_errors")
  project(directory)
  support.write(
    directory <> "/test/invalid.spec.pooka",
    "module invalid_test\ntest \"invalid\" { 1 + True }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert report.stdout == ""
  assert string.contains(report.stderr, "error:")
  let arguments =
    support.cli_main(["test", "--unknown"], command.plain(directory))
  assert arguments.status == 1
  assert arguments.stdout == ""
  assert string.contains(arguments.stderr, "--unknown")
}

// Failure reporting needs the operands that were already evaluated. Running
// them again to print expected and got would repeat effects and could report
// different values.
pub fn equality_failures_show_actual_operands_inline_without_repeating_effects_test() {
  use directory <- support.with_directory("runner_expected_found")
  project(directory)
  support.write(
    directory <> "/test/equality.spec.pooka",
    "module equality_test\nactor Counter { var value = 0\nnext() { value += 1\nvalue }\nget() { value } }\ntest \"operands evaluated once\" { let counter = Counter.new()\nassert counter.next() == counter.next() as { echo counter.get()\n\"values differ\" } }\ntest \"continues\" { assert True }",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert string.contains(report.stdout, "expected 2")
  assert string.contains(report.stdout, "got 1")
  assert string.contains(report.stdout, "      2\n")
  assert string.contains(report.stdout, "✓ continues")
  assert !string.contains(report.stdout, "error: test failed")
  assert !string.contains(report.stdout, "╭─")
  report.stdout |> birdie.snap(title: "test runner inline expected and found")
}

pub fn skipped_tests_are_checked_but_not_executed_and_failures_show_values_and_source_test() {
  use directory <- support.with_directory("runner_skip_and_values")
  project(directory)
  support.write(
    directory <> "/test/config.spec.pooka",
    "module config_test\n\ntest \"parses valid configuration\" { assert True }\ntest skip \"supports remote configuration\" { panic(\"must not execute\") }\ntest \"rejects an invalid port\" {\n  assert Ok(70000) == Error(\"invalid port\")\n}\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert string.contains(
    report.stdout,
    "- supports remote configuration (skipped)",
  )
  assert string.contains(
    report.stdout,
    "      expected Error(\"invalid port\")\n      got Ok(70000)\n      test/config.spec.pooka:6\n",
  )
  assert string.contains(
    report.stdout,
    "3 tests, 1 passed, 1 failed, 1 skipped",
  )
  assert !string.contains(report.stdout, "must not execute")
  birdie.snap(report.stdout, "test runner skipped and detailed failures")
  let coloured =
    support.cli_main(
      ["test"],
      command.Environment(..command.plain(directory), stdout: colour.Ansi),
    )
  assert string.contains(coloured.stdout, colour.bold_lantern_orange <> "-")
  assert string.contains(coloured.stdout, colour.magic_violet <> "Error")
  let assert Ok(source) =
    simplifile.read(directory <> "/test/config.spec.pooka")
  support.write(
    directory <> "/test/config.spec.pooka",
    string.replace(source, "Ok(70000)", "Error(\"invalid port\")"),
  )
  let passed = support.cli_main(["test"], command.plain(directory))
  assert passed.status == 0
  assert string.contains(passed.stdout, "3 tests, 2 passed, 1 skipped")
}

// Skipping controls execution, not validity. A broken type in a skipped test
// must still fail the compilation step.
pub fn skipped_test_type_errors_remain_compiler_errors_test() {
  use directory <- support.with_directory("runner_skip_invalid")
  project(directory)
  support.write(
    directory <> "/test/invalid.spec.pooka",
    "module invalid_test\ntest skip \"not runnable yet\" { missing() }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert !string.contains(report.stdout, "(skipped)")
  assert string.contains(report.stderr, "missing")
}

pub fn output_is_captured_per_test_test() {
  use directory <- support.with_directory("runner_capture")
  project(directory)
  support.write(
    directory <> "/test/capture.spec.pooka",
    "module capture_test\nexternal Io from erlang \"io\" {\n  put_chars(text: String) -> Nil\n}\ntest \"prints and fails\" {\n  Io.put_chars(\"from the first test\\n\")\n  assert False\n}\ntest \"prints and passes\" {\n  Io.put_chars(\"from the second test\\n\")\n}\n",
  )
  let report = support.cli_main(["test", "--verbose"], command.plain(directory))
  assert report.status == 1
  let assert Ok(#(first, second)) =
    string.split_once(report.stdout, "✓ prints and passes")
  assert string.contains(first, "from the first test")
  assert !string.contains(first, "from the second test")
  assert string.contains(second, "from the second test")
}

// A disappearing VM cannot award passing results to work it never finished.
// Preserve completed results and mark the unfinished tests as failed.
pub fn a_vm_that_halts_fails_its_unfinished_tests_test() {
  use directory <- support.with_directory("runner_halt")
  project(directory)
  support.write(
    directory <> "/test/halt.spec.pooka",
    "module halt_test\nexternal Erl from erlang \"erlang\" {\n  halt(status: Int) -> Nil\n}\ntest \"halts\" { Erl.halt(3) }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert string.contains(report.stdout, "✗ halts")
  assert string.contains(
    report.stdout,
    "the test VM stopped before the test finished",
  )
}

pub fn failures_point_at_the_failing_line_test() {
  use directory <- support.with_directory("runner_failing_line")
  project(directory)
  support.write(
    directory <> "/src/check.pooka",
    "module check\nis_even(n: Int) -> Nil {\n  match n % 2 == 0 {\n    True -> Nil\n    False -> panic as \"odd\"\n  }\n}\n",
  )
  support.write(
    directory <> "/test/line.spec.pooka",
    "module line_test\nimport check\ntest \"fails on line four\" {\n  check.is_even(3)\n}\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert string.contains(report.stdout, "panic: odd")
  assert string.contains(report.stdout, "test/line.spec.pooka:4")
}

pub fn compact_mode_shows_failures_and_totals_without_passing_rows_test() {
  use directory <- support.with_directory("runner_compact")
  project(directory)
  support.write(
    directory <> "/test/compact.spec.pooka",
    "module compact_test\ntest \"passing row\" { assert True }\ntest skip \"skipped row\" { panic as \"do not run\" }\ntest \"failure row\" { assert 1 == 2 }\n",
  )
  let report = support.cli_main(["test", "--compact"], command.plain(directory))
  assert report.status == 1
  assert !string.contains(report.stdout, "passing row")
  assert !string.contains(report.stdout, "skipped row")
  assert string.contains(report.stdout, "✗ failure row")
  assert string.contains(
    report.stdout,
    "3 tests, 1 passed, 1 failed, 1 skipped",
  )
}
