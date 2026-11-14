//// A header can belong to a neighbour before that neighbour has an ebin.
//// Cache keys must remember its source, including paths hidden by macros.

import builder/stamp
import project/dependency
import project/package
import project/project
import simplifile
import support

fn fixture(directory: String) -> package.Graph {
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nshared_headers = { path = \"../headers_source\" }\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nmain() { 42 }\n",
  )
  support.write(
    directory <> "/headers_source/pooka.toml",
    "name = \"shared_headers\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/headers_source/src/headers.pooka",
    "module headers\nanswer() { 42 }\n",
  )
  support.write(
    directory <> "/headers_source/include/constants.hrl",
    "-define(ANSWER, 42).\n-define(HAS_EXTRA, true).\n",
  )
  support.write(
    directory <> "/app/ffi/sample.erl",
    "-module(sample).\n-include_lib(\"shared_headers/include/constants.hrl\").\n-export([answer/0]).\nanswer() -> ?ANSWER.\n",
  )
  let assert Ok(config) = project.load(directory <> "/app")
  let assert Ok(graph) = package.resolve(config, True)
  graph
}

pub fn unavailable_dependency_headers_still_produce_stable_snapshots_test() {
  use directory <- support.with_directory("headers_snapshot_stable")
  let graph = fixture(directory)
  let assert Ok(first) = stamp.snapshot(graph, "dev")
  assert stamp.snapshot(graph, "dev") == Ok(first)
}

pub fn header_changes_and_removal_invalidate_or_disable_snapshots_test() {
  use directory <- support.with_directory("headers_snapshot_change")
  let graph = fixture(directory)
  let assert Ok(first) = stamp.snapshot(graph, "dev")
  support.write(
    directory <> "/headers_source/include/constants.hrl",
    "-define(ANSWER, 43).\n",
  )
  let assert Ok(changed) = stamp.snapshot(graph, "dev")
  assert first.key != changed.key
  assert stamp.package_key(Ok(first), "app")
    != stamp.package_key(Ok(changed), "app")
  assert stamp.foreign_key(Ok(first), "app")
    != stamp.foreign_key(Ok(changed), "app")
  let assert Ok(Nil) =
    simplifile.delete(directory <> "/headers_source/include/constants.hrl")
  assert stamp.snapshot(graph, "dev") == Error(Nil)
}

pub fn macros_cannot_hide_local_headers_outside_standard_directories_test() {
  use directory <- support.with_directory("headers_conditional_local")
  let graph = fixture(directory)
  support.write(directory <> "/app/extra/local.hrl", "-define(LOCAL, 1).\n")
  support.write(
    directory <> "/app/ffi/sample.erl",
    "-module(sample).\n-include_lib(\"shared_headers/include/constants.hrl\").\n-ifdef(HAS_EXTRA).\n-include(\"../extra/local.hrl\").\n-endif.\n-export([answer/0]).\nanswer() -> ?ANSWER.\n",
  )
  let assert Ok(first) = stamp.snapshot(graph, "dev")
  support.write(directory <> "/app/extra/local.hrl", "-define(LOCAL, 2).\n")
  let assert Ok(changed) = stamp.snapshot(graph, "dev")
  assert first.key != changed.key
}

pub fn transitive_dependency_headers_outside_standard_directories_are_tracked_test() {
  use directory <- support.with_directory("headers_transitive")
  let graph = fixture(directory)
  support.write(
    directory <> "/headers_source/include/constants.hrl",
    "-include(\"../extra/nested.hrl\").\n",
  )
  support.write(
    directory <> "/headers_source/extra/nested.hrl",
    "-define(ANSWER, 42).\n",
  )
  let assert Ok(first) = stamp.snapshot(graph, "dev")
  support.write(
    directory <> "/headers_source/extra/nested.hrl",
    "-define(ANSWER, 43).\n",
  )
  let assert Ok(changed) = stamp.snapshot(graph, "dev")
  assert first.key != changed.key
}

pub fn unknown_libraries_local_missing_headers_and_syntax_errors_stay_uncacheable_test() {
  use directory <- support.with_directory("headers_bad_sources")
  let graph = fixture(directory)
  let source = directory <> "/app/ffi/sample.erl"
  support.write(
    source,
    "-module(sample).\n-include_lib(\"not_a_dependency/include/missing.hrl\").\n",
  )
  assert stamp.snapshot(graph, "dev") == Error(Nil)
  support.write(
    source,
    "-module(sample).\n-include_lib(\"shared_headers/include/constants.hrl\").\n-include(\"missing.hrl\").\n",
  )
  assert stamp.snapshot(graph, "dev") == Error(Nil)
  support.write(
    source,
    "-module(sample).\n-include_lib(\"shared_headers/include/constants.hrl\").\nanswer() -> .\n",
  )
  assert stamp.snapshot(graph, "dev") == Error(Nil)
}

pub fn dynamic_include_paths_do_not_create_an_incomplete_snapshot_test() {
  use directory <- support.with_directory("headers_dynamic_path")
  let graph = fixture(directory)
  support.write(
    directory <> "/app/ffi/sample.erl",
    "-module(sample).\n-include_lib(\"shared_headers/include/constants.hrl\").\n-include(?HEADER).\n",
  )
  assert stamp.snapshot(graph, "dev") == Error(Nil)
}

pub fn application_identity_can_differ_from_package_name_test() {
  use directory <- support.with_directory("headers_application_identity")
  let graph = fixture(directory)
  let assert [headers, app] = graph.packages
  let headers =
    project.Project(..headers, kind: dependency.Beam("header_app", ["rebar3"]))
  let graph = package.Graph(..graph, packages: [headers, app])
  support.write(
    directory <> "/app/ffi/sample.erl",
    "-module(sample).\n-include_lib(\"header_app/include/constants.hrl\").\nanswer() -> ?ANSWER.\n",
  )
  let assert Ok(_) = stamp.snapshot(graph, "dev")
}

pub fn guarded_recursive_header_paths_finish_without_losing_inputs_test() {
  use directory <- support.with_directory("headers_recursive_paths")
  let graph = fixture(directory)
  support.write(
    directory <> "/headers_source/include/constants.hrl",
    "-ifndef(CONSTANTS).\n-define(CONSTANTS, true).\n-include(\"../extra/nested.hrl\").\n-endif.\n",
  )
  support.write(
    directory <> "/headers_source/extra/nested.hrl",
    "-include(\"../include/constants.hrl\").\n-define(ANSWER, 42).\n",
  )
  let assert Ok(first) = stamp.snapshot(graph, "dev")
  assert stamp.snapshot(graph, "dev") == Ok(first)
}

pub fn unresolved_conditional_headers_disable_the_fallback_safely_test() {
  use directory <- support.with_directory("headers_unknown_conditional")
  let graph = fixture(directory)
  support.write(
    directory <> "/app/ffi/sample.erl",
    "-module(sample).\n-include_lib(\"shared_headers/include/constants.hrl\").\n-ifdef(HAS_EXTRA).\n-include(\"missing.hrl\").\n-endif.\nanswer() -> ?ANSWER.\n",
  )
  assert stamp.snapshot(graph, "dev") == Error(Nil)
}

pub fn fallback_preserves_normal_include_lib_search_precedence_test() {
  use directory <- support.with_directory("headers_search_precedence")
  let graph = fixture(directory)
  support.write(
    directory <> "/app/ffi/local_library/include/local.hrl",
    "-include(\"../../../extra/value.hrl\").\n",
  )
  support.write(directory <> "/app/extra/value.hrl", "-define(LOCAL, 1).\n")
  support.write(
    directory <> "/app/ffi/sample.erl",
    "-module(sample).\n-include_lib(\"shared_headers/include/constants.hrl\").\n-include_lib(\"local_library/include/local.hrl\").\nanswer() -> {?ANSWER, ?LOCAL}.\n",
  )
  let assert Ok(first) = stamp.snapshot(graph, "dev")
  support.write(directory <> "/app/extra/value.hrl", "-define(LOCAL, 2).\n")
  let assert Ok(changed) = stamp.snapshot(graph, "dev")
  assert first.key != changed.key
}
