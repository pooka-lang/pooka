//// Every package can keep its own front door.

import builder/build
import cli/command
import gleam/list
import gleam/option.{None, Some}
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

pub fn package_shorthand_wins_and_invalid_explicit_entries_keep_clear_errors_test() {
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
  let package =
    support.cli_main(
      ["run", "-m", "tool", "--", "--help", "two words", ""],
      env,
    )
  assert package.status == 0
  assert package.stdout == "\"tool\"\n"
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

pub fn a_same_named_library_module_does_not_hide_its_package_entrypoint_test() {
  use directory <- support.with_directory("run_target_same_named_library")
  let env = setup(directory)
  support.write(
    directory <> "/tool/src/tool.pooka",
    "module tool\nanswer() { 42 }\n",
  )
  let selected =
    support.cli_main(
      ["run", "-m", "tool", "--", "--help", "two words", ""],
      env,
    )
  assert selected.status == 0
  assert selected.stdout == "\"tool\"\n"
  let exact = support.cli_main(["run", "-m", "tool:tool"], env)
  assert exact.status == 1
  assert string.contains(exact.stderr, "zero-argument main()")
}

pub fn a_package_entrypoint_wins_over_its_same_named_executable_module_test() {
  use directory <- support.with_directory("run_target_same_named_executable")
  let env = setup(directory)
  support.write(
    directory <> "/tool/src/tool.pooka",
    "module tool\nmain() { echo \"module tool\" }\n",
  )
  let bare =
    support.cli_main(
      ["run", "-m", "tool", "--", "--help", "two words", ""],
      env,
    )
  assert bare.status == 0
  assert bare.stdout == "\"tool\"\n"
  assert support.cli_main(["run", "-m", "tool:tool"], env).stdout
    == "\"module tool\"\n"
}

pub fn ambiguity_lists_only_runnable_modules_test() {
  use directory <- support.with_directory("run_target_runnable_choices")
  let env = setup(directory)
  support.write(
    directory <> "/app/src/tool/shared.pooka",
    "module shared\nmain() { Nil }\n",
  )
  support.write(
    directory <> "/tool/src/shared.pooka",
    "module shared\nmain() { Nil }\n",
  )
  let ambiguous = support.cli_main(["run", "-m", "tool/shared"], env)
  assert ambiguous.status == 1
  assert string.contains(ambiguous.stderr, "ambiguous")
  assert string.contains(ambiguous.stderr, "app:tool/shared")
  assert string.contains(ambiguous.stderr, "tool:shared")
  support.write(
    directory <> "/app/src/tool/shared.pooka",
    "module shared\nanswer() { 42 }\n",
  )
  let runnable = support.cli_main(["run", "-m", "tool/shared"], env)
  assert runnable.status == 0
  assert string.contains(runnable.stderr, "Running tool.shared")
}

pub fn selected_development_tools_accept_arguments_without_a_separator_test() {
  use directory <- support.with_directory("run_target_unseparated_arguments")
  let env = setup(directory)
  list.each(["-m", "--module"], fn(flag) {
    let report =
      support.cli_main(["run", flag, "tool", "--help", "two words", ""], env)
    assert report.status == 0
    assert report.stdout == "\"tool\"\n"
  })
}

pub fn selected_tools_own_colliding_options_and_internal_separators_test() {
  use directory <- support.with_directory("run_target_colliding_options")
  let env = setup(directory)
  support.write(
    directory <> "/tool/src/main.pooka",
    "module main\nexternal Args from erlang \"tool_args\" { get() -> List(String) }\nmessage() { \"tool\" }\nmain() { echo Args.get() }\n",
  )
  list.each(
    [
      [
        "review",
        "--verbose",
        "-m",
        "another",
        "--module",
        "other",
        "--",
        "--help",
        "",
      ],
      ["--help"],
      ["-h"],
      ["--module", "other"],
      ["-m", "other"],
    ],
    fn(arguments) {
      let direct =
        support.cli_main(list.append(["run", "-m", "tool"], arguments), env)
      let separated =
        support.cli_main(
          list.append(["run", "-m", "tool", "--"], arguments),
          env,
        )
      assert direct.status == 0
      assert direct.stdout == separated.stdout
    },
  )
  assert support.cli_main(["run", "review"], env).status == 1
  assert support.cli_main(["run", "--help"], env).status == 0
}

pub fn only_unambiguous_selectors_name_a_dependency_test() {
  let dependencies = ["tool", "tome"]
  assert build.selects_dependency(Some("tool"), "app", dependencies)
  assert build.selects_dependency(Some("tool:main"), "app", dependencies)
  assert build.selects_dependency(Some("tool:tools/check"), "app", dependencies)
  // The root's own entry points, and spellings a root module could share.
  assert !build.selects_dependency(None, "app", dependencies)
  assert !build.selects_dependency(Some("app"), "app", dependencies)
  assert !build.selects_dependency(Some("app:main"), "app", dependencies)
  assert !build.selects_dependency(Some("checker"), "app", dependencies)
  assert !build.selects_dependency(Some("tool/main"), "app", dependencies)
  assert !build.selects_dependency(Some("absent:main"), "app", dependencies)
}

pub fn a_dependency_tool_runs_while_the_project_does_not_compile_test() {
  use directory <- support.with_directory("run_target_broken_root")
  let env = setup(directory)
  assert support.cli_main(["run"], env).stdout == "\"app\"\n"
  let ebin = directory <> "/app/build/dev/erlang/app/ebin"
  let assert Ok(before) = simplifile.read_directory(ebin)

  // A code generator may well be the reason the project does not compile.
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nmain() {\n  this is not pooka\n}\n",
  )
  list.each(["tool", "tool:main"], fn(selector) {
    let report =
      support.cli_main(
        ["run", "-m", selector, "--", "--help", "two words", ""],
        env,
      )
    assert report.status == 0
    assert report.stdout == "\"tool\"\n"
    assert string.contains(report.stderr, "Running tool.main")
  })

  // Running the tool again reuses its build: the project is not its concern.
  let again =
    support.cli_main(
      ["run", "-m", "tool", "--", "--help", "two words", ""],
      env,
    )
  assert again.status == 0
  assert !string.contains(again.stderr, "Compiling")

  // The project's own output is left exactly as it was.
  let assert Ok(after) = simplifile.read_directory(ebin)
  assert list.sort(after, string.compare) == list.sort(before, string.compare)

  // Its own entry points still need it to compile, and say why they cannot run.
  let own = support.cli_main(["run", "-m", "checker"], env)
  assert own.status == 1
  assert string.contains(own.stderr, "unexpected `is`")

  // Once mended, the whole project builds and runs again.
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nmessage() { \"app\" }\nmain() { echo \"app\" }\n",
  )
  assert support.cli_main(["run"], env).stdout == "\"app\"\n"
  assert support.cli_main(["run", "-m", "checker"], env).stdout
    == "\"checker\"\n"
}
