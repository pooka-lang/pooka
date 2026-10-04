//// Bad news deserves a legible letter.
////
//// Construct diagnostics directly and inspect their plain and coloured
//// rendering. Labels may cross lines or files, source text may be missing, and
//// Unicode makes byte offsets differ from printed columns. Snapshots preserve
//// the layout a reader actually sees.

import birdie
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/string
import support
import utilities/colour
import utilities/location

const path = "src/main.pooka"

fn at(source: String, needle: String) -> location.Location {
  location.new(path, support.span_of(source, needle))
}

fn plain(diagnostic: diagnostic.Diagnostic, source: String) -> String {
  render.render_in(diagnostic, path, source, colour.PlainText)
}

pub fn builder_test() {
  let source = "let x = 1"
  let built =
    diagnostic.error("test.id", "a title")
    |> diagnostic.primary(at(source, "x"), "primary")
    |> diagnostic.secondary(at(source, "1"), "secondary")
    |> diagnostic.conclusion("The conclusion.")
    |> diagnostic.note("A note.")
    |> diagnostic.help("Some help.")
    |> diagnostic.fix(at(source, "1"), "2", "Use two", diagnostic.Suggested)
  assert built.severity == diagnostic.ErrorSeverity
  assert list.length(built.labels) == 2
  assert built.notes == ["A note."]
  assert built.suggestions == ["Some help."]
  let assert [
    diagnostic.Fix(replacement: "2", applicability: diagnostic.Suggested, ..),
  ] = built.fixes
  let assert Ok(primary) = diagnostic.primary_label(built)
  assert primary.message == "primary"
}

// A diagnostic without an explicit primary still needs somewhere sensible to
// point. The first available label supplies that fallback location.
pub fn primary_label_falls_back_to_the_first_label_test() {
  let source = "a b"
  let built =
    diagnostic.warning("test.id", "title")
    |> diagnostic.secondary(at(source, "b"), "only secondary")
  let assert Ok(label) = diagnostic.primary_label(built)
  assert label.message == "only secondary"
}

pub fn summary_test() {
  let error = diagnostic.error("e", "e")
  let warning = diagnostic.warning("w", "w")
  let notice = diagnostic.notice("n", "n")
  assert diagnostic.summary([]) == ""
  assert diagnostic.summary([notice]) == ""
  assert diagnostic.summary([error]) == "Found 1 error."
  assert diagnostic.summary([error, error]) == "Found 2 errors."
  assert diagnostic.summary([warning]) == "Found 1 warning."
  assert diagnostic.summary([error, error, error, warning])
    == "Found 3 errors and 1 warning."
}

pub fn notices_are_hidden_unless_verbose_test() {
  let diagnostics = [diagnostic.notice("n", "n"), diagnostic.warning("w", "w")]
  assert list.length(diagnostic.visible(diagnostics, diagnostic.Quiet)) == 1
  assert list.length(diagnostic.visible(diagnostics, diagnostic.Verbose)) == 2
}

pub fn sort_is_by_file_then_position_test() {
  let source = "a b c"
  let make = fn(id, needle, file) {
    diagnostic.error(id, id)
    |> diagnostic.primary(
      location.new(file, support.span_of(source, needle)),
      "",
    )
  }
  let sorted =
    diagnostic.sort([
      make("third", "a", "src/z.pooka"),
      make("second", "c", "src/a.pooka"),
      make("first", "a", "src/a.pooka"),
      diagnostic.error("unlocated", "unlocated"),
    ])
  assert list.map(sorted, fn(d) { d.id })
    == ["unlocated", "first", "second", "third"]
}

pub fn has_errors_test() {
  assert diagnostic.has_errors([diagnostic.warning("w", "w")]) == False
  assert diagnostic.has_errors([
    diagnostic.warning("w", "w"),
    diagnostic.error("e", "e"),
  ])
}

// The explanatory conclusion belongs after the reader has seen the marked
// source. Reordering it changes the way the diagnostic is read.
pub fn conclusion_comes_after_the_snippet_test() {
  let source = "pritn(\"Hello\")"
  let text =
    diagnostic.error("name.unknown", "unknown name")
    |> diagnostic.primary(at(source, "pritn"), "not defined")
    |> diagnostic.conclusion("Could not find `pritn`.")
    |> plain(source)
  let assert Ok(#(before, after)) = string.split_once(text, "Could not find")
  assert string.contains(before, "pritn(\"Hello\")")
  assert !string.contains(after, "│")
}

pub fn a_diagnostic_without_labels_has_no_frame_test() {
  let text =
    diagnostic.error("cli.unknown", "unknown command")
    |> diagnostic.conclusion("`pooka x` is not a command.")
    |> render.render(dict.new(), colour.PlainText)
  assert text == "error: unknown command\n\n`pooka x` is not a command.\n"
}

pub fn plain_output_has_no_escapes_test() {
  let source = "x"
  let text =
    diagnostic.error("id", "title")
    |> diagnostic.primary(at(source, "x"), "here")
    |> plain(source)
  assert !string.contains(text, "\u{001b}")
}

pub fn basic_rendering_test() {
  let source = "module main\n\nmain() {\n  pritn(\"Hello\")\n}\n"
  diagnostic.error("name.unknown", "unknown name")
  |> diagnostic.primary(
    at(source, "pritn"),
    "`pritn` is not defined in this scope",
  )
  |> diagnostic.conclusion("Could not find `pritn`.")
  |> diagnostic.help("Did you mean `print`?")
  |> plain(source)
  |> birdie.snap(title: "render: basic diagnostic")
}

pub fn expected_and_found_rendering_test() {
  let source = "let age: Int = \"42\"\n"
  diagnostic.error("type.mismatch", "incompatible types")
  |> diagnostic.secondary(at(source, "Int"), "`age` is declared as Int")
  |> diagnostic.primary(at(source, "\"42\""), "this is a String")
  |> diagnostic.conclusion("Expected: Int\n   Found: String")
  |> plain(source)
  |> birdie.snap(title: "render: expected and found with two labels")
}

pub fn labels_on_separate_lines_rendering_test() {
  let source = "let count = 0\ncount = 1\n"
  diagnostic.error("binding.immutable", "cannot assign to an immutable binding")
  |> diagnostic.secondary(at(source, "count = 0"), "`count` is declared here")
  |> diagnostic.primary(at(source, "count = 1"), "assignment attempted here")
  |> diagnostic.conclusion("`count` cannot be assigned another value.")
  |> diagnostic.note("Local bindings in Pooka are immutable.")
  |> plain(source)
  |> birdie.snap(title: "render: labels on adjacent lines")
}

pub fn distant_labels_rendering_test() {
  let source = "add(a: Int, b: Int) {\n  a + b\n}\n\nadd(1)\n"
  diagnostic.error("call.arity", "incorrect arity")
  |> diagnostic.secondary(
    at(source, "add"),
    "`add` is defined with 2 parameters",
  )
  |> diagnostic.primary(at(source, "add(1)"), "only 1 argument is provided")
  |> diagnostic.conclusion("Expected 2 arguments, but found 1.")
  |> plain(source)
  |> birdie.snap(title: "render: distant labels with a gap")
}

pub fn multiple_files_rendering_test() {
  let user =
    "class User with Encoder {\n  encode() -> String {\n    \"\"\n  }\n}\n"
  let encoder = "interface Encoder {\n  encode() -> BitArray\n}\n"
  diagnostic.error("interface.mismatch", "method does not satisfy interface")
  |> diagnostic.primary(
    location.new("src/user.pooka", support.span_of(user, "encode() -> String")),
    "implementation returns String",
  )
  |> diagnostic.secondary(
    location.new(
      "src/encoder.pooka",
      support.span_of(encoder, "encode() -> BitArray"),
    ),
    "required by `Encoder`",
  )
  |> diagnostic.conclusion(
    "Expected: fn() -> BitArray\n   Found: fn() -> String",
  )
  |> render.render(
    dict.from_list([#("src/user.pooka", user), #("src/encoder.pooka", encoder)]),
    colour.PlainText,
  )
  |> birdie.snap(title: "render: labels in two files")
}

pub fn multiline_span_rendering_test() {
  let source = "main() {\n  match option {\n    Some(value) -> value\n  }\n}\n"
  diagnostic.error("match.exhaustive", "non-exhaustive match")
  |> diagnostic.primary(
    at(source, "match option {\n    Some(value) -> value\n  }"),
    "this match does not handle every possible value",
  )
  |> diagnostic.conclusion("Missing pattern: `None`")
  |> plain(source)
  |> birdie.snap(title: "render: a span over several lines")
}

// The source stores bytes, but the frame presents columns. Tabs and multibyte
// text make an incorrect conversion visible in the underline.
pub fn tabs_and_unicode_rendering_test() {
  let source = "\tlet greeting = \"Καλημέρα\" + oops\n"
  diagnostic.error("name.unknown", "unknown name")
  |> diagnostic.primary(at(source, "oops"), "not defined")
  |> plain(source)
  |> birdie.snap(title: "render: tabs and multi-byte text before a label")
}

pub fn missing_source_rendering_test() {
  diagnostic.error("name.unknown", "unknown name")
  |> diagnostic.primary(
    location.new("src/missing.pooka", support.span_of("abc", "b")),
    "here",
  )
  |> render.render(dict.new(), colour.PlainText)
  |> birdie.snap(title: "render: a label whose file is not available")
}

pub fn render_all_rendering_test() {
  let source = "let a = 1\nlet b = 2\n"
  let diagnostics = [
    diagnostic.warning("w", "unused binding")
      |> diagnostic.primary(at(source, "b"), "never used"),
    diagnostic.error("e", "first problem")
      |> diagnostic.primary(at(source, "a"), "problem"),
    diagnostic.notice("n", "hidden notice"),
  ]
  render.render_all(
    diagnostics,
    dict.from_list([#(path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(
    title: "render: several diagnostics in source order with a summary",
  )
}

pub fn coloured_rendering_test() {
  let source = "let age: Int = \"42\"\n"
  diagnostic.error("type.mismatch", "incompatible types")
  |> diagnostic.secondary(at(source, "Int"), "declared here")
  |> diagnostic.primary(at(source, "\"42\""), "this is a String")
  |> diagnostic.note("A note.")
  |> diagnostic.help("Some help.")
  |> render.render_in(path, source, colour.Ansi)
  |> support.show_escapes
  |> birdie.snap(title: "render: colour escape sequences")
}
