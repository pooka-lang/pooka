//// A dependency's development tools can stay in their own cupboard.

import builder/native
import builder/stamp
import gleam/list
import gleam/string
import project/config
import project/dependency
import project/package
import project/project
import simplifile
import support

fn fixture(directory: String) -> project.Project {
  support.write(
    directory <> "/src/fixture.erl",
    "-module(fixture).\n-export([main/0]).\n-ifndef(ANSWER).\n-define(ANSWER, 42).\n-endif.\nmain() -> io:format(\"~p~n\", [?ANSWER]).\n",
  )
  support.write(
    directory <> "/src/fixture.app.src",
    "{application,fixture,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
  )
  project.Project(
    directory,
    "fixture",
    "1.0.0",
    [],
    [],
    dependency.LocalOrigin,
    dependency.Beam("fixture", ["rebar3"]),
    [],
    config.defaults(),
  )
}

fn compile(
  directory: String,
  owner: project.Project,
) -> Result(#(List(#(String, BitArray)), String), String) {
  native.compile(owner, directory <> "/library")
}

pub fn project_plugins_and_development_hooks_do_not_block_dependency_builds_test() {
  use directory <- support.with_directory("native_development_hooks")
  let owner = fixture(directory)
  support.write(
    directory <> "/rebar.config",
    "{project_plugins,[dev_tool]}.\n{pre_hooks,[{eunit,\"must not run\"}]}.\n{post_hooks,[{ct,\"must not run\"}]}.\n{provider_hooks,[{pre,[{eunit,lint}]},{post,[{edoc,docs}]}]}.\n",
  )
  support.write(directory <> "/rebar.config.script", "CONFIG.\n")
  let assert Ok(#(modules, _)) = compile(directory, owner)
  assert list.length(modules) == 1
  assert support.execute(directory <> "/library/fixture/ebin", "fixture", [])
    == Ok("42\n")
}

pub fn config_and_script_bindings_and_cwd_are_available_in_an_isolated_vm_test() {
  use directory <- support.with_directory("native_script_bindings")
  let owner = fixture(directory)
  support.write(directory <> "/rebar.config", "{erl_opts,[{d,'BASE',20}]}.\n")
  support.write(directory <> "/answer.term", "43.\n")
  support.write(
    directory <> "/rebar.config.script",
    "true = filelib:is_regular(SCRIPT).\n{ok,[Answer]} = file:consult(\"answer.term\").\n[{erl_opts,Existing}] = CONFIG.\n[{erl_opts,[{d,'ANSWER',Answer}|Existing]}].\n",
  )
  let assert Ok(before) = simplifile.current_directory()
  let assert Ok(_) = compile(directory, owner)
  assert simplifile.current_directory() == Ok(before)
  assert support.execute(directory <> "/library/fixture/ebin", "fixture", [])
    == Ok("43\n")
  let graph = package.Graph(owner, [owner])
  let assert Ok(first) = stamp.snapshot(graph, "dev")
  support.write(directory <> "/answer.term", "44.\n")
  let assert Ok(second) = stamp.snapshot(graph, "dev")
  assert first != second
}

pub fn malformed_scripts_and_compile_affecting_configuration_remain_errors_test() {
  use directory <- support.with_directory("native_unsupported_tooling")
  let owner = fixture(directory)
  list.each(
    [
      #("{plugins,[build_plugin]}.\n", "compilation plugins"),
      #("{overrides,[{override,fixture,[]} ]}.\n", "overrides"),
      #("{pre_hooks,[{compile,\"must not run\"}]}.\n", "compilation hooks"),
      #("{provider_hooks,[{pre,[{compile,custom}]}]}.\n", "compilation hooks"),
      #(
        "{pre_hooks,[{unknown_stage,\"must not run\"}]}.\n",
        "compilation hooks",
      ),
      #("{port_specs,[{\"priv/driver.so\",[]} ]}.\n", "native build"),
    ],
    fn(pair) {
      support.write(directory <> "/rebar.config", pair.0)
      let assert Error(detail) = compile(directory, owner)
      assert string.contains(detail, pair.1)
    },
  )
  support.write(directory <> "/rebar.config", "")
  support.write(directory <> "/rebar.config.script", "not_a_configuration.\n")
  let assert Error(detail) = compile(directory, owner)
  assert string.contains(detail, "configuration list")
  support.write(directory <> "/rebar.config.script", "missing_function(.\n")
  let assert Error(detail) = compile(directory, owner)
  assert string.contains(detail, "rebar.config.script")
}

pub fn configuration_scripts_can_supply_configuration_without_a_base_file_test() {
  use directory <- support.with_directory("native_script_without_config")
  let owner = fixture(directory)
  support.write(
    directory <> "/rebar.config.script",
    "[] = CONFIG.\n[{erl_opts,[{d,'ANSWER',45}]}].\n",
  )
  let assert Ok(_) = compile(directory, owner)
  assert support.execute(directory <> "/library/fixture/ebin", "fixture", [])
    == Ok("45\n")
}
