//// Inspect the parcel before shelving it in the cache.
////
//// Use injected catalogs and local Hex archives to check backtracking, version
//// requirements, checksums and unpacking paths. Optional constraints from a
//// discarded candidate must disappear with it. Cached Erlang and Gleam
//// packages are then exercised without a network dependency.

import builder/build
import cli/command
import gleam/bit_array
import gleam/dict
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import project/config
import project/dependency as d
import project/hex
import project/lockfile
import project/package
import project/project.{type Project, Project}
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
