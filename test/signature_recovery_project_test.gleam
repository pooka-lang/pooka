//// A repaired interface should help the next module, while its owner still fails.
//// Text, JSON and build status must agree about that distinction.

import birdie
import builder/infer
import cli/command
import compiler/typesystem/monotype
import diagnostics/diagnostic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import support

fn project(directory: String, caller_error: Bool) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/models.pooka",
    "module models\nclass Box(value: Int)\n",
  )
  support.write(
    directory <> "/src/collections.pooka",
    "module collections\nmap_first(items: List(a), change: fn(a) -> b) -> b {\n  let assert [first, .._rest] = items\n  change(first)\n}\n",
  )
  support.write(
    directory <> "/src/helpers.pooka",
    "module helpers\nimport models.{Box}\nmake() -> List(Box) { [Box(\"wrong\")] }\n",
  )
  let main = case caller_error {
    False ->
      "main() { collections.map_first(helpers.make(), fn(box) { box.value }) }\n"
    True ->
      "main() {\n  let received: String = collections.map_first(helpers.make(), fn(box) { box.value })\n  received\n}\n"
  }
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport helpers\nimport collections\n" <> main,
  )
}

fn error_count(output: String) -> Int {
  let assert Ok(count) =
    json.parse(output, decode.at(["summary", "errors"], decode.int))
  count
}

pub fn a_failed_import_retains_its_declared_result_for_generic_callbacks_test() {
  use directory <- support.with_directory("signature_recovery_imports")
  project(directory, False)
  let assert Ok(report) = infer.preview(directory)
  assert list.length(report.diagnostics) == 1
  let assert Ok(main) =
    list.find(report.modules, fn(value) { value.identity == "main" })
  let assert [function] = main.inferred.functions
  assert monotype.to_string(function.type_) == "fn() -> Int"
  let assert [problem] = report.diagnostics
  let assert Ok(at) = diagnostic.primary_location(problem)
  assert at.path == "src/helpers.pooka"
}

pub fn text_and_json_report_the_body_error_without_a_member_access_cascade_test() {
  use directory <- support.with_directory("signature_recovery_cli")
  project(directory, False)
  let text = support.cli_main(["check"], command.plain(directory))
  let structured =
    support.cli_main(["check", "--json"], command.plain(directory))
  assert text.status == 1
  assert structured.status == 1
  assert structured.stderr == ""
  assert error_count(structured.stdout) == 1
  let assert Ok(ids) =
    json.parse(
      structured.stdout,
      decode.at(["diagnostics"], decode.list(decode.at(["id"], decode.string))),
    )
  assert ids == ["type.unification"]
  support.diagnostics(text.stderr)
  |> birdie.snap(
    title: "types: failed body keeps its declared signature in text diagnostics",
  )
  structured.stdout
  |> birdie.snap(
    title: "types: failed body keeps its declared signature in JSON diagnostics",
  )
}

pub fn independent_errors_in_the_caller_remain_in_text_and_json_test() {
  use directory <- support.with_directory("signature_recovery_independent")
  project(directory, True)
  let assert Ok(report) = infer.preview(directory)
  assert list.length(report.diagnostics) == 2
  let paths =
    list.map(report.diagnostics, fn(problem) {
      let assert Ok(at) = diagnostic.primary_location(problem)
      at.path
    })
  assert paths == ["src/helpers.pooka", "src/main.pooka"]
  let text = support.cli_main(["check"], command.plain(directory))
  assert text.status == 1
  assert string.contains(text.stderr, "src/helpers.pooka")
  assert string.contains(text.stderr, "src/main.pooka")
  let structured =
    support.cli_main(["check", "--json"], command.plain(directory))
  assert structured.status == 1
  assert error_count(structured.stdout) == 2
}

pub fn retaining_a_contract_does_not_allow_an_invalid_program_to_build_test() {
  use directory <- support.with_directory("signature_recovery_build_rejection")
  project(directory, False)
  let build = support.cli_main(["build"], command.plain(directory))
  let run = support.cli_main(["run"], command.plain(directory))
  assert build.status == 1
  assert run.status == 1
  assert run.stdout == ""
}
