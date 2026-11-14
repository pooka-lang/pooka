//// Native transforms belong to the build VM, not the compiler's code server.

import builder/native
import gleam/list
import gleam/string
import project/dependency
import project/project
import support

@external(erlang, "parallel_compile_test_ffi", "native_transform_is_unloaded")
fn native_transform_is_unloaded() -> Bool

fn fixture(directory: String) -> project.Project {
  support.write(
    directory <> "/pooka.toml",
    "name = \"fixture\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/fixture.app.src",
    "{application,fixture,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
  )
  let assert Ok(config) = project.load(directory)
  project.Project(..config, kind: dependency.Beam("fixture", ["rebar3"]))
}

pub fn native_parse_transforms_do_not_enter_the_parent_vm_test() {
  use directory <- support.with_directory("native_isolated_transform")
  let config = fixture(directory)
  support.write(
    directory <> "/rebar.config",
    "{erl_first_files,[\"src/isolated_native_transform.erl\"]}.\n",
  )
  support.write(
    directory <> "/src/isolated_native_transform.erl",
    "-module(isolated_native_transform).\n-export([parse_transform/2]).\nparse_transform(Forms, _) -> Forms.\n",
  )
  support.write(
    directory <> "/src/fixture.erl",
    "-module(fixture).\n-compile({parse_transform,isolated_native_transform}).\n-export([answer/0]).\nanswer() -> 42.\n",
  )
  assert native_transform_is_unloaded()
  let assert Ok(library) = native.directory(directory <> "/stage")
  use <- native.using_directory(library)
  let assert Ok(result) = native.compile(config, library)
  assert list.length(result.0) == 2
  assert native_transform_is_unloaded()
}

pub fn parallel_native_errors_stay_in_source_order_test() {
  use directory <- support.with_directory("native_ordered_errors")
  let config = fixture(directory)
  support.write(
    directory <> "/src/a_broken.erl",
    "-module(a_broken).\nanswer() -> .\n",
  )
  support.write(
    directory <> "/src/z_broken.erl",
    "-module(z_broken).\nanswer() -> .\n",
  )
  let assert Ok(library) = native.directory(directory <> "/stage")
  use <- native.using_directory(library)
  let assert Error(detail) = native.compile(config, library)
  assert string.contains(detail, "a_broken.erl")
  assert !string.contains(detail, "z_broken.erl")
}
