//// Every package can keep its own front door.

import cli/command
import gleam/list
import gleam/string
import simplifile
import support

fn setup(directory: String) -> command.Environment {
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dev-dependencies]\ntool = { path = \"../tool\" }\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nmessage() { \"app\" }\nmain() { echo \"app\" }\n",
  )
  support.write(
    directory <> "/app/src/checker.pooka",
    "module checker\nimport main as app_entry\nimport tool/use\nmain() { assert app_entry.message() == \"app\"\nassert use.answer() == \"tool\"\necho \"checker\" }\n",
  )
  support.write(
    directory <> "/tool/pooka.toml",
    "name = \"tool\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/tool/ffi/tool_args.erl",
    "-module(tool_args).\n-export([get/0]).\nget() -> [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].\n",
  )
  support.write(
    directory <> "/tool/src/main.pooka",
    "module main\nexternal Args from erlang \"tool_args\" { get() -> List(String) }\nmessage() { \"tool\" }\nmain() { assert Args.get() == [\"--help\", \"two words\", \"\"]\necho \"tool\" }\n",
  )
  support.write(
    directory <> "/tool/src/tool/use.pooka",
    "module use\nimport main as own_entry\nanswer() { own_entry.message() }\n",
  )
  command.plain(directory <> "/app")
}

pub fn package_main_modules_are_distinct_and_owned_imports_stay_local_test() {
  use directory <- support.with_directory("run_target_owners")
  let env = setup(directory)
  let app = support.cli_main(["run"], env)
  assert app.status == 0
  assert app.stdout == "\"app\"\n"
  let checker = support.cli_main(["run", "-m", "checker"], env)
  assert checker.status == 0
  assert checker.stdout == "\"checker\"\n"
  assert string.contains(checker.stderr, "Running app.checker")
  assert support.cli_main(["run", "-m", "main"], env).stdout == "\"app\"\n"
}

pub fn dependency_entrypoints_forward_all_arguments_unchanged_test() {
  use directory <- support.with_directory("run_target_arguments")
  let env = setup(directory)
  list.each(
    [#("-m", "tool"), #("--module", "tool:main"), #("-m", "tool/main")],
    fn(selector) {
      let report =
        support.cli_main(
          ["run", selector.0, selector.1, "--", "--help", "two words", ""],
          env,
        )
      assert report.status == 0
      assert report.stdout == "\"tool\"\n"
      assert string.contains(report.stderr, "Running tool.main")
    },
  )
}

pub fn a_library_without_its_own_main_can_run_a_development_tool_test() {
  use directory <- support.with_directory("run_target_library")
  let env = setup(directory)
  let assert Ok(Nil) =
    simplifile.delete_file(directory <> "/app/src/main.pooka")
  let assert Ok(Nil) =
    simplifile.delete_file(directory <> "/app/src/checker.pooka")
  support.write(
    directory <> "/app/src/library.pooka",
    "module library\nanswer() { 42 }\n",
  )
  assert support.cli_main(
      ["run", "-m", "tool", "--", "--help", "two words", ""],
      env,
    ).status
    == 0
  let missing = support.cli_main(["run"], env)
  assert missing.status == 1
  assert string.contains(missing.stderr, "requires src/main.pooka")
}

pub fn foreign_main_modules_are_not_importable_api_test() {
  use directory <- support.with_directory("run_target_private_main")
  let env = setup(directory)
  let assert Ok(Nil) =
    simplifile.delete_file(directory <> "/app/src/main.pooka")
  support.write(
    directory <> "/app/src/checker.pooka",
    "module checker\nimport main\nanswer() { main.message() }\n",
  )
  let report = support.cli_main(["check"], env)
  assert report.status == 1
  assert string.contains(report.stderr, "unknown module")
  assert !string.contains(report.stderr, "multiple packages")
}

pub fn selectors_report_ambiguity_missing_modules_and_main_arity_test() {
  use directory <- support.with_directory("run_target_errors")
  let env = setup(directory)
  support.write(
    directory <> "/app/src/tool.pooka",
    "module tool\nmain() { echo \"local tool\" }\n",
  )
  support.write(
    directory <> "/app/src/api.pooka",
    "module api\nanswer() { 42 }\n",
  )
  support.write(
    directory <> "/app/src/arity.pooka",
    "module arity\nmain(value: Int) { value }\n",
  )
  let ambiguous = support.cli_main(["run", "-m", "tool"], env)
  assert ambiguous.status == 1
  assert string.contains(ambiguous.stderr, "ambiguous")
  assert string.contains(ambiguous.stderr, "app:tool")
  assert string.contains(ambiguous.stderr, "tool:main")
  assert support.cli_main(["run", "-m", "app:tool"], env).stdout
    == "\"local tool\"\n"
  list.each(["api", "arity"], fn(name) {
    let report = support.cli_main(["run", "-m", name], env)
    assert report.status == 1
    assert string.contains(report.stderr, "zero-argument main()")
  })
  let missing = support.cli_main(["run", "-m", "absent"], env)
  assert missing.status == 1
  assert string.contains(missing.stderr, "No entry module or package")
  assert support.cli_main(["run", "-m"], env).status == 1
}
