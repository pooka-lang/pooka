//// The native door has a narrower frame.
////
//// Follow native declarations through compatible boundary types, manifest
//// components, build commands and runtime loading. Actual C fixtures exercise
//// the protocol when tools are available. Missing artifacts and loader
//// mismatches must report their own failures rather than pretend a function
//// was implemented.

import birdie
import cli/command
import compiler/codegen/beam
import compiler/codegen/erlang
import compiler/foreign_language
import compiler/parser/ast
import compiler/parser/parse_error
import compiler/typesystem/module_infer
import compiler/typesystem/typed_ast
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import project/native_component
import project/project
import project/project_error
import simplifile
import support
import tom

@external(erlang, "ffi_test_ffi", "has_executable")
fn has_executable(name: String) -> Bool

const hash =
  "native Hash from \"hash\" {\n  digest(data: BitArray) -> BitArray\n}\n"

pub fn native_declarations_parse_as_namespaces_test() {
  let module = support.parse("module main\n" <> hash)
  let assert [ast.ExternalDeclaration(native)] = module.declarations
  assert native.name.name == "Hash"
  assert native.language == ast.Native
  assert native.module == "hash"
  let assert [function] = native.functions
  assert function.name.name == "digest"
}

// Native syntax is contextual. Import paths and bindings using the same
// spelling must remain ordinary names outside the declaration form.
pub fn native_stays_an_ordinary_name_test() {
  let module =
    support.parse(
      "module main\nimport native\nimport other.{native}\nmain() { let native = 1\nnative }",
    )
  assert list.length(module.imports) == 2
}

pub fn component_names_are_snake_case_test() {
  let assert [parse_error.InvalidNativeComponent(_, "Fast-Hash")] =
    support.parse_errors(
      "module main\nnative Hash from \"Fast-Hash\" { digest(data: BitArray) -> BitArray }",
    )
  let assert [parse_error.InvalidNativeComponent(_, "")] =
    support.parse_errors("module main\nnative Hash from \"\" {}")
}

pub fn native_declarations_need_a_component_test() {
  let assert [error] =
    support.parse_errors("module main\nnative Hash from hash { }")
  assert parse_error.id(error) == "parse.unexpected_token"
}

pub fn native_signatures_follow_external_rules_test() {
  let assert [parse_error.ExternalColonReturn(_)] =
    support.parse_errors(
      "module main\nnative Hash from \"hash\" { digest(data: BitArray): BitArray }",
    )
}

pub fn native_syntax_errors_snapshot_test() {
  support.rendered(
    "module main\nnative Hash from \"Fast-Hash\" {\n  digest(data: BitArray) -> BitArray\n}\n",
  )
  |> birdie.snap(title: "native: invalid component name")
}

fn type_errors(source: String) -> List(String) {
  let syntax = support.parse("module main\n" <> source)
  let assert Ok(report) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  list.map(report.diagnostics, fn(value) { value.id })
}

pub fn native_compatible_types_are_accepted_test() {
  assert type_errors(
      "native Every from \"every\" {\n  all(a: Int, b: Float, c: Bool, d: String, e: BitArray) -> Nil\n  nested(values: List(#(Int, List(Float)))) -> #(String, BitArray)\n}\n",
    )
    == []
}

pub fn other_types_are_rejected_where_written_test() {
  assert type_errors(
      "class Point { let x: Int\nnew(x) { self.x = x } }\nnative Bad from \"bad\" {\n  option(value: Option(Int)) -> Int\n  generic(value: a) -> a\n  function(f: fn(Int) -> Int) -> Nil\n  instance(point: Point) -> List(Result(Int, String))\n}\n",
    )
    == list.repeat("native.unsupported_type", 6)
}

pub fn unsupported_type_snapshot_test() {
  let source =
    "module main\nnative Math from \"fast_math\" {\n  calculate(value: Option(Int)) -> Float\n}\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  support.render_all(report.diagnostics, source)
  |> birdie.snap(title: "native: unsupported type")
}

pub fn calls_are_type_checked_test() {
  assert type_errors(
      "native Math from \"fast_math\" {\n  calculate(value: Int) -> Float\n}\nmain() { Math.calculate(\"42\") }\n",
    )
    == ["type.unification"]
  assert type_errors(
      "native Math from \"fast_math\" {\n  calculate(value: Int) -> Float\n}\nmain() -> Float { Math.calculate(42) }\n",
    )
    == []
}

pub fn native_namespaces_are_not_values_test() {
  let ids = support.diagnostic_ids("module main\n" <> hash <> "main() { Hash }")
  assert ids == ["analysis.external_namespace_value"]
  assert string.contains(
    support.rendered("module main\n" <> hash <> "main() { Hash }"),
    "native namespace used as a value",
  )
}

pub fn calls_go_to_the_component_loader_test() {
  assert foreign_language.beam_module(ast.Native, "hash") == "pooka_native_hash"
  assert native_component.module("fast_hash") == "pooka_native_fast_hash"
  let syntax =
    support.parse("module main\n" <> hash <> "main() { Hash.digest(<<1>>) }\n")
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  let assert Ok(generated) = erlang.generate(typed, "app", "main", dict.new())
  assert string.contains(beam.pretty(generated.forms), "pooka_native_hash")
}

fn manifest(text: String) {
  let assert Ok(config) = tom.parse(text)
  native_component.parse(config, "pooka.toml")
}

pub fn components_are_read_from_the_manifest_test() {
  assert manifest(
      "[native.hash]\nbuild = \"make\"\n\n[native.fast_math]\nbuild = \"zig build\"\nartifact = \"zig-out/lib/fast_math.so\"\n",
    )
    == Ok([
      native_component.NativeComponent(
        "fast_math",
        "zig build",
        Some("zig-out/lib/fast_math.so"),
      ),
      native_component.NativeComponent("hash", "make", None),
    ])
  assert manifest("name = \"x\"\n") == Ok([])
}

pub fn invalid_components_are_reported_test() {
  let problem = fn(text) {
    case manifest(text) {
      Error(project_error.InvalidNativeComponent(_, component, problem)) ->
        component <> ": " <> problem
      _ -> "accepted"
    }
  }
  assert problem("[native.hash]\nartifact = \"x.so\"\n")
    == "hash: `build` is required: the command that builds it."
  assert problem("[native.hash]\nbuild = \"  \"\n")
    == "hash: `build` must not be empty."
  assert problem("[native.Hash]\nbuild = \"make\"\n")
    == "Hash: Component names are lowercase snake_case and start with a letter."
  assert problem("[native.hash]\nbuild = \"make\"\nartifact = \"/abs.so\"\n")
    == "hash: `artifact` must be a path relative to the component's directory."
  assert problem("[native.hash]\nbuild = \"make\"\nflags = \"-O2\"\n")
    == "hash: Unknown field `flags`."
  assert problem("native = 1\n") == ": `native` must be a table of components."
}

pub fn projects_load_their_components_test() {
  let assert Ok(loaded) =
    project.parse_manifest(
      "name = \"app\"\nversion = \"0.1.0\"\n[native.hash]\nbuild = \"make\"\n",
      "pooka.toml",
      "/p",
    )
  assert loaded.natives
    == [native_component.NativeComponent("hash", "make", None)]
}

fn native_project(directory: String, build: String, source: String) -> Nil {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n\n[native.calc]\nbuild = \""
      <> build
      <> "\"\n",
  )
  support.write(directory <> "/native/calc/README", "The calc component.\n")
  support.write(directory <> "/src/main.pooka", source)
}

const calc =
  "module main\nnative Calc from \"calc\" {\n  double(value: Int) -> Int\n}\nmain() { echo(Calc.double(21)) }\n"

pub fn undeclared_components_are_reported_by_check_test() {
  use directory <- support.with_directory("nif_unknown_component")
  native_project(
    directory,
    "true",
    "module main\nnative Other from \"other\" { f() -> Nil }\nmain() { Other.f() }\n",
  )
  let outcome = support.cli_main(["check"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "unknown native component")
  assert string.contains(outcome.stderr, "Add a `[native.other]` table")
}

pub fn components_need_a_directory_test() {
  use directory <- support.with_directory("nif_missing_directory")
  native_project(directory, "true", calc)
  let assert Ok(Nil) = simplifile.delete(directory <> "/native")
  let outcome = support.cli_main(["check"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "missing native component")
}

pub fn component_names_are_unique_across_packages_test() {
  use directory <- support.with_directory("nif_duplicate_component")
  native_project(directory, "true", calc)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nlib = { path = \"lib\" }\n\n[native.calc]\nbuild = \"true\"\n",
  )
  support.write(
    directory <> "/lib/pooka.toml",
    "name = \"lib\"\nversion = \"0.1.0\"\n\n[native.calc]\nbuild = \"true\"\n",
  )
  support.write(directory <> "/lib/native/calc/README", "Another calc.\n")
  support.write(directory <> "/lib/src/lib.pooka", "module lib\nf() { 1 }\n")
  let outcome = support.cli_main(["check"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(
    outcome.stderr,
    "native component declared by several packages",
  )
}

pub fn failing_builds_show_their_output_test() {
  use directory <- support.with_directory("nif_failing_build")
  native_project(
    directory,
    "echo compiling calc; echo broken >&2; exit 3",
    calc,
  )
  let outcome = support.cli_main(["build"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "native build failed")
  assert string.contains(outcome.stderr, "compiling calc")
  assert string.contains(outcome.stderr, "broken")
  assert string.contains(outcome.stderr, "(exit status 3)")
}

pub fn builds_must_produce_their_artifact_test() {
  use directory <- support.with_directory("nif_missing_artifact")
  native_project(directory, "true", calc)
  let outcome = support.cli_main(["build"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(outcome.stderr, "missing native artifact")
  assert string.contains(outcome.stderr, "$POOKA_NATIVE_OUTPUT")
}

// A successful build command can leave the wrong kind of file. Validate the
// artifact rather than equating exit status zero with a loadable NIF.
pub fn artifacts_must_be_shared_libraries_test() {
  use directory <- support.with_directory("nif_invalid_artifact")
  native_project(directory, "echo text > \\\"$POOKA_NATIVE_OUTPUT\\\"", calc)
  let outcome = support.cli_main(["build"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(
    outcome.stderr,
    "native artifact is not a shared library",
  )
}

pub fn the_build_command_sees_the_protocol_environment_test() {
  use directory <- support.with_directory("nif_environment")
  native_project(
    directory,
    "env | grep ^POOKA_ > ../../environment.txt; pwd > ../../cwd.txt; exit 1",
    calc,
  )
  let _ = support.cli_main(["build"], command.plain(directory))
  let assert Ok(seen) = simplifile.read(directory <> "/environment.txt")
  assert string.contains(seen, "POOKA_NATIVE_COMPONENT=calc")
  assert string.contains(seen, "POOKA_NATIVE_MODULE=pooka_native_calc")
  assert string.contains(seen, "POOKA_BUILD_MODE=dev")
  assert string.contains(seen, "POOKA_NATIVE_OUTPUT=")
  assert string.contains(seen, "POOKA_ERTS_INCLUDE=")
  let assert Ok(cwd) = simplifile.read(directory <> "/cwd.txt")
  assert string.ends_with(string.trim(cwd), "/native/calc")
}

fn c_component(directory: String, functions: String) -> Nil {
  support.write(
    directory <> "/native/calc/calc.c",
    "#include <erl_nif.h>\nstatic ERL_NIF_TERM double_it(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {\n  (void)argc;\n  long value;\n  if (!enif_get_long(env, argv[0], &value)) return enif_make_badarg(env);\n  return enif_make_long(env, value * 2);\n}\nstatic ErlNifFunc functions[] = {"
      <> functions
      <> "};\nERL_NIF_INIT(pooka_native_calc, functions, NULL, NULL, NULL, NULL)\n",
  )
  support.write(
    directory <> "/native/calc/build.sh",
    "set -e\necho run >> ../../builds.txt\nif [ \"$(uname -s)\" = Darwin ]; then flags='-dynamiclib -undefined dynamic_lookup'; else flags=-shared; fi\ncc -fPIC -I\"$POOKA_ERTS_INCLUDE\" $flags -o \"$POOKA_NATIVE_OUTPUT\" calc.c\n",
  )
}

fn builds(directory: String) -> Int {
  case simplifile.read(directory <> "/builds.txt") {
    Ok(text) -> list.length(string.split(string.trim(text), "\n"))
    Error(_) -> 0
  }
}

// This fixture crosses the real C build and loader boundary when its required
// tools are present. Signature-only checks cannot prove the component
// protocol works.
pub fn c_nifs_build_load_and_run_test() {
  use <- when_available("cc")
  use directory <- support.with_directory("nif_c_runs")
  native_project(directory, "sh build.sh", calc)
  c_component(directory, "{\"double\", 1, double_it, 0}")
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
  assert outcome.stdout == "42\n"
  assert simplifile.is_file(directory <> "/build/dev/erlang/app/native/calc.so")
    == Ok(True)
  assert simplifile.is_file(
      directory <> "/build/dev/erlang/app/ebin/pooka_native_calc.beam",
    )
    == Ok(True)

  let _ = support.cli_main(["run"], command.plain(directory))
  assert builds(directory) == 1
  support.write(directory <> "/native/calc/notes.txt", "edited\n")
  let _ = support.cli_main(["run"], command.plain(directory))
  assert builds(directory) == 2
}

pub fn nifs_run_in_tests_and_shipments_test() {
  use <- when_available("cc")
  use directory <- support.with_directory("nif_c_shipment")
  native_project(directory, "sh build.sh", calc)
  c_component(directory, "{\"double\", 1, double_it, 0}")
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main_test\nimport main.{Calc}\ntest \"doubles\" { assert Calc.double(4) == 8 }\n",
  )
  let tested = support.cli_main(["test"], command.plain(directory))
  assert tested.status == 0
  assert string.contains(tested.stdout, "1 test, 1 passed")
  let exported =
    support.cli_main(["export", "shipment"], command.plain(directory))
  assert exported.status == 0
  assert simplifile.is_file(directory <> "/build/shipment/app/native/calc.so")
    == Ok(True)
}

pub fn unimplemented_functions_are_reported_when_called_test() {
  use <- when_available("cc")
  use directory <- support.with_directory("nif_c_unimplemented")
  native_project(
    directory,
    "sh build.sh",
    "module main\nnative Calc from \"calc\" {\n  double(value: Int) -> Int\n  triple(value: Int) -> Int\n}\nmain() { echo(Calc.triple(1)) }\n",
  )
  c_component(directory, "{\"double\", 1, double_it, 0}")
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(
    outcome.stderr,
    "native component `calc` does not implement `triple/1`",
  )
}

pub fn libraries_that_do_not_match_report_why_test() {
  use <- when_available("cc")
  use directory <- support.with_directory("nif_c_mismatch")
  native_project(
    directory,
    "sh build.sh",
    "module main\nnative Calc from \"calc\" {\n  halve(value: Int) -> Int\n}\nmain() { echo(Calc.halve(4)) }\n",
  )
  c_component(directory, "{\"double\", 1, double_it, 0}")
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 1
  assert string.contains(
    outcome.stderr,
    "native component `calc` could not be loaded",
  )
  assert string.contains(outcome.stderr, "pooka_native_calc:double/1")
}

pub fn dependencies_bring_their_own_nifs_test() {
  use <- when_available("cc")
  use directory <- support.with_directory("nif_dependency")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nfast = { path = \"fast\" }\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport fast\nmain() { echo(fast.twice(5)) }\n",
  )
  support.write(
    directory <> "/fast/pooka.toml",
    "name = \"fast\"\nversion = \"0.1.0\"\n\n[native.calc]\nbuild = \"sh build.sh\"\n",
  )
  support.write(
    directory <> "/fast/src/fast.pooka",
    "module fast\nnative _Calc from \"calc\" {\n  double(value: Int) -> Int\n}\ntwice(value: Int) -> Int { _Calc.double(value) }\n",
  )
  c_component(directory <> "/fast", "{\"double\", 1, double_it, 0}")
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.stdout == "10\n"
}

fn when_available(program: String, body: fn() -> Nil) -> Nil {
  case has_executable(program) {
    True -> body()
    False -> Nil
  }
}
