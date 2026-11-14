//// A familiar name should keep its familiar meaning.
////
//// Exercise every built-in against each nominal declaration, then follow a
//// collision through the CLI to ensure inference does not add misleading errors.

import birdie
import cli/command
import compiler/compiler
import gleam/list
import gleam/string
import support

pub fn every_nominal_kind_rejects_every_builtin_type_name_test() {
  list.each(["class", "actor", "interface", "enum"], fn(kind) {
    list.each(
      [
        "Int", "Float", "String", "Bool", "Nil", "BitArray", "UtfCodepoint",
        "Pid", "List", "Option", "Result",
      ],
      fn(name) {
        let body = case kind {
          "enum" -> " { Value }\n"
          _ -> " {}\n"
        }
        let source = "module main\n" <> kind <> " " <> name <> body
        let report = compiler.check_source("src/main.pooka", source)
        assert report.lexed.errors == []
        assert report.parsed.errors == []
        let assert [error] = report.diagnostics
        assert error.id == "analysis.builtin_type_name"
        let assert [label] = error.labels
        assert label.location.path == "src/main.pooka"
        assert label.location.span.start.line == 2
        assert label.location.span.start.column == string.length(kind) + 2
        assert label.location.span.end.column
          == label.location.span.start.column + string.length(name)
        assert string.contains(label.message, "`" <> name <> "`")
      },
    )
  })
}

pub fn fresh_names_and_builtin_annotations_remain_valid_test() {
  let report =
    compiler.check_source(
      "src/main.pooka",
      "module main\nclass Process {}\nactor Worker {}\ninterface Task {}\nenum State { Ready }\nidentity(value: Result(Option(List(Pid)), String)) { value }\n",
    )
  assert report.diagnostics == []
}

pub fn constructors_with_builtin_names_are_not_type_declarations_test() {
  let report =
    compiler.check_source(
      "src/main.pooka",
      "module main\nenum Choice { Pid Int List }\n",
    )
  assert report.diagnostics == []
}

pub fn collisions_stop_before_derivative_type_errors_in_commands_test() {
  use directory <- support.with_directory("builtin_type_name_commands")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nclass Pid {}\nmake() -> Pid { Pid() }\nmain() { echo make() }\n",
  )
  list.each([["check"], ["build"], ["test"]], fn(arguments) {
    let report = support.cli_main(arguments, command.plain(directory))
    assert report.status == 1
    assert list.length(string.split(report.stderr, "error:")) == 2
    assert string.contains(report.stderr, "built-in type name redeclared")
    assert !string.contains(report.stderr, "type mismatch")
    assert !string.contains(report.stderr, "found main.Pid")
  })
}

pub fn builtin_collision_diagnostic_snapshot_test() {
  support.rendered(
    "module main\nclass Pid {}\nmake() -> Pid { Pid() }\nmain() { echo make() }\n",
  )
  |> birdie.snap(title: "analysis: built-in type name collision")
}
