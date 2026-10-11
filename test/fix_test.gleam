//// A correction is a promise about the original bytes.
////
//// Apply edits against one unchanged source buffer. Overlaps, invalid
//// boundaries and malformed replacements reject the entire set, while adjacent
//// edits and duplicate requests follow explicit rules. Unicode tests guard the
//// boundary between byte offsets and whole characters.

import birdie
import builder/check
import builder/fix as builder_fix
import cli/command
import diagnostics/diagnostic
import diagnostics/fix
import gleam/string
import simplifile
import support
import utilities/location

fn edit(
  source: String,
  start: Int,
  end: Int,
  replacement: String,
) -> diagnostic.Fix {
  diagnostic.Fix(
    location.new("src/main.pooka", location.span(source, start, end)),
    replacement,
    "test edit",
    diagnostic.Automatic,
  )
}

pub fn replaces_in_original_byte_order_test() {
  let source = "éabc\r\nxyz"
  let edits = [
    edit(source, 8, 9, "!"),
    edit(source, 2, 3, "LONG"),
    edit(source, 5, 5, "?"),
  ]
  assert fix.apply(source, edits) == Ok("éLONGbc?\r\nx!z")
}

pub fn insertion_and_deletion_test() {
  assert fix.apply("abc", [edit("abc", 3, 3, "!"), edit("abc", 0, 1, "")])
    == Ok("bc!")
  assert fix.apply("", [edit("", 0, 0, "hello")]) == Ok("hello")
}

pub fn adjacent_edits_test() {
  assert fix.apply("abc", [edit("abc", 0, 1, "x"), edit("abc", 1, 2, "y")])
    == Ok("xyc")
}

pub fn duplicate_edits_test() {
  let first = edit("abc", 1, 2, "!")
  assert fix.apply("abc", [
      first,
      diagnostic.Fix(..first, description: "another explanation"),
    ])
    == Ok("a!c")
}

// Apply the set atomically. Keeping the first of two conflicting edits would
// produce a result that neither diagnostic actually requested.
pub fn conflicts_reject_the_entire_set_test() {
  assert fix.apply("abc", [edit("abc", 0, 2, "x"), edit("abc", 1, 3, "y")])
    == Error(fix.ConflictingEdits)
  assert fix.apply("abc", [edit("abc", 1, 1, "x"), edit("abc", 1, 1, "y")])
    == Error(fix.ConflictingEdits)
  assert fix.apply("abc", [edit("abc", 1, 1, "x"), edit("abc", 1, 2, "y")])
    == Error(fix.ConflictingEdits)
}

// A byte range can land inside a Unicode character. Reject it instead of
// manufacturing invalid source while trying to repair another error.
pub fn rejects_invalid_utf8_and_bounds_test() {
  let first = edit("é", 0, 2, "x")
  let bad = fn(start, end) {
    diagnostic.Fix(
      ..first,
      location: location.new(
        "src/main.pooka",
        location.Span(
          location.Position(1, 1, start),
          location.Position(1, 1, end),
        ),
      ),
    )
  }
  assert fix.apply("é", [bad(1, 2)]) == Error(fix.InvalidSpan)
  assert fix.apply("é", [bad(0, 1)]) == Error(fix.InvalidSpan)
  assert fix.apply("é", [bad(-1, 1)]) == Error(fix.InvalidSpan)
  assert fix.apply("é", [bad(0, 3)]) == Error(fix.InvalidSpan)
  assert fix.apply("é", [bad(2, 0)]) == Error(fix.InvalidSpan)
}

pub fn selects_only_automatic_edits_for_the_file_test() {
  let at = location.new("src/main.pooka", location.span("abc", 0, 1))
  let other = location.new("src/other.pooka", location.span("abc", 0, 1))
  let value =
    diagnostic.error("test", "test")
    |> diagnostic.fix(at, "a", "automatic", diagnostic.Automatic)
    |> diagnostic.fix(at, "b", "suggested", diagnostic.Suggested)
    |> diagnostic.fix(at, "c", "uncertain", diagnostic.Uncertain)
    |> diagnostic.fix(other, "d", "other file", diagnostic.Automatic)
  assert fix.automatic([value], "src/main.pooka")
    == [diagnostic.Fix(at, "a", "automatic", diagnostic.Automatic)]
}

fn project(directory: String, source: String) -> Nil {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", source)
}

pub fn cli_applies_fixes_and_rechecks_test() {
  use directory <- support.with_directory("fix_cli")
  project(directory, "module main\nmain() { 1; }\n")
  let outcome = support.cli_main(["check", "--fix"], command.plain(directory))
  assert outcome.status == 0
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == ""
  assert string.contains(outcome.stderr, "Checked 1 file in 0µs")
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\nmain() { 1 }\n")
  assert support.cli_main(["check", "--fix"], command.plain(directory))
    == outcome
}

pub fn suggested_fixes_are_left_for_review_test() {
  use directory <- support.with_directory("fix_suggested")
  let source = "module wrong\nmain() { 1; }\n"
  project(directory, source)
  let outcome =
    support.cli_main(["check", "--fix", "--json"], command.plain(directory))
  assert outcome.status == 1
  assert support.diagnostics(outcome.stderr) == ""
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module wrong\nmain() { 1 }\n")
  outcome.stdout
  |> birdie.snap(title: "fix: JSON reports remaining diagnostics")
}

pub fn plain_check_does_not_apply_edits_test() {
  use directory <- support.with_directory("fix_read_only")
  let source = "module main\nmain() { 1; }\n"
  project(directory, source)
  let outcome = support.cli_main(["check"], command.plain(directory))
  assert outcome.status == 1
  assert simplifile.read(directory <> "/src/main.pooka") == Ok(source)
}

pub fn changed_sources_are_not_overwritten_test() {
  use directory <- support.with_directory("fix_stale")
  project(directory, "module main\nmain() { 1; }\n")
  support.write(directory <> "/src/other.pooka", "module other\nf() { 2; }\n")
  let assert Ok(report) = check.check_project(directory)
  support.write(directory <> "/src/other.pooka", "module other\nf() { 3 }\n")
  let assert Error(_) = builder_fix.apply(report)

  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\nmain() { 1; }\n")
  assert simplifile.read(directory <> "/src/other.pooka")
    == Ok("module other\nf() { 3 }\n")
}

pub fn fixes_multiple_files_and_preserves_crlf_test() {
  use directory <- support.with_directory("fix_multi")
  project(directory, "module main\r\nmain() { 1; }\r\n")
  support.write(
    directory <> "/test/example.spec.pooka",
    "module example\nf() { 2; }\n",
  )
  let outcome =
    support.cli_main(["check", "--fix", "--json"], command.plain(directory))
  assert outcome.status == 0
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\r\nmain() { 1 }\r\n")
  assert simplifile.read(directory <> "/test/example.spec.pooka")
    == Ok("module example\nf() { 2 }\n")
}

pub fn each_fix_invocation_performs_only_one_pass_test() {
  use directory <- support.with_directory("fix_one_pass")
  project(directory, "module main\nimport unused\nmain() { 1; }\n")
  support.write(directory <> "/src/unused.pooka", "module unused\n")
  let first =
    support.cli_main(["check", "--fix", "--json"], command.plain(directory))
  assert first.status == 0
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\nimport unused\nmain() { 1 }\n")
  let second =
    support.cli_main(["check", "--fix", "--json"], command.plain(directory))
  assert second.status == 0
  assert simplifile.read(directory <> "/src/main.pooka")
    == Ok("module main\n\nmain() { 1 }\n")
}
