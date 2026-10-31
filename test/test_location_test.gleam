//// A test belongs on a spec page, even when nobody plans to run it.
////
//// Check the .spec.pooka filename rule through checking, formatting and
//// production exports. Validation must happen before production filtering can
//// discard a misplaced test. Legal spec files retain access to ordinary
//// private helpers, including in actual execution.
////
//// ```text
//// src/main.pooka       -> declarations, no test blocks
//// test/main.spec.pooka  -> declarations and test blocks
//// ```

import birdie
import cli/command
import compiler/compiler
import compiler/parser/ast
import diagnostics/diagnostic
import gleam/list
import gleam/string
import support

const source = "module main\ntest \"a small check\" { assert True }\n"

pub fn ordinary_files_reject_tests_in_both_checking_modes_test() {
  list.each(
    [
      "src/main.pooka",
      "test/main.pooka",
      "main.pooka",
      "main.spec.pooka.backup",
    ],
    fn(path) {
      list.each(
        [compiler.check_source, compiler.check_production_source],
        fn(check) {
          let report = check(path, source)
          let assert [error] = report.diagnostics
          assert error.id == "analysis.test_location"
          let assert [label] = error.labels
          assert label.location.path == path
          assert label.location.span.start.line == 2
        },
      )
    },
  )
}

// Production filtering is not an escape hatch from the filename rule. Report
// the misplaced declaration before its body disappears from the production
// module.
pub fn production_rejects_tests_before_removing_their_bodies_test() {
  let report = compiler.check_production_source("src/main.pooka", source)
  assert diagnostic.has_errors(report.diagnostics)
  assert !list.any(report.parsed.module.declarations, fn(declaration) {
    case declaration {
      ast.TestDeclaration(_) -> True
      _ -> False
    }
  })
}

pub fn spec_files_allow_tests_and_ordinary_helpers_test() {
  let report =
    compiler.check_source(
      "test/main.spec.pooka",
      "module main\n_helper() { 42 }\nclass Value(value: Int)\ntest \"helper\" { assert _helper() == Value(42).value }\n",
    )
  assert report.diagnostics == []
}

pub fn skipped_and_multiple_tests_still_require_a_spec_file_test() {
  let report =
    compiler.check_source(
      "src/main.pooka",
      "module main\ntest \"first\" { assert True }\ntest skip \"later\" { assert True }\n",
    )
  assert list.map(report.diagnostics, fn(error) { error.id })
    == ["analysis.test_location", "analysis.test_location"]
}

// Exercise the command paths as well as the checker. Formatting and exports
// must not quietly accept an inline test that ordinary checking rejects.
pub fn commands_and_production_exports_reject_misplaced_tests_test() {
  use directory <- support.with_directory("test_location_commands")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { Nil }\ntest \"misplaced\" { assert True }\n",
  )
  list.each(
    [
      ["check"],
      ["build"],
      ["run"],
      ["test"],
      ["docs"],
      ["format"],
      ["format", "--check"],
      ["export", "escript"],
      ["export", "shipment"],
      ["export", "release"],
    ],
    fn(arguments) {
      let report = support.cli_main(arguments, command.plain(directory))
      assert report.status == 1
      assert string.contains(
        report.stderr,
        "test declaration outside a spec file",
      )
      assert string.contains(report.stderr, "src/main.pooka:3")
    },
  )
}

pub fn valid_spec_tests_can_use_their_private_helpers_test() {
  use directory <- support.with_directory("test_location_spec_helpers")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\nmain() { Nil }\n")
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\n_helper() { 42 }\ntest \"helper\" { assert _helper() == 42 }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 0
  assert string.contains(report.stdout, "1 test, 1 passed")
}

pub fn misplaced_test_diagnostic_snapshot_test() {
  let report = compiler.check_source(support.path, source)
  support.render_all(report.diagnostics, source)
  |> birdie.snap("analysis_tests_require_spec_files")
}
