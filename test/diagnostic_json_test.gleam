//// The machine reader needs the whole address too.
////
//// Check structured reports, severity visibility and stable source ordering.
//// JSON snapshots retain labels and fix data for tools that cannot read a
//// terminal frame. An empty report is still a valid report.

import birdie
import diagnostics/diagnostic
import diagnostics/json as diagnostic_json
import gleam/dynamic/decode
import gleam/json
import gleam/string
import utilities/location

pub fn empty_report_test() {
  assert diagnostic_json.render([], diagnostic.Quiet)
    == "{\"version\":1,\"diagnostics\":[],\"summary\":{\"errors\":0,\"warnings\":0,\"notices\":0}}"
}

pub fn notice_visibility_test() {
  let notices = [diagnostic.notice("test.notice", "a notice")]
  assert diagnostic_json.render(notices, diagnostic.Quiet)
    == diagnostic_json.render([], diagnostic.Quiet)
  assert string.contains(
    diagnostic_json.render(notices, diagnostic.Verbose),
    "\"notices\":1",
  )
}

// Keep the complete structured report visible in one snapshot. Label ranges
// and fixes are part of the tool-facing contract, not merely terminal
// decoration.
pub fn diagnostic_data_snapshot_test() {
  let source = "é\r\n\tvalue"
  let at = location.new("src/quoted\".pooka", location.span(source, 2, 5))
  let value =
    diagnostic.error("test.structured", "quotes \" and newline\n")
    |> diagnostic.primary(at, "primary\tlabel")
    |> diagnostic.secondary(
      location.new("other.pooka", location.span("abc", 0, 3)),
      "context",
    )
    |> diagnostic.conclusion("Unicode: λ 🫎")
    |> diagnostic.note("a note")
    |> diagnostic.help("a suggestion")
    |> diagnostic.fix(at, "\"\\\n\t", "automatic edit", diagnostic.Automatic)
    |> diagnostic.fix(at, "", "suggested deletion", diagnostic.Suggested)
    |> diagnostic.fix(at, "?", "uncertain edit", diagnostic.Uncertain)
  let output = diagnostic_json.render([value], diagnostic.Quiet)

  let assert Ok(_) = json.parse(output, decode.dynamic)
  output |> birdie.snap(title: "json: complete diagnostic data")
}

pub fn stable_source_order_test() {
  let early =
    diagnostic.error("early", "early")
    |> diagnostic.primary(
      location.new("a.pooka", location.span("abc", 0, 1)),
      "",
    )
  let late =
    diagnostic.warning("late", "late")
    |> diagnostic.primary(
      location.new("z.pooka", location.span("abc", 2, 3)),
      "",
    )
  let unlocated = diagnostic.error("global", "global")
  assert diagnostic_json.render([late, early, unlocated], diagnostic.Quiet)
    == diagnostic_json.render([unlocated, early, late], diagnostic.Quiet)
}
