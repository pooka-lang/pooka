//// A package cache must outlive the staging directory that first built it.
//// These parcels contain real Erlang sources and compile without a registry.

import builder/build
import cli/command
import gleam/bit_array
import gleam/json
import gleam/list
import gleam/string
import project/lockfile
import project/package
import project/project
import simplifile
import support

@external(erlang, "shipment_test_ffi", "hex_archive")
fn archive(
  directory: String,
  files: List(#(String, BitArray)),
) -> #(BitArray, String)

fn release(
  app: String,
  checksum: String,
  requirements: List(#(String, json.Json)),
) -> String {
  json.object([
    #("version", json.string("1.0.0")),
    #("checksum", json.string(checksum)),
    #("requirements", json.object(requirements)),
    #(
      "meta",
      json.object([
        #("app", json.string(app)),
        #("build_tools", json.array(["rebar3"], json.string)),
      ]),
    ),
  ])
  |> json.to_string
}

fn fixture(directory: String) {
  support.write(directory <> "/producer_archive/keep", "")
  support.write(directory <> "/consumer_archive/keep", "")
  support.write(directory <> "/outside/resource.txt", "first")
  let #(producer, producer_checksum) =
    archive(directory <> "/producer_archive", [
      #(
        "src/header_provider.erl",
        bit_array.from_string(
          "-module(header_provider).\n-export([answer/0]).\nanswer() -> 42.\n",
        ),
      ),
      #(
        "include/constants.hrl",
        bit_array.from_string("-define(ANSWER, 42).\n"),
      ),
      #(
        "src/header_provider.app.src",
        bit_array.from_string(
          "{application,header_provider,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib]}]}.\n",
        ),
      ),
    ])
  let #(consumer, consumer_checksum) =
    archive(directory <> "/consumer_archive", [
      #(
        "src/header_consumer.erl",
        bit_array.from_string(
          "-module(header_consumer).\n-include_lib(\"header_provider/include/constants.hrl\").\n-include_lib(\"header_consumer/include/local.hrl\").\n-external_resource(\""
          <> directory
          <> "/outside/resource.txt\").\n-export([answer/0]).\nanswer() -> ?ANSWER + ?OFFSET.\n",
        ),
      ),
      #("include/local.hrl", bit_array.from_string("-define(OFFSET, 0).\n")),
      #(
        "src/header_consumer.app.src",
        bit_array.from_string(
          "{application,header_consumer,[{vsn,\"1.0.0\"},{modules,[]},{applications,[kernel,stdlib,header_provider]}]}.\n",
        ),
      ),
    ])
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n[dependencies]\nconsumer = \"== 1.0.0\"\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nexternal Consumer from erlang \"header_consumer\" { answer() -> Int }\nmain() { echo Consumer.answer() }\n",
  )
  let producer_release = release("header_provider", producer_checksum, [])
  let consumer_release =
    release("header_consumer", consumer_checksum, [
      #(
        "producer",
        json.object([
          #("requirement", json.string("== 1.0.0")),
          #("optional", json.bool(False)),
          #("app", json.string("header_provider")),
        ]),
      ),
    ])
  let assert Ok(config) = project.load(directory <> "/app")
  let assert Ok(graph) =
    package.resolve_using(config, True, False, fn(url) {
      case
        string.contains(url, "producer"),
        string.ends_with(url, ".tar"),
        string.contains(url, "/releases/")
      {
        True, True, _ -> Ok(producer)
        False, True, _ -> Ok(consumer)
        True, False, True -> Ok(bit_array.from_string(producer_release))
        False, False, True -> Ok(bit_array.from_string(consumer_release))
        _, _, _ ->
          Ok(bit_array.from_string("{\"releases\":[{\"version\":\"1.0.0\"}]}"))
      }
    })
  let assert Ok(Nil) = lockfile.write(graph.root, graph.packages)
  Nil
}

pub fn application_edits_reuse_native_consumers_across_fresh_staging_directories_test() {
  use directory <- support.with_directory("native_header_relocation")
  fixture(directory)
  let root = directory <> "/app"
  let assert Ok(first) = build.build(root)
  assert list.contains(first.compiled_foreign, "header_consumer")
  support.write(root <> "/src/extra.pooka", "module extra\nanswer() { 7 }\n")
  let assert Ok(changed) = build.build(root)
  assert !changed.reused
  assert changed.compiled_foreign == []
  assert !list.contains(changed.compiled_packages, "consumer")
  assert support.cli_main(["run"], command.plain(root)).stdout == "42\n"
}

@external(erlang, "shipment_test_ffi", "run_cli")
fn run_cli(arguments: List(String), directory: String) -> #(Int, String)

pub fn native_header_caches_survive_fresh_compiler_processes_test() {
  use directory <- support.with_directory("native_header_fresh_vm")
  fixture(directory)
  let root = directory <> "/app"
  let first = run_cli(["build"], root)
  assert first.0 == 0
  support.write(root <> "/src/extra.pooka", "module extra\nanswer() { 7 }\n")
  let second = run_cli(["build"], root)
  assert second.0 == 0
  assert !string.contains(second.1, "Compiling producer")
  assert !string.contains(second.1, "Compiling consumer")
  let assert Ok(Nil) = simplifile.delete_file(root <> "/src/extra.pooka")
  let third = run_cli(["build"], root)
  assert third.0 == 0
  assert !string.contains(third.1, "Compiling consumer")
}

pub fn external_resources_still_invalidate_relocated_native_caches_test() {
  use directory <- support.with_directory("native_header_resource")
  fixture(directory)
  let root = directory <> "/app"
  let assert Ok(_) = build.build(root)
  support.write(directory <> "/outside/resource.txt", "changed")
  let assert Ok(changed) = build.build(root)
  assert list.contains(changed.compiled_foreign, "header_consumer")
  assert !list.contains(changed.compiled_foreign, "header_provider")
  support.write(root <> "/src/extra.pooka", "module extra\nanswer() { 7 }\n")
  let assert Ok(reused) = build.build(root)
  assert reused.compiled_foreign == []
}

pub fn corrupt_native_cache_rebuilds_then_becomes_reusable_test() {
  use directory <- support.with_directory("native_header_corrupt")
  fixture(directory)
  let root = directory <> "/app"
  let assert Ok(_) = build.build(root)
  support.write(
    root <> "/build/dev/erlang/header_consumer/_pooka_artefacts/native.cache",
    "broken",
  )
  support.write(root <> "/src/extra.pooka", "module extra\nanswer() { 7 }\n")
  let assert Ok(repaired) = build.build(root)
  assert list.contains(repaired.compiled_foreign, "header_consumer")
  assert !list.contains(repaired.compiled_foreign, "header_provider")
  support.write(root <> "/src/extra.pooka", "module extra\nanswer() { 8 }\n")
  let assert Ok(reused) = build.build(root)
  assert reused.compiled_foreign == []
}
