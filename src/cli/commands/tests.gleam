//// Give each test its turn under the lamp.
////
//// Discover and run test declarations, grouping results by module and keeping
//// assertion details beside failures. Skips are checked as source without
//// executing their test bodies.
////
//// ```sh
//// pooka test --verbose
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import builder/check
import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/build as build_command
import cli/commands/new
import compiler/codegen/beam
import diagnostics/diagnostic
import diagnostics/render
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/project_error
import tools/logger
import utilities/colour
import utilities/text
import utilities/timer

pub const info =
  Info(
    name: "test",
    arguments: "[--verbose|--compact]",
    summary: "Compile and execute the project's tests",
  )

type Detail {
  Summary
  Verbose
  Compact
}

type TestResult {
  TestResult(test_case: build.Test, outcome: Run, duration: Int)
}

type Run {
  Passed(output: String)
  Failed(failure: beam.TestFailure)
  Skipped
}

/// Check tests, execute selected bodies and render grouped results. Successful
/// checks and totals are green; skipped tests retain their own count.
///
/// ```sh
/// pooka test --verbose
/// ```
pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments {
    [] -> run_tests(Summary, environment)
    ["--verbose"] -> run_tests(Verbose, environment)
    ["--compact"] -> run_tests(Compact, environment)
    _ ->
      new.failure(
        project_error.UnexpectedArguments("test", arguments),
        environment,
      )
  }
}

fn run_tests(detail: Detail, environment: Environment) -> Outcome {
  let started = environment.clock()

  let vm = beam.start_test_vm(environment.stdout == colour.Ansi)
  case build.build_tests(environment.working_directory) {
    Error(error) -> {
      beam.stop_test_vm(vm)
      build_command.failure(error, environment)
    }
    Ok(report) -> {
      let compiled = case detail {
        Verbose -> build_command.compiled(report, started, environment)
        Summary | Compact ->
          render.render_all(
            report.diagnostics,
            check.sources(report.checked),
            environment.stderr,
            diagnostic.Quiet,
          )
      }

      let runs =
        report.tests
        |> list.filter(fn(test_case) { !test_case.skipped })
        |> list.map(fn(test_case) { #(test_case.module, test_case.function) })
        |> beam.execute_tests(vm, report.directory, _)
      let #(_, results) =
        list.map_fold(report.tests, runs, fn(runs, test_case) {
          case test_case.skipped, runs {
            False, [run, ..rest] -> #(
              rest,
              TestResult(
                test_case,
                case run.outcome {
                  Ok(output) -> Passed(output)
                  Error(failure) -> Failed(failure)
                },
                run.duration,
              ),
            )
            _, _ -> #(runs, TestResult(test_case, Skipped, 0))
          }
        })
      let failed =
        list.count(results, fn(result) {
          case result.outcome {
            Failed(_) -> True
            _ -> False
          }
        })
      Outcome(
        stdout: "  "
          <> colour.paint(
          "Running",
          colour.bold_lantern_orange,
          environment.stdout,
        )
          <> " tests...\n\n"
          <> groups(
          case detail {
            Compact ->
              list.filter(results, fn(r) {
                case r.outcome {
                  Failed(_) -> True
                  _ -> False
                }
              })
            _ -> results
          },
          report,
          detail,
          environment,
        )
          <> totals(results, environment.clock() - started, environment),
        stderr: compiled,
        status: case failed {
          0 -> 0
          _ -> 1
        },
      )
    }
  }
}

fn passed(result: TestResult) -> Bool {
  case result.outcome {
    Passed(_) -> True
    Failed(_) | Skipped -> False
  }
}

fn groups(
  results: List(TestResult),
  report: build.Report,
  detail: Detail,
  environment: Environment,
) -> String {
  let paths =
    results
    |> list.map(fn(result) { result.test_case.path })
    |> list.unique
    |> list.sort(string.compare)
  paths
  |> list.map(fn(path) {
    let name = module_name(path, report)
    let label =
      colour.paint(name, colour.bold_lantern_orange, environment.stdout)
      <> case
        list.count(paths, fn(other) { module_name(other, report) == name }) > 1
      {
        True -> logger.muted(" (" <> path <> ")", environment.stdout)
        False -> ""
      }
    let lines =
      results
      |> list.filter(fn(result) { result.test_case.path == path })
      |> list.sort(fn(a, b) {
        int.compare(
          a.test_case.span.start.byte_offset,
          b.test_case.span.start.byte_offset,
        )
      })
      |> list.map(test_line(_, detail, environment))
      |> string.concat
    "  "
    <> colour.paint("•", colour.bold_lantern_orange, environment.stdout)
    <> " test module: "
    <> label
    <> "\n\n"
    <> lines
  })
  |> string.join("\n")
}

fn module_name(path: String, report: build.Report) -> String {
  let segments = case string.split(path, "/") {
    ["src", ..rest] | ["test", ..rest] -> rest
    segments -> segments
  }
  let parents = case list.reverse(segments) {
    [_, ..rest] -> list.reverse(rest)
    [] -> []
  }
  let name = case
    list.find(report.checked.files, fn(file) { file.path == path })
  {
    Ok(file) ->
      case file.parsed.module.header {
        Some(header) -> header.name.name
        None -> path
      }
    Error(_) -> path
  }
  string.join(list.append(parents, [name]), "/")
}

fn test_line(
  result: TestResult,
  detail: Detail,
  environment: Environment,
) -> String {
  let mark = case result.outcome {
    Passed(_) ->
      colour.paint("✓", colour.bold_success_green, environment.stdout)
    Failed(_) -> colour.paint("✗", colour.bold_scarf, environment.stdout)
    Skipped -> colour.paint("-", colour.bold_lantern_orange, environment.stdout)
  }
  let timing = case detail {
    Verbose ->
      " "
      <> logger.muted(
        "(" <> timer.format(result.duration) <> ")",
        environment.stdout,
      )
    Summary | Compact -> ""
  }
  let printed = case detail, result.outcome {
    Verbose, Passed(output) if output != "" -> indent(output, "      ")
    _, Failed(failure) ->
      failure_details(failure, result.test_case, detail, environment)
    _, _ -> ""
  }
  "  "
  <> mark
  <> " "
  <> case result.outcome {
    Skipped ->
      logger.muted(
        result.test_case.description <> " (skipped)",
        environment.stdout,
      )
    _ -> result.test_case.description
  }
  <> timing
  <> "\n"
  <> printed
}

fn failure_details(
  failure: beam.TestFailure,
  test_case: build.Test,
  detail: Detail,
  environment: Environment,
) -> String {
  let reason = case failure.reason, failure.details {
    "assertion failed: assertion failed", [_, ..] -> ""
    "assertion failed: assertion failed", [] -> "      assertion failed\n"
    reason, _ ->
      indent(
        colour.paint(reason, colour.bold_amber_glow, environment.stdout),
        "      ",
      )
  }
  let values =
    failure.details
    |> list.filter(fn(pair) { pair.0 != "location" })
    |> list.map(fn(pair) {
      "      "
      <> logger.muted(
        case pair.0 {
          "expected" -> "expected"
          _ -> "got"
        },
        environment.stdout,
      )
      <> " "
      <> colour.paint(
        string.replace(pair.1, "\n", "\n        "),
        case pair.0 {
          "expected" -> colour.magic_violet
          _ -> colour.diagnostic_error
        },
        environment.stdout,
      )
      <> "\n"
    })
    |> string.concat
  let source =
    failure.details
    |> list.find(fn(pair) { pair.0 == "location" })
  let source = case source {
    Ok(pair) -> pair.1
    Error(_) ->
      test_case.path <> ":" <> int.to_string(test_case.span.start.line)
  }
  let printed = case failure.output {
    "" -> ""
    output -> "      output:\n" <> indent(output, "        ")
  }
  let trace = case detail, failure.stacktrace {
    Verbose, trace if trace != "" ->
      "      Stack trace:\n" <> indent(trace, "        ")
    _, _ -> ""
  }
  reason
  <> values
  <> "      "
  <> logger.muted(source, environment.stdout)
  <> "\n"
  <> printed
  <> trace
  <> "\n"
}

fn totals(
  results: List(TestResult),
  duration: Int,
  environment: Environment,
) -> String {
  let passed = list.count(results, passed)
  let failed =
    list.count(results, fn(result) {
      case result.outcome {
        Failed(_) -> True
        _ -> False
      }
    })
  let skipped = list.count(results, fn(result) { result.outcome == Skipped })

  case results {
    [] -> ""
    _ -> "\n"
  }
  <> "  "
  <> text.counted(list.length(results), "test")
  <> ", "
  <> colour.paint(
    int.to_string(passed) <> " passed",
    colour.bold_success_green,
    environment.stdout,
  )
  <> case failed {
    0 -> ""
    _ ->
      ", "
      <> colour.paint(
        int.to_string(failed) <> " failed",
        colour.bold_scarf,
        environment.stdout,
      )
  }
  <> case skipped {
    0 -> ""
    _ ->
      ", "
      <> colour.paint(
        int.to_string(skipped) <> " skipped",
        colour.bold_lantern_orange,
        environment.stdout,
      )
  }
  <> "\n\n  "
  <> colour.paint("Finished", colour.bold_lantern_orange, environment.stdout)
  <> " in "
  <> logger.muted(timer.format(duration), environment.stdout)
  <> "\n"
}

fn indent(text: String, prefix: String) -> String {
  text
  |> string.trim_end
  |> string.split("\n")
  |> list.map(fn(line) { prefix <> line <> "\n" })
  |> string.concat
}
