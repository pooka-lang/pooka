//// At a foreign door, write down the shape of the reply.
////
//// Check external namespaces, mandatory boundary signatures and generated
//// calls. Runtime fixtures cross into Erlang and other available BEAM tools;
//// executable checks guard platform-dependent cases. A namespace is a
//// qualifier, not an ordinary value to construct or pass around.

import builder/build
import builder/foreign
import cli/command
import compiler/analysis/resolve
import compiler/compiler
import compiler/foreign_language
import compiler/parser/ast
import gleam/list
import gleam/string
import simplifile
import support

fn ids(source: String) -> List(String) {
  resolve.check(support.parse("module main\n" <> source), support.path)
  |> list.map(fn(value) { value.id })
}

const math =
  "external Math from erlang \"math_helpers\" {\n  double(value: Int) -> Int\n}\n"

@external(erlang, "ffi_test_ffi", "has_executable")
fn has_executable(name: String) -> Bool

// The namespace binds foreign function names without turning into an ordinary
// object. Resolution must preserve the declared target and signature.
pub fn namespace_functions_resolve_test() {
  assert ids(math <> "main() { echo { Math.double(1) } }") == []

  assert ids(math <> "main() { echo { let f = Math.double\nf(1) } }") == []
}

pub fn unknown_namespace_functions_are_reported_test() {
  assert ids(math <> "main() { echo { Math.tripple(1) } }")
    == ["analysis.unknown_external_function"]
}

pub fn unknown_namespace_function_suggestion_test() {
  let diagnostics =
    resolve.check(
      support.parse(
        "module main\n" <> math <> "main() { echo { Math.doubel(1) } }",
      ),
      support.path,
    )
  let assert [diagnostic] = diagnostics
  assert diagnostic.suggestions == ["Did you mean `Math.double`?"]
}

pub fn a_namespace_is_not_a_value_test() {
  assert ids(math <> "main() { echo { Math } }")
    == ["analysis.external_namespace_value"]
  assert ids(math <> "main() { echo { let m = Math\nm } }")
    == ["analysis.external_namespace_value"]
}

pub fn a_namespace_cannot_be_instantiated_test() {
  assert ids(math <> "main() { echo { Math(1) } }")
    == ["analysis.external_namespace_construction"]
}

pub fn a_namespace_is_not_a_type_test() {
  assert ids(math <> "f(value: Math) { value }")
    == ["analysis.external_namespace_type"]
  assert ids(math <> "f() -> List(Math) { [] }")
    == ["analysis.external_namespace_type"]
}

pub fn a_namespace_cannot_be_matched_test() {
  assert ids(math <> "f(value) { match value { Math -> 1\n_ -> 2 } }")
    == ["analysis.external_namespace_pattern"]
}

pub fn a_namespace_cannot_be_inherited_from_test() {
  assert support.diagnostic_ids(
      "module main\n" <> math <> "class Calculator is Math {}",
    )
    == ["analysis.invalid_superclass"]
}

pub fn a_namespace_is_a_used_declaration_test() {
  let ids =
    support.diagnostic_ids(
      "module main\nexternal _Native from erlang \"native\" { read() -> Int }\nmain() { echo { _Native.read() } }",
    )
  assert !list.contains(ids, "analysis.unused_private_declaration")
}

pub fn foreign_module_names_test() {
  assert foreign_language.beam_module(ast.Erlang, "crypto") == "crypto"
  assert foreign_language.beam_module(ast.Elixir, "Formatter")
    == "Elixir.Formatter"
  assert foreign_language.beam_module(ast.Gleam, "text/style") == "text@style"
  assert foreign_language.beam_module(ast.Lfe, "lfe_helpers") == "lfe_helpers"
}

fn project(directory: String, main: String) -> Nil {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> main)
}

fn run(directory: String) -> command.Outcome {
  support.cli_main(["run"], command.plain(directory))
}

pub fn erlang_ffi_source_executes_test() {
  use directory <- support.with_directory("ffi_erlang")
  project(directory, math <> "main() { echo { Math.double(21) } }")
  support.write(
    directory <> "/ffi/math_helpers.erl",
    "-module(math_helpers).\n-export([double/1]).\ndouble(V) -> V * 2.\n",
  )
  let outcome = run(directory)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "42\n"
}

pub fn otp_modules_need_no_ffi_source_test() {
  use directory <- support.with_directory("ffi_otp")
  project(
    directory,
    "external Lists from erlang \"lists\" {\n  reverse(items: List(a)) -> List(a)\n}\nmain() { echo { Lists.reverse([1, 2, 3]) } }",
  )
  let outcome = run(directory)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "[3, 2, 1]\n"
}

pub fn first_class_foreign_functions_execute_test() {
  use directory <- support.with_directory("ffi_first_class")
  project(
    directory,
    "external Lists from erlang \"lists\" {\n  reverse(items: List(a)) -> List(a)\n}\napply(f, value) { f(value) }\nmain() { echo { apply(Lists.reverse, [1, 2]) } }",
  )
  let outcome = run(directory)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "[2, 1]\n"
}

pub fn imported_namespaces_execute_test() {
  use directory <- support.with_directory("ffi_imported")
  project(
    directory,
    "import native.{Lists}\nimport native as n\nmain() { echo { #(Lists.reverse([1, 2]), n.Lists.reverse([3, 4])) } }",
  )
  support.write(
    directory <> "/src/native.pooka",
    "module native\nexternal Lists from erlang \"lists\" {\n  reverse(items: List(a)) -> List(a)\n}\n",
  )
  let outcome = run(directory)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "#([2, 1], [4, 3])\n"
}

pub fn elixir_ffi_source_executes_test() {
  case has_executable("elixirc") {
    False -> Nil
    True -> {
      use directory <- support.with_directory("ffi_elixir")
      project(
        directory,
        "external Formatter from elixir \"Formatter\" {\n  label(n: Int) -> String\n}\nmain() { echo { Formatter.label(7) } }",
      )
      support.write(
        directory <> "/ffi/formatter.ex",
        "defmodule Formatter do\n  def label(n), do: \"n=\" <> Integer.to_string(n)\nend\n",
      )
      let outcome = run(directory)
      assert support.diagnostics(outcome.stderr) == ""
      assert outcome.stdout == "\"n=7\"\n"
    }
  }
}

pub fn foreign_compile_errors_fail_the_build_test() {
  use directory <- support.with_directory("ffi_compile_error")
  project(directory, math <> "main() { echo { Math.double(1) } }")
  support.write(
    directory <> "/ffi/math_helpers.erl",
    "-module(math_helpers).\n-export([double/1]).\ndouble(V) -> V * .\n",
  )
  let outcome = support.cli_main(["build"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "foreign source could not be compiled")
  assert string.contains(outcome.stderr, "ffi/math_helpers.erl:3:")

  assert !string.contains(outcome.stderr, directory)
}

pub fn removed_foreign_sources_are_pruned_test() {
  use directory <- support.with_directory("ffi_prune")
  project(directory, math <> "main() { echo { Math.double(1) } }")
  support.write(
    directory <> "/ffi/math_helpers.erl",
    "-module(math_helpers).\n-export([double/1]).\ndouble(V) -> V * 2.\n",
  )
  support.write(
    directory <> "/ffi/extra.erl",
    "-module(extra).\n-export([x/0]).\nx() -> 1.\n",
  )
  let assert Ok(report) = build.build(directory)
  let extra = report.directory <> "/extra.beam"
  assert simplifile.is_file(extra) == Ok(True)
  let assert Ok(Nil) = simplifile.delete(directory <> "/ffi/extra.erl")
  let assert Ok(report) = build.build(directory)
  assert simplifile.is_file(extra) == Ok(False)
  assert simplifile.is_file(report.directory <> "/math_helpers.beam")
    == Ok(True)
}

pub fn foreign_modules_are_listed_in_the_application_test() {
  use directory <- support.with_directory("ffi_application")
  project(directory, math <> "main() { echo { Math.double(1) } }")
  support.write(
    directory <> "/ffi/math_helpers.erl",
    "-module(math_helpers).\n-export([double/1]).\ndouble(V) -> V * 2.\n",
  )
  let assert Ok(report) = build.build(directory)
  let assert Ok(application) = simplifile.read(report.layout.application)
  assert string.contains(application, "math_helpers")
}

pub fn hidden_ffi_files_are_ignored_test() {
  use directory <- support.with_directory("ffi_hidden")
  project(directory, math <> "main() { echo { Math.double(1) } }")
  support.write(
    directory <> "/ffi/math_helpers.erl",
    "-module(math_helpers).\n-export([double/1]).\ndouble(V) -> V * 2.\n",
  )

  support.write(directory <> "/ffi/.broken.erl", "not erlang")
  let assert Ok(_) = build.build(directory)
}

pub fn every_language_word_parses_test() {
  ["erlang", "elixir", "gleam", "lfe"]
  |> list.each(fn(word) {
    assert support.diagnostic_ids(
        "module main\nexternal X from " <> word <> " \"x\" { f() -> Int }",
      )
      == []
  })
  let assert [
    ast.ExternalDeclaration(ast.External(language: ast.Gleam, ..)),
    ast.ExternalDeclaration(ast.External(language: ast.Lfe, ..)),
  ] =
    support.parse(
      "module main\nexternal A from gleam \"a\" { f() -> Int }\nexternal B from lfe \"b\" { f() -> Int }",
    ).declarations
}

pub fn misspelt_languages_get_a_suggestion_test() {
  let checked =
    compiler.check_source(
      support.path,
      "module main\nexternal X from elixr \"X\" { f() -> Int }",
    )
  let assert [diagnostic] = checked.diagnostics
  assert diagnostic.id == "parse.unsupported_foreign_language"
  assert diagnostic.suggestions == ["Did you mean `elixir`?"]
}

pub fn ffi_files_are_assigned_a_language_by_extension_test() {
  assert foreign_language.of_file("a.erl") == Ok(ast.Erlang)
  assert foreign_language.of_file("b.ex") == Ok(ast.Elixir)
  assert foreign_language.of_file("text/style.gleam") == Ok(ast.Gleam)
  assert foreign_language.of_file("c.lfe") == Ok(ast.Lfe)
  assert foreign_language.of_file("header.hrl") == Error(Nil)
}

pub fn foreign_compiler_commands_test() {
  let sources = fn(language, path) {
    [foreign.Source("/p/ffi/" <> path, path, language)]
  }
  assert foreign.command(ast.Erlang, sources(ast.Erlang, "a.erl"), "/w")
    == Error(Nil)
  assert foreign.command(ast.Elixir, sources(ast.Elixir, "b.ex"), "/w")
    == Ok(foreign.Command(
      "elixirc",
      ["--ignore-module-conflict", "-o", "/w/elixir", "/p/ffi/b.ex"],
      "/w/elixir",
    ))
  assert foreign.command(ast.Lfe, sources(ast.Lfe, "c.lfe"), "/w")
    == Ok(foreign.Command("lfec", ["-o", "/w/lfe", "/p/ffi/c.lfe"], "/w/lfe"))
  assert foreign.command(ast.Gleam, sources(ast.Gleam, "d.gleam"), "/w")
    == Ok(foreign.Command(
      "gleam",
      [
        "compile-package", "--target", "erlang", "--package", "/w/gleam/package",
        "--out", "/w/gleam/out", "--lib", "/w/gleam/lib",
      ],
      "/w/gleam/out/ebin",
    ))
}

pub fn ffi_discovery_test() {
  use directory <- support.with_directory("ffi_discovery")
  support.write(directory <> "/ffi/a.erl", "")
  support.write(directory <> "/ffi/include.hrl", "")
  support.write(directory <> "/ffi/text/style.gleam", "")
  support.write(directory <> "/ffi/.hidden.erl", "")
  assert foreign.discover(directory)
    |> list.map(fn(source) { #(source.relative, source.language) })
    == [#("a.erl", ast.Erlang), #("text/style.gleam", ast.Gleam)]
}

pub fn gleam_ffi_source_executes_test() {
  use directory <- support.with_directory("ffi_gleam")
  project(
    directory,
    "external Style from gleam \"text/style\" {\n  shout(text: String) -> String\n}\nexternal Top from gleam \"top\" {\n  answer() -> Int\n}\nmain() { echo { #(Style.shout(\"hi\"), Top.answer()) } }",
  )
  support.write(
    directory <> "/ffi/text/style.gleam",
    "pub fn shout(text: String) -> String {\n  text <> \"!\"\n}\n",
  )
  support.write(
    directory <> "/ffi/top.gleam",
    "pub fn answer() -> Int { 42 }\n",
  )
  let outcome = run(directory)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "#(\"hi!\", 42)\n"
}

pub fn gleam_compile_errors_fail_the_build_test() {
  use directory <- support.with_directory("ffi_gleam_error")
  project(directory, "main() { Nil }")
  support.write(
    directory <> "/ffi/broken.gleam",
    "pub fn f() -> Int { \"no\" }\n",
  )
  let outcome = support.cli_main(["build"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "`ffi/*.gleam` failed to compile")
  assert string.contains(outcome.stderr, "Type mismatch")
}

pub fn removed_gleam_sources_are_pruned_test() {
  use directory <- support.with_directory("ffi_gleam_prune")
  project(directory, "main() { Nil }")
  support.write(directory <> "/ffi/one.gleam", "pub fn f() -> Int { 1 }\n")
  support.write(directory <> "/ffi/two.gleam", "pub fn g() -> Int { 2 }\n")
  let assert Ok(report) = build.build(directory)
  assert simplifile.is_file(report.directory <> "/two.beam") == Ok(True)
  let assert Ok(Nil) = simplifile.delete(directory <> "/ffi/two.gleam")
  let assert Ok(report) = build.build(directory)
  assert simplifile.is_file(report.directory <> "/two.beam") == Ok(False)
  assert simplifile.is_file(report.directory <> "/one.beam") == Ok(True)
}

pub fn a_missing_compiler_is_reported_test() {
  case has_executable("lfec") {
    True -> Nil
    False -> {
      use directory <- support.with_directory("ffi_lfe_missing")
      project(directory, "main() { Nil }")
      support.write(directory <> "/ffi/helpers.lfe", "(defmodule helpers)\n")
      let outcome = support.cli_main(["build"], command.plain(directory))
      assert outcome.status == 1
      assert string.contains(outcome.stderr, "foreign compiler not found")
      assert string.contains(outcome.stderr, "`lfec` was not found on PATH")
    }
  }
}

pub fn foreign_modules_with_a_pooka_prefix_are_not_pruned_test() {
  use directory <- support.with_directory("ffi_generated_prefix")
  project(
    directory,
    "external Native from erlang \"pooka@app@native\" { value() -> Int }\nmain() { echo { Native.value() } }",
  )
  support.write(
    directory <> "/ffi/native.erl",
    "-module('pooka@app@native').\n-export([value/0]).\nvalue() -> 42.\n",
  )
  let outcome = run(directory)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "42\n"
}

pub fn foreign_module_collisions_preserve_existing_beams_test() {
  use directory <- support.with_directory("ffi_owner_collision")
  project(directory, "main() { echo { 42 } }")
  let assert Ok(first) = build.build(directory)
  let assert Ok(previous) =
    simplifile.read_bits(first.directory <> "/pooka@app@main.beam")
  support.write(
    directory <> "/ffi/collision.erl",
    "-module('pooka@app@main').\n-export([main/0]).\nmain() -> 99.\n",
  )
  let assert Error(error) = build.build(directory)
  assert list.any(error.diagnostics, fn(value) {
    value.id == "build.foreign_module_collision"
  })
  assert simplifile.read_bits(first.directory <> "/pooka@app@main.beam")
    == Ok(previous)
}

pub fn a_removed_foreign_module_can_be_replaced_by_pooka_source_test() {
  use directory <- support.with_directory("ffi_owner_transition")
  project(directory, "main() { echo { 42 } }")
  support.write(
    directory <> "/ffi/helper.erl",
    "-module('pooka@app@helper').\n-export([value/0]).\nvalue() -> 1.\n",
  )
  let assert Ok(_) = build.build(directory)
  let assert Ok(Nil) = simplifile.delete_file(directory <> "/ffi/helper.erl")
  support.write(
    directory <> "/src/helper.pooka",
    "module helper\nvalue() { 42 }",
  )
  project(directory, "import helper\nmain() { echo { helper.value() } }")
  let outcome = run(directory)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "42\n"
}

pub fn two_foreign_files_cannot_own_the_same_module_test() {
  use directory <- support.with_directory("ffi_duplicate_owner")
  project(directory, "main() { echo { 42 } }")
  support.write(
    directory <> "/ffi/one.erl",
    "-module(shared).\n-export([value/0]).\nvalue() -> 1.\n",
  )
  support.write(
    directory <> "/ffi/two.erl",
    "-module(shared).\n-export([value/0]).\nvalue() -> 2.\n",
  )
  let assert Error(error) = build.build(directory)
  assert list.any(error.diagnostics, fn(value) {
    value.id == "build.foreign_module_collision"
  })
}

pub fn lfe_ffi_source_executes_test() {
  case has_executable("lfec") {
    False -> Nil
    True -> {
      use directory <- support.with_directory("ffi_lfe")
      project(
        directory,
        "external Lisp from lfe \"lfe_helpers\" { triple(value: Int) -> Int }\nmain() { echo { let triple = Lisp.triple\n#(Lisp.triple(14), triple(7)) } }",
      )
      support.write(
        directory <> "/ffi/lfe_helpers.lfe",
        "(defmodule lfe_helpers (export (triple 1)))\n(defun triple (value) (* value 3))\n",
      )
      let outcome = run(directory)
      assert support.diagnostics(outcome.stderr) == ""
      assert outcome.status == 0
      assert outcome.stdout == "#(42, 21)\n"
    }
  }
}
