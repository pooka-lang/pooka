//// Inspect the parcel before shelving it in the cache.
////
//// Use injected catalogs and local Hex archives to check backtracking, version
//// requirements, checksums and unpacking paths. Optional constraints from a
//// discarded candidate must disappear with it. Cached Erlang and Gleam
//// packages are then exercised without a network dependency.

import builder/build
import builder/clean
import builder/escript
import builder/shipment
import cli/cli as raw_cli
import cli/command
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import pooka
import project/config
import project/dependency as d
import project/hex
import project/lockfile
import project/package
import project/project.{type Project, Project}
import project/project_error
import project/semver
import simplifile
import support

@external(erlang, "shipment_test_ffi", "hex_archive")
fn archive(
  directory: String,
  files: List(#(String, BitArray)),
) -> #(BitArray, String)

fn root(directory: String, dependencies: List(d.Dependency)) -> Project {
  Project(
    directory,
    "app",
    "0.1.0",
    dependencies,
    [],
    d.LocalOrigin,
    d.Pooka,
    [],
    config.defaults(),
  )
}

fn candidate(
  name: String,
  version: String,
  deps: List(d.Dependency),
) -> Project {
  Project(
    "/cache/" <> name <> "-" <> version,
    name,
    version,
    deps,
    [],
    d.HexOrigin(string.repeat("0", 64)),
    d.Pooka,
    [],
    config.defaults(),
  )
}

fn requirement(name: String, version: String) -> d.Dependency {
  d.Hex(name, version, False)
}

// Trying a candidate may add optional constraints. When the solver backs out,
// those constraints must leave too, or a valid older selection appears
// impossible.
pub fn resolver_backtracks_without_leaking_discarded_optional_constraints_test() {
  let a2 =
    candidate("a", "2.0.0", [
      requirement("shared", ">= 2.0.0"),
      d.Hex("x", ">= 9.0.0", True),
    ])
  let a1 = candidate("a", "1.0.0", [requirement("shared", "< 2.0.0")])
  let b =
    candidate("b", "1.0.0", [
      requirement("shared", "< 2.0.0"),
      requirement("x", "== 1.0.0"),
    ])
  let catalog =
    dict.from_list([
      #("a", [a2, a1]),
      #("b", [b]),
      #("shared", [
        candidate("shared", "2.0.0", []),
        candidate("shared", "1.0.0", []),
      ]),
      #("x", [candidate("x", "1.0.0", [])]),
    ])
  let provider = fn(_root, _owner, dep, _pins, _update) {
    let assert d.Hex(name, range, _) = dep
    Ok(
      dict.get(catalog, name)
      |> result.unwrap([])
      |> list.filter(fn(p) {
        let assert Ok(v) = semver.parse(p.version)
        semver.satisfies(v, range)
      })
      |> list.map(fn(p) { fn() { Ok(p) } }),
    )
  }
  let assert Ok(graph) =
    package.solve(
      root("/workspace", [
        requirement("a", ">= 1.0.0"),
        requirement("b", "1.0.0"),
      ]),
      False,
      [],
      False,
      provider,
    )
  assert list.find(graph.packages, fn(p) { p.name == "a" }) == Ok(a1)
  assert list.find(graph.packages, fn(p) { p.name == "shared" })
    |> result.map(fn(p) { p.version })
    == Ok("1.0.0")
}

pub fn unused_optional_dependencies_are_not_selected_test() {
  let a = candidate("a", "1.0.0", [d.Hex("unused", "~> 1.0", True)])
  let provider = fn(_root, _owner, _dep, _pins, _update) {
    Ok([fn() { Ok(a) }])
  }
  let assert Ok(graph) =
    package.solve(
      root("/workspace", [requirement("a", "1.0.0")]),
      False,
      [],
      False,
      provider,
    )
  assert list.map(graph.packages, fn(p) { p.name }) == ["a", "app"]
}

pub fn semantic_versions_compare_numeric_prereleases_and_ignore_build_metadata_test() {
  let assert Ok(a) = semver.parse("1.2.3-alpha.2")
  let assert Ok(b) = semver.parse("1.2.3-alpha.10")
  assert semver.compare(a, b) == order.Lt
  let assert Ok(stable) = semver.parse("1.2.3+build.1")
  let assert Ok(other) = semver.parse("1.2.3+build.2")
  assert semver.compare(stable, other) == order.Eq
  assert semver.satisfies(stable, ">=1.0.0 and <2.0.0")
  assert !semver.satisfies(stable, "~> 1.1.0")
  assert semver.satisfies(stable, "~> 1.2")
  let assert Ok(later) = semver.parse("1.9.0")
  assert semver.satisfies(later, "~> 1.2+build.3")
  list.each(
    ["01.2.3", "-1.2.3", "1.2.3-01", "1.2.3-../../escape", "1.2.3+bad/metadata"],
    fn(v) {
      assert semver.parse(v) == Error(Nil)
    },
  )
  list.each(["", ">= nonsense", "~> ", "1.0.0 or"], fn(req) {
    assert !semver.valid_requirement(req)
  })
}

fn metadata(
  _name: String,
  app: String,
  tool: String,
  checksum: String,
) -> String {
  json.object([
    #("version", json.string("1.0.0")),
    #("checksum", json.string(checksum)),
    #("requirements", json.object([])),
    #(
      "meta",
      json.object([
        #("app", json.string(app)),
        #("build_tools", json.array([tool], json.string)),
      ]),
    ),
  ])
  |> json.to_string
}

fn prepare(
  directory: String,
  name: String,
  app: String,
  tool: String,
  files: List(#(String, String)),
) -> Project {
  let #(bytes, checksum) =
    archive(
      directory,
      list.map(files, fn(p) { #(p.0, bit_array.from_string(p.1)) }),
    )
  let app_root = directory <> "/app"
  support.write(
    app_root <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n[dependencies]\n"
      <> name
      <> " = \"== 1.0.0\"\n",
  )
  support.write(
    app_root <> "/src/main.pooka",
    "module main\nexternal Library from erlang \""
      <> name
      <> "\" { answer() -> Int }\nmain() { echo Library.answer() }\n",
  )
  let assert Ok(config) = project.load(app_root)
  let release = metadata(name, app, tool, checksum)
  let fetcher = fn(url) {
    case string.ends_with(url, ".tar"), string.contains(url, "/releases/") {
      True, _ -> Ok(bytes)
      _, True -> Ok(bit_array.from_string(release))
      _, _ ->
        Ok(bit_array.from_string("{\"releases\":[{\"version\":\"1.0.0\"}]}"))
    }
  }
  let assert Ok(graph) = package.resolve_using(config, True, False, fetcher)
  let assert Ok(Nil) = lockfile.write(graph.root, graph.packages)
  let assert Ok(selected) = list.find(graph.packages, fn(p) { p.name == name })
  selected
}

pub fn cached_hex_erlang_packages_build_offline_with_their_actual_otp_application_name_test() {
  use directory <- support.with_directory("hex_native_erlang")
  let selected =
    prepare(directory, "fixture", "actual_fixture", "rebar3", [
      #(
        "src/fixture.erl",
        "-module(fixture).\n-export([answer/0]).\nanswer() -> 42.\n",
      ),
      #(
        "src/actual_fixture.app.src",
        "{application,actual_fixture,[{vsn,\"1.0.0\"},{modules,[]},{registered,[]},{applications,[kernel,stdlib]}]}.\n",
      ),
    ])
  let env = command.plain(directory <> "/app")
  let result = support.cli_main(["run"], env)
  assert result.status == 0
  assert result.stdout == "42\n"
  assert string.contains(result.stderr, "Compiling fixture\n")
  assert string.contains(result.stderr, "Compiling app\n")
  assert simplifile.is_file(
      directory
      <> "/app/build/dev/erlang/actual_fixture/ebin/actual_fixture.app",
    )
    == Ok(True)
  assert support.cli_main(["export", "escript"], env).status == 0

  support.write(selected.root <> "/src/extra.erl", "malicious extra source")
  assert support.cli_main(["run"], env).status == 1
}

// Some native packages describe their application in a Makefile and publish
// the finished resource rather than an .app.src. Read the published resource in
// ebin/. Read it from the package, not from the build's own output folder.
pub fn cached_hex_erlang_mk_packages_use_their_published_application_resource_test() {
  use directory <- support.with_directory("hex_native_erlang_mk")
  let _selected =
    prepare(directory, "fixture", "fixture", "make", [
      #("Makefile", "PROJECT = fixture\n"),
      #(
        "src/fixture.erl",
        "-module(fixture).\n-export([answer/0]).\nanswer() -> 42.\n",
      ),
      #(
        "ebin/fixture.app",
        "{application,fixture,[{description,\"Made by erlang.mk\"},{vsn,\"1.0.0\"},{modules,[]},{registered,[]},{applications,[kernel,stdlib]}]}.\n",
      ),
    ])
  let env = command.plain(directory <> "/app")
  let result = support.cli_main(["run"], env)
  assert result.status == 0
  assert result.stdout == "42\n"
  let assert Ok(resource) =
    simplifile.read(
      directory <> "/app/build/dev/erlang/fixture/ebin/fixture.app",
    )
  assert string.contains(resource, "Made by erlang.mk")
  assert string.contains(resource, "{modules,[fixture]}")
}

pub fn cached_hex_gleam_packages_compile_without_network_or_source_mutation_test() {
  use directory <- support.with_directory("hex_native_gleam")
  let selected =
    prepare(directory, "fixture", "fixture", "gleam", [
      #("gleam.toml", "name = \"fixture\"\nversion = \"1.0.0\"\n"),
      #("src/fixture.gleam", "pub fn answer() { 42 }\n"),
    ])
  let env = command.plain(directory <> "/app")
  let result = support.cli_main(["run"], env)
  assert result.status == 0
  assert result.stdout == "42\n"
  assert support.cli_main(["run"], env).stdout == "42\n"
  assert simplifile.read(selected.root <> "/src/fixture.gleam")
    == Ok("pub fn answer() { 42 }\n")
}

// Verify the archive before exposing a cache directory. A damaged parcel must
// not look like a completed package to the next build.
pub fn checksum_mismatches_never_publish_a_hex_cache_test() {
  use directory <- support.with_directory("hex_checksum")
  let #(bytes, _checksum) =
    archive(directory, [#("src/fixture.erl", bit_array.from_string("source"))])
  let target = directory <> "/cache"
  assert result.is_error(hex.unpack(bytes, string.repeat("0", 64), target))
  assert simplifile.is_directory(target) == Ok(False)
}

pub fn malformed_release_data_does_not_silently_drop_requirements_test() {
  let r = root("/workspace", [])
  assert result.is_error(hex.release(
    r,
    "fixture",
    "1.0.0",
    "{\"checksum\":\"bad\"}",
  ))
  let valid = metadata("fixture", "fixture", "rebar3", string.repeat("0", 64))
  assert result.is_ok(hex.release(r, "fixture", "1.0.0", valid))
  assert result.is_error(hex.release(r, "fixture", "2.0.0", valid))
}

// An archive entry can ask to climb out of its destination. Reject the
// package before extraction gives that request access to a neighbouring path.
pub fn unsafe_archive_paths_never_escape_the_cache_test() {
  use directory <- support.with_directory("hex_unsafe_path")
  let #(bytes, checksum) =
    archive(directory, [#("../escaped", bit_array.from_string("bad"))])
  let target = directory <> "/cache/package"
  assert result.is_error(hex.unpack(bytes, checksum, target))
  assert simplifile.is_directory(target) == Ok(False)
  assert simplifile.is_file(directory <> "/cache/escaped") == Ok(False)
}

// A cached Hex library carries ordinary Pooka source. Every package gets its own
// helper when compiled, without requiring a second registry package.
pub fn published_pooka_packages_build_from_cache_without_runtime_dependencies_test() {
  use directory <- support.with_directory("hex_embedded_runtime_graph")
  let #(source, checksum) =
    archive(directory, [
      #(
        "pooka.toml",
        bit_array.from_string("name = \"fixture\"\nversion = \"1.0.0\"\n"),
      ),
      #(
        "src/fixture.pooka",
        bit_array.from_string("module fixture\nanswer() { 42 }"),
      ),
    ])
  let release = metadata("fixture", "fixture", "pooka", checksum)
  let app = directory <> "/app"
  support.write(
    app <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nfixture = \"1.0.0\"\n",
  )
  support.write(
    app <> "/src/main.pooka",
    "module main\nimport fixture\nmain() { echo fixture.answer() }",
  )
  let assert Ok(root) = project.load(app)
  let assert Ok(graph) =
    package.resolve_using(root, False, False, fn(url) {
      assert !string.contains(url, "pooka_runtime")
      case string.ends_with(url, ".tar"), string.contains(url, "/releases/") {
        True, _ -> Ok(source)
        _, True -> Ok(bit_array.from_string(release))
        _, _ ->
          Ok(bit_array.from_string("{\"releases\":[{\"version\":\"1.0.0\"}]}"))
      }
    })
  let assert Ok(Nil) = lockfile.write(root, graph.packages)
  let assert Ok(pins) = lockfile.read(root)
  assert !list.any(pins, fn(pin) { pin.name == "pooka_runtime" })
  let assert Ok(report) = build.build_production(app)
  assert support.execute(report.directory, "pooka@app@main", []) == Ok("42\n")
  assert simplifile.is_file(report.directory <> "/pooka@app@@runtime.beam")
    == Ok(True)
  assert simplifile.is_file(
      report.layout.target <> "/fixture/ebin/pooka@fixture@@runtime.beam",
    )
    == Ok(True)
  let assert Ok(again) = build.build_production(app)
  assert again.reused
}

pub fn cached_native_dependency_headers_preserve_unchanged_build_reuse_test() {
  use directory <- support.with_directory("hex_native_header_reuse")
  let _selected =
    prepare(directory, "fixture", "header_fixture", "rebar3", [
      #(
        "src/fixture.erl",
        "-module(fixture).\n-include_lib(\"header_fixture/include/constants.hrl\").\n-export([answer/0]).\nanswer() -> ?ANSWER.\n",
      ),
      #("include/constants.hrl", "-define(ANSWER, 42).\n"),
      #(
        "src/header_fixture.app.src",
        "{application,header_fixture,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
      ),
    ])
  let assert Ok(first) = build.build(directory <> "/app")
  assert !first.reused
  let assert Ok(second) = build.build(directory <> "/app")
  assert second.reused
  assert second.compiled_packages == []
  assert second.compiled_foreign == []
  support.write(
    directory <> "/app/src/extra.pooka",
    "module extra\nanswer() { 7 }\n",
  )
  let assert Ok(changed) = build.build(directory <> "/app")
  assert !changed.reused
  assert !list.contains(changed.compiled_packages, "fixture")
  assert changed.compiled_foreign == []
  assert support.cli_main(["run"], command.plain(directory <> "/app")).stdout
    == "42\n"
}

pub fn native_hex_artifacts_survive_clean_but_invalidate_on_compiler_options_test() {
  use directory <- support.with_directory("hex_retained_native")
  let selected =
    prepare(directory, "fixture", "fixture", "rebar3", [
      #(
        "src/fixture.erl",
        "-module(fixture).\n-export([answer/0]).\nanswer() -> 42.\n",
      ),
      #(
        "src/fixture.app.src",
        "{application,fixture,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
      ),
    ])
  let app = directory <> "/app"
  let assert Ok(first) = build.build(app)
  assert list.contains(first.compiled_packages, "fixture")
  let assert Ok(archive) =
    simplifile.read_bits(selected.root <> "/.pooka-hex.tar")
  let assert Ok(config) = project.load(app)
  let restore_sources = fn() {
    let assert Ok(Nil) = clean.clean_project(app)
    let assert Ok(_) = hex.materialize(config, selected, fn(_) { Ok(archive) })
    Nil
  }
  restore_sources()
  let assert Ok(reused) = build.build(app)
  assert !reused.reused
  assert !list.contains(reused.compiled_packages, "fixture")
  assert support.cli_main(["run"], command.plain(app)).stdout == "42\n"
  restore_sources()
  with_environment("ERL_COMPILER_OPTIONS", "[debug_info]", fn() {
    let assert Ok(changed) = build.build(app)
    assert list.contains(changed.compiled_packages, "fixture")
  })
}

pub fn native_batches_keep_options_and_compile_modules_beyond_the_first_batch_test() {
  use directory <- support.with_directory("hex native batches")
  let extras =
    list.index_map(list.repeat(Nil, 64), fn(_, n) {
      let name = "batch_extra_" <> int.to_string(n)
      #(
        "src/" <> name <> ".erl",
        "-module("
          <> name
          <> ").\n-include(\"offset.hrl\").\n-export([answer/0]).\nanswer() -> ?BASE + ?OFFSET.\n",
      )
    })
  let _ =
    prepare(
      directory,
      "fixture",
      "fixture",
      "rebar3",
      list.append(
        [
          #(
            "rebar.config",
            "{erl_opts,[{i,\"extra_headers\"},{d,'BASE',20}]}.\n",
          ),
          #("extra_headers/offset.hrl", "-define(OFFSET, 22).\n"),
          #(
            "src/fixture.erl",
            "-module(fixture).\n-export([answer/0]).\nanswer() -> batch_extra_63:answer().\n",
          ),
          #(
            "src/fixture.app.src",
            "{application,fixture,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
          ),
        ],
        extras,
      ),
    )
  let assert Ok(built) = build.build(directory <> "/app")
  assert list.length(built.compiled_foreign) == 65
  assert support.cli_main(["run"], command.plain(directory <> "/app")).stdout
    == "42\n"
}

pub fn native_batches_keep_first_files_available_as_parse_transforms_test() {
  use directory <- support.with_directory("hex_native_first_transform")
  let fillers =
    list.index_map(list.repeat(Nil, 33), fn(_, n) {
      let name = "a_filler_" <> int.to_string(n)
      #(
        "src/" <> name <> ".erl",
        "-module(" <> name <> ").\n-export([answer/0]).\nanswer() -> 1.\n",
      )
    })
  let _ =
    prepare(
      directory,
      "fixture",
      "fixture",
      "rebar3",
      list.append(
        [
          #(
            "rebar.config",
            "{erl_first_files,[\"src/z_fixture_transform.erl\"]}.\n",
          ),
          #(
            "src/z_fixture_transform.erl",
            "-module(z_fixture_transform).\n-export([parse_transform/2]).\nparse_transform(Forms, _) -> lists:map(fun rewrite/1, Forms).\nrewrite({function,L,answer,0,_}) -> {function,L,answer,0,[{clause,L,[],[],[{integer,L,42}]}]};\nrewrite(Form) -> Form.\n",
          ),
          #(
            "src/fixture.erl",
            "-module(fixture).\n-compile({parse_transform,z_fixture_transform}).\n-export([answer/0]).\nanswer() -> 1.\n",
          ),
          #(
            "src/fixture.app.src",
            "{application,fixture,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
          ),
        ],
        fillers,
      ),
    )
  let report = support.cli_main(["run"], command.plain(directory <> "/app"))
  assert report.status == 0
  assert report.stdout == "42\n"
}

pub fn native_batch_failures_keep_the_source_diagnostic_test() {
  use directory <- support.with_directory("hex_native_batch_error")
  let fillers =
    list.index_map(list.repeat(Nil, 33), fn(_, n) {
      let name = "a_filler_" <> int.to_string(n)
      #(
        "src/" <> name <> ".erl",
        "-module(" <> name <> ").\n-export([answer/0]).\nanswer() -> 1.\n",
      )
    })
  let _ =
    prepare(
      directory,
      "fixture",
      "fixture",
      "rebar3",
      list.append(
        [
          #(
            "src/fixture.erl",
            "-module(fixture).\n-export([answer/0]).\nanswer() -> 42.\n",
          ),
          #("src/zz_broken.erl", "-module(zz_broken).\nanswer() -> .\n"),
          #(
            "src/fixture.app.src",
            "{application,fixture,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
          ),
        ],
        fillers,
      ),
    )
  let report = support.cli_main(["build"], command.plain(directory <> "/app"))
  assert report.status == 1
  assert string.contains(report.stderr, "zz_broken.erl")
  assert string.contains(report.stderr, "syntax error")
}

pub fn published_resources_use_the_application_name_from_package_metadata_test() {
  use directory <- support.with_directory("hex_published_resource_identity")
  let _ =
    prepare(directory, "fixture", "published_fixture", "make", [
      #(
        "src/fixture.erl",
        "-module(fixture).\n-export([answer/0]).\nanswer() -> 42.\n",
      ),
      #(
        "ebin/published_fixture.app",
        "{application,published_fixture,[{vsn,\"1.0.0\"},{description,\"Published resource\"},{modules,[old_module]},{applications,[kernel,stdlib]}]}.\n",
      ),
    ])
  let report = support.cli_main(["run"], command.plain(directory <> "/app"))
  assert report.status == 0
  assert report.stdout == "42\n"
  let assert Ok(resource) =
    simplifile.read(
      directory
      <> "/app/build/dev/erlang/published_fixture/ebin/published_fixture.app",
    )
  assert string.contains(resource, "Published resource")
  assert string.contains(resource, "{modules,[fixture]}")
  assert !string.contains(resource, "old_module")
}

pub fn generated_resources_take_precedence_over_published_resources_test() {
  use directory <- support.with_directory("hex_generated_resource_first")
  let _ =
    prepare(directory, "fixture", "fixture", "gleam", [
      #("gleam.toml", "name = \"fixture\"\nversion = \"1.0.0\"\n"),
      #("src/fixture.gleam", "pub fn answer() { 42 }\n"),
      #("ebin/fixture.app", "not_an_application.\n"),
    ])
  let report = support.cli_main(["run"], command.plain(directory <> "/app"))
  assert report.status == 0
  assert report.stdout == "42\n"
}

fn rejected_published_resource(
  name: String,
  files: List(#(String, String)),
  message: String,
) {
  use directory <- support.with_directory(name)
  let _ =
    prepare(directory, "fixture", "fixture", "make", [
      #(
        "src/fixture.erl",
        "-module(fixture).\n-export([answer/0]).\nanswer() -> 42.\n",
      ),
      ..files
    ])
  let report = support.cli_main(["build"], command.plain(directory <> "/app"))
  assert report.status == 1
  assert string.contains(report.stderr, message)
}

pub fn missing_published_resources_have_a_clear_error_test() {
  rejected_published_resource(
    "hex_published_missing",
    [],
    "Native package application resource is missing",
  )
}

pub fn malformed_published_resources_keep_their_own_diagnostic_test() {
  rejected_published_resource(
    "hex_published_malformed",
    [#("ebin/fixture.app", "{not a valid term\n")],
    "Invalid native application resource",
  )
}

pub fn published_resources_cannot_declare_another_application_test() {
  rejected_published_resource(
    "hex_published_wrong_identity",
    [#("ebin/fixture.app", "{application,other,[{vsn,\"1.0.0\"}]}.\n")],
    "declares other; expected fixture",
  )
}

pub fn published_resource_properties_must_be_a_list_test() {
  rejected_published_resource(
    "hex_published_bad_properties",
    [#("ebin/fixture.app", "{application,fixture,not_a_list}.\n")],
    "Invalid native application resource",
  )
}

@external(erlang, "ffi_test_ffi", "has_executable")
fn has_executable(name: String) -> Bool

@external(erlang, "shipment_test_ffi", "run_escript")
fn execute_escript(
  path: String,
  arguments: List(String),
  directory: String,
) -> #(Int, String)

// Put the macro after its caller alphabetically. Mix must establish compile-time
// order, and its generated application resource must keep runtime dependencies.
pub fn cached_hex_elixir_packages_build_without_mutating_sources_test() {
  use directory <- support.with_directory("hex_native_elixir")
  let selected =
    prepare(directory, "fixture", "fixture", "mix", [
      #(
        "mix.exs",
        "defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :fixture, version: \"1.0.0\", deps: []]\n  def application, do: [extra_applications: [:logger]]\nend\n",
      ),
      #(
        "lib/a_fixture.ex",
        "defmodule Fixture do\n  require Fixture.Definition\n  Fixture.Definition.answer()\nend\n",
      ),
      #(
        "lib/z_definition.ex",
        "defmodule Fixture.Definition do\n  defmacro answer do\n    quote do\n      def answer(), do: String.length(\"forty-two\") + 33\n    end\n  end\nend\n",
      ),
      #("priv/message.txt", "a private runtime resource"),
    ])
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nexternal Library from elixir \"Fixture\" { answer() -> Int }\nmain() { echo Library.answer() }\n",
  )
  let env = command.plain(directory <> "/app")
  let first = support.cli_main(["run"], env)
  case has_executable("elixir") && has_executable("mix") {
    False -> {
      assert first.status == 1
      assert string.contains(
        first.stderr,
        "fixture is an Elixir package; install Elixir to use it",
      )
    }
    True -> {
      assert first.status == 0
      assert first.stdout == "42\n"
      assert support.cli_main(["run"], env).stdout == "42\n"
      let assert Ok(repeated) = build.build(directory <> "/app")
      assert repeated.reused
      support.write(
        directory <> "/app/src/main.pooka",
        "module main\nexternal Library from elixir \"Fixture\" { answer() -> Int }\nmain() { echo Library.answer() + 1 }\n",
      )
      let assert Ok(changed) = build.build(directory <> "/app")
      assert changed.compiled_foreign == []
      support.write(
        directory <> "/app/src/main.pooka",
        "module main\nexternal Library from elixir \"Fixture\" { answer() -> Int }\nmain() { echo Library.answer() }\n",
      )
      assert simplifile.is_directory(selected.root <> "/_build") == Ok(False)
      assert simplifile.is_directory(selected.root <> "/deps") == Ok(False)
      let assert Ok(resource) =
        simplifile.read(
          directory <> "/app/build/dev/erlang/fixture/ebin/fixture.app",
        )
      assert string.contains(resource, "elixir")
      assert string.contains(resource, "logger")
      let assert Ok(exported) = escript.export(directory <> "/app")
      let executed = execute_escript(exported.path, [], directory)
      assert executed == #(0, "src/main.pooka:3\n42\n")
      let assert Ok(shipped) = shipment.export(directory <> "/app")
      assert simplifile.read(shipped.directory <> "/fixture/priv/message.txt")
        == Ok("a private runtime resource")
      assert simplifile.is_file(shipped.directory <> "/elixir/ebin/elixir.app")
        == Ok(True)
    }
  }
}

pub fn elixir_hex_packages_use_the_already_built_dependency_graph_test() {
  case has_executable("elixir") && has_executable("mix") {
    False -> Nil
    True -> {
      use directory <- support.with_directory("hex_elixir_dependency_order")
      use <- with_environment("MIX_HOME", directory <> "/empty-mix-home")
      use <- with_environment("HEX_HOME", directory <> "/empty-hex-home")
      let #(helper_bytes, helper_sum) =
        archive(directory, [
          #(
            "src/helper.erl",
            bit_array.from_string(
              "-module(helper).\n-export([answer/0]).\nanswer() -> 42.\n",
            ),
          ),
          #(
            "src/helper.app.src",
            bit_array.from_string(
              "{application,helper,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
            ),
          ),
        ])
      let #(fixture_bytes, fixture_sum) =
        archive(directory, [
          #(
            "mix.exs",
            bit_array.from_string(
              "defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :fixture, version: \"1.0.0\", deps: [{:helper, \"== 1.0.0\"}]]\nend\n",
            ),
          ),
          #(
            "lib/fixture.ex",
            bit_array.from_string(
              "defmodule Fixture do\n  @answer :helper.answer()\n  def answer(), do: @answer\nend\n",
            ),
          ),
        ])
      let app = directory <> "/app"
      support.write(
        app <> "/pooka.toml",
        "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nfixture = \"== 1.0.0\"\n",
      )
      support.write(
        app <> "/src/main.pooka",
        "module main\nexternal Library from elixir \"Fixture\" { answer() -> Int }\nmain() { echo Library.answer() }\n",
      )
      let helper_meta = metadata("helper", "helper", "rebar3", helper_sum)
      let fixture_meta =
        metadata("fixture", "fixture", "mix", fixture_sum)
        |> string.replace(
          "\"requirements\":{}",
          "\"requirements\":{\"helper\":{\"app\":\"helper\",\"requirement\":\"== 1.0.0\",\"optional\":false}}",
        )
      let fetch = fn(url) {
        let helper = string.contains(url, "helper")
        case string.ends_with(url, ".tar"), string.contains(url, "/releases/") {
          True, _ ->
            Ok(case helper {
              True -> helper_bytes
              False -> fixture_bytes
            })
          _, True ->
            Ok(
              bit_array.from_string(case helper {
                True -> helper_meta
                False -> fixture_meta
              }),
            )
          _, _ ->
            Ok(bit_array.from_string("{\"releases\":[{\"version\":\"1.0.0\"}]}"))
        }
      }
      let assert Ok(loaded) = project.load(app)
      let assert Ok(graph) = package.resolve_using(loaded, True, False, fetch)
      let assert Ok(Nil) = lockfile.write(graph.root, graph.packages)
      let run = support.cli_main(["run"], command.plain(app))
      assert run.status == 0
      assert run.stdout == "42\n"
      let assert Ok(reused) = build.build(app)
      assert reused.reused
    }
  }
}

@external(erlang, "incremental_test_ffi", "with_environment")
fn with_environment(name: String, value: String, run: fn() -> a) -> a

pub fn cached_hex_pooka_locations_keep_the_package_source_name_test() {
  use directory <- support.with_directory("hex_pooka_source_locations")
  let _ =
    prepare(directory, "tool", "tool", "pooka", [
      #("pooka.toml", "name = \"tool\"\nversion = \"1.0.0\"\n"),
      #(
        "src/tool.pooka",
        "module tool\ngreeting() { echo \"hello\" }\nexplode() { panic as \"boom\" }\n",
      ),
      #(
        "src/main.pooka",
        "module main\nimport tool\nmain() { tool.greeting() }\n",
      ),
    ])
  let app = directory <> "/app"
  support.write(
    app <> "/src/main.pooka",
    "module main\nimport tool\nmain() { tool.greeting() }\n",
  )
  let env = command.plain(app)
  list.each([["run"], ["run", "-m", "tool"]], fn(args) {
    let report = raw_cli.main(args, pooka.version, env)
    assert report.status == 0
    assert string.contains(
      report.stdout <> report.stderr,
      "tool: src/tool.pooka:2",
    )
    assert !string.contains(report.stdout <> report.stderr, "$package")
  })
  support.write(
    app <> "/src/main.pooka",
    "module main\nimport tool\nmain() { tool.explode() }\n",
  )
  let failure = support.cli_main(["run"], env)
  assert failure.status == 1
  assert string.contains(failure.stderr, "tool: src/tool.pooka:3")
  assert !string.contains(failure.stderr, "$package")
}

// The root's source wins whether the child or shared library is visited first.
// No registry request should be made for a package explicitly supplied locally.
fn source_fixture(directory: String, source: String, dev: Bool) -> Project {
  support.write(
    directory <> "/shared/pooka.toml",
    "name = \"shared\"\nversion = \"1.2.0\"\n",
  )
  support.write(
    directory <> "/child/pooka.toml",
    "name = \"child\"\nversion = \"1.0.0\"\n[dependencies]\nshared = \">= 1.0.0 and < 2.0.0\"\n",
  )
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nchild = { path = \"../child\" }\n"
      <> case dev {
      True -> "[dev-dependencies]\n"
      False -> ""
    }
      <> "shared = "
      <> source
      <> "\n",
  )
  let assert Ok(root) = project.load(directory <> "/app")
  root
}

fn no_registry(_url: String) -> Result(BitArray, String) {
  panic as "the root source should replace registry lookup"
}

pub fn root_path_satisfies_hex_requirements_in_both_orders_test() {
  use directory <- support.with_directory("root_path_hex")
  let root = source_fixture(directory, "{ path = \"../shared\" }", False)
  list.each([root.dependencies, list.reverse(root.dependencies)], fn(deps) {
    let assert Ok(graph) =
      package.resolve_using(
        Project(..root, dependencies: deps),
        False,
        False,
        no_registry,
      )
    assert list.map(graph.packages, fn(p) { p.name })
      == ["shared", "child", "app"]
    let assert Ok(shared) =
      list.find(graph.packages, fn(p) { p.name == "shared" })
    assert shared.origin == d.LocalOrigin
    assert shared.version == "1.2.0"
    let assert Ok(Nil) = lockfile.write(root, graph.packages)
    assert result.is_ok(package.resolve_using(root, False, False, no_registry))
  })
}

pub fn root_path_still_checks_transitive_hex_versions_test() {
  use directory <- support.with_directory("root_path_hex_version")
  let root = source_fixture(directory, "{ path = \"../shared\" }", False)
  support.write(
    directory <> "/shared/pooka.toml",
    "name = \"shared\"\nversion = \"2.0.0\"\n",
  )
  let assert Error(error) =
    package.resolve_using(root, False, False, no_registry)
  let assert project_error.DependencyProblem(_, detail) = error
  assert string.contains(detail, "2.0.0 does not satisfy >= 1.0.0 and < 2.0.0")
}

pub fn root_dev_sources_apply_only_when_dev_dependencies_are_enabled_test() {
  use directory <- support.with_directory("root_dev_source")
  let root = source_fixture(directory, "{ path = \"../shared\" }", True)
  assert result.is_ok(package.resolve_using(root, True, False, no_registry))
  let assert Error(_) =
    package.resolve_using(root, False, False, fn(_) {
      Error("registry unavailable")
    })
}

pub fn transitive_path_sources_cannot_replace_hex_requirements_test() {
  use directory <- support.with_directory("transitive_source_conflict")
  let root = source_fixture(directory, "{ path = \"../shared\" }", False)
  support.write(
    directory <> "/bridge/pooka.toml",
    "name = \"bridge\"\nversion = \"1.0.0\"\n[dependencies]\nshared = { path = \"../shared\" }\n",
  )
  let root =
    Project(..root, dependencies: [
      d.Local("bridge", "../bridge"),
      d.Local("child", "../child"),
    ])
  let assert Error(project_error.DependencyProblem(_, detail)) =
    package.resolve_using(root, False, False, no_registry)
  assert string.contains(detail, "Conflicting sources for Hex package `shared`")
}

@external(erlang, "shipment_test_ffi", "git")
fn source_git(directory: String, args: List(String)) -> #(Int, String)

pub fn root_git_source_keeps_revision_pins_with_transitive_hex_requests_test() {
  use directory <- support.with_directory("root_git_hex")
  let root =
    source_fixture(
      directory,
      "{ git = \"../shared\", branch = \"main\" }",
      False,
    )
  let repository = directory <> "/shared"
  list.each(
    [
      ["init", "-q", "-b", "main"],
      ["add", "."],
      [
        "-c",
        "user.name=Pooka Test",
        "-c",
        "user.email=tests@example.invalid",
        "commit",
        "-qm",
        "fixture",
      ],
    ],
    fn(args) {
      let assert #(0, _) = source_git(repository, args)
    },
  )
  let assert Ok(graph) = package.resolve_using(root, False, False, no_registry)
  let assert Ok(shared) =
    list.find(graph.packages, fn(p) { p.name == "shared" })
  let assert d.GitOrigin(_, "branch:main", revision) = shared.origin
  assert string.length(revision) == 40
  let assert Ok(Nil) = lockfile.write(root, graph.packages)
  let assert Ok(again) = package.resolve_using(root, False, False, no_registry)
  assert list.find(again.packages, fn(p) { p.name == "shared" }) == Ok(shared)
}

pub fn published_hex_packages_accept_the_roots_local_source_test() {
  use directory <- support.with_directory("hex_child_root_source")
  let loaded = source_fixture(directory, "{ path = \"../shared\" }", False)
  let root =
    Project(..loaded, dependencies: [
      requirement("child", "1.0.0"),
      d.Local("shared", "../shared"),
    ])
  let #(bytes, checksum) =
    archive(directory, [
      #(
        "pooka.toml",
        bit_array.from_string(
          "name = \"child\"\nversion = \"1.0.0\"\n[dependencies]\nshared = \">= 1.0.0 and < 2.0.0\"\n",
        ),
      ),
    ])
  let release =
    metadata("child", "child", "pooka", checksum)
    |> string.replace(
      "\"requirements\":{}",
      "\"requirements\":{\"shared\":{\"app\":\"shared\",\"requirement\":\">= 1.0.0 and < 2.0.0\",\"optional\":false}}",
    )
  let fetch = fn(url) {
    assert !string.contains(url, "shared")
    case string.ends_with(url, ".tar"), string.contains(url, "/releases/") {
      True, _ -> Ok(bytes)
      _, True -> Ok(bit_array.from_string(release))
      _, _ ->
        Ok(bit_array.from_string("{\"releases\":[{\"version\":\"1.0.0\"}]}"))
    }
  }
  let assert Ok(graph) = package.resolve_using(root, False, False, fetch)
  let assert Ok(child) = list.find(graph.packages, fn(p) { p.name == "child" })
  let assert d.HexOrigin(_) = child.origin
  let assert Ok(shared) =
    list.find(graph.packages, fn(p) { p.name == "shared" })
  assert shared.origin == d.LocalOrigin
}

pub fn optional_hex_constraints_are_checked_against_root_sources_test() {
  use directory <- support.with_directory("optional_root_source")
  let root = source_fixture(directory, "{ path = \"../shared\" }", False)
  support.write(
    directory <> "/child/pooka.toml",
    "name = \"child\"\nversion = \"1.0.0\"\n[dependencies]\nshared = { version = \">= 2.0.0\", optional = true }\n",
  )
  list.each([root.dependencies, list.reverse(root.dependencies)], fn(deps) {
    let assert Error(project_error.DependencyProblem(_, detail)) =
      package.resolve_using(
        Project(..root, dependencies: deps),
        False,
        False,
        no_registry,
      )
    assert string.contains(detail, "1.2.0 does not satisfy >= 2.0.0")
  })
}
