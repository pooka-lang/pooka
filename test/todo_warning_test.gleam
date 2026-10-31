//// Leave a note at every door that is not finished yet.
////
//// A `todo` still compiles, so unfinished programs can run their finished
//// parts. Every `todo` the source can reach produces one warning at its own
//// location: in functions, methods, constructors, closures, actors and tests.
//// The warning never becomes an error, and `panic` stays silent because it is
//// a deliberate stop rather than missing work.
////
//// ```pooka
//// later() -> Int { todo as "teach the parser about floats" }
//// ```

import birdie
import compiler/analysis/resolve
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import support
import utilities/colour

fn todo_warnings(body: String) -> List(diagnostic.Diagnostic) {
  let source = "module main\n" <> body
  resolve.resolve_with_exports(support.parse(source), support.path, dict.new())
  |> fn(resolved) { resolved.diagnostics }
  |> list.filter(fn(value) { value.id == "analysis.todo" })
}

pub fn a_todo_produces_one_warning_test() {
  let assert [warning] = todo_warnings("later() -> Int { todo }")
  assert warning.severity == diagnostic.WarningSeverity
  let assert [_] =
    todo_warnings(
      "later() -> Int { todo as \"teach the parser about floats\" }",
    )
}

pub fn every_reachable_todo_is_reported_test() {
  let source =
    "class Lantern {\n  let room: String\n  new(room: String) { self.room = todo }\n  light() -> String { todo }\n}\nactor Kettle {\n  be pour() { todo }\n}\nlater() { fn() { todo } }\ntest \"unfinished\" { todo }\n"
  assert list.length(todo_warnings(source)) == 5
}

pub fn panic_is_not_reported_as_unfinished_work_test() {
  assert todo_warnings("stop() -> Int { panic as \"the bridge is out\" }") == []
}

pub fn todo_warning_snapshot_test() {
  let source =
    "module main\nlater() -> Int {\n  todo as \"teach the parser about floats\"\n}\n"
  resolve.resolve_with_exports(support.parse(source), support.path, dict.new())
  |> fn(resolved) { resolved.diagnostics }
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "analysis: todo warning")
}
