//// A correct type is only the beginning of the journey.
////
//// Compile small Pooka programs and execute the resulting BEAM modules. These
//// checks observe evaluation order, callable boundaries, immutable constructor
//// state and runtime failures; abstract-form snapshots inspect selected
//// translations. The source strings are the fixtures, not examples to rewrite
//// while commenting the harness.
////
//// ```text
//// Pooka source -> checked program -> Erlang abstract forms -> BEAM -> output
//// ```

import birdie
import builder/build
import cli/command
import compiler/codegen/beam
import compiler/codegen/erlang
import compiler/typesystem/module_infer
import compiler/typesystem/typed_ast
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string
import simplifile
import support

fn run(name: String, source: String) -> command.Outcome {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
  support.cli_main(["run"], command.plain(directory))
}

/// Wrap a single-module runtime example in the suite's temporary project
/// runner. Expected output comes from executing the generated program, not
/// evaluating its AST in the test.
fn output(name: String, source: String) -> String {
  let report = run(name, source)
  assert support.diagnostics(report.stderr) == ""
  assert report.status == 0
  report.stdout
}

// These assertions run compiled BEAM code. Successful inference alone cannot
// tell us that recursive calls were emitted with the correct target.
pub fn recursive_functions_execute_on_beam_test() {
  assert output(
      "codegen_recursion",
      "factorial(n) { match n { 0 -> 1\n_ -> n * factorial(n - 1) } }\nmain() { echo { factorial(6) } }",
    )
    == "720\n"
}

pub fn closures_polymorphism_and_shadowing_execute_test() {
  assert output(
      "codegen_closures",
      "id(value) { value }\nmain() { echo { let x = 1\nlet f = fn(y) { x + y }\nlet inner = { let x = 99\nx }\n#(f(2), x, inner, id(\"s\"), id(True)) } }",
    )
    == "#(3, 1, 99, \"s\", True)\n"
}

pub fn arbitrary_guards_and_nested_patterns_execute_test() {
  assert output(
      "codegen_guards",
      "positive(x) { x > 0 }\nmain() { echo { match Some(#(-1, [True])) { Some(#(x, [True])) if positive(x) -> 0\nSome(#(x, [True])) if positive(-x) -> 42\n_ -> 99 } } }",
    )
    == "42\n"
}

pub fn string_addition_numeric_division_and_remainder_execute_test() {
  assert output(
      "codegen_operators",
      "main() { echo { #(\"a\" + \"é\", 5 / 2, 5 % 2, 5.5 % 2.0, -5 % 2) } }",
    )
    == "#(\"aé\", 2.5, 1, 1.5, -1)\n"
}

// The propagation handler belongs to the source callable. An inner closure
// must not return through the handler of the function that created it.
pub fn result_propagation_stops_only_its_callable_test() {
  assert output(
      "codegen_propagate",
      "read(flag) -> Result(Int, String) { match flag { True -> Ok(1)\nFalse -> Error(\"failed\") } }\nwork(flag) { let value = read(flag)?\nOk(value + 1) }\nmain() { echo { let f = fn() { let x = read(False)?\nOk(x) }\n#(work(True), work(False), f(), 42) } }",
    )
    == "#(Ok(2), Error(\"failed\"), Error(\"failed\"), 42)\n"
}

pub fn short_circuit_and_assertion_messages_are_lazy_test() {
  assert output(
      "codegen_lazy",
      "main() { echo { assert True as panic\n#(False && panic, True || panic) } }",
    )
    == "#(False, True)\n"
}

pub fn binary_construction_and_pattern_sizes_execute_test() {
  assert output(
      "codegen_binary",
      "main() { echo { let bytes = <<2:8, 513:16-little>>\nlet <<length:8, payload:size(length)-bytes>> = bytes\nlet <<value:16-little>> = payload\n#(length, value, <<\"é\":utf8>>) } }",
    )
    == "#(2, 513, \"é\")\n"
}

pub fn dynamic_binary_sizes_and_constant_units_execute_test() {
  assert output(
      "codegen_dynamic_binary_sizes",
      "pack(value, size) { <<value:size(size)-unit(2 * 4)>> }\nread(bytes, size) { match bytes { <<value:size(size)-unit(8), rest:bits>> -> #(value, rest)\n_ -> #(0, <<>>) } }\nmain() { echo { let bytes = pack(513, 2)\n#(bytes, pack(0, 0), read(bytes, 1), read(bytes, 0)) } }",
    )
    == "#(<<2, 1>>, \"\", #(2, <<1>>), #(0, <<2, 1>>))\n"
}

pub fn invalid_dynamic_binary_construction_fails_at_runtime_test() {
  list.each(
    [
      #(
        "negative_size",
        "pack(size) { <<1:size(size)>> }\nmain() { echo { pack(-1) } }",
      ),
      #(
        "float_width",
        "pack(size) { <<1.0:float-size(size)>> }\nmain() { echo { pack(24) } }",
      ),
      #(
        "short_payload",
        "pack(payload, size) { <<payload:bytes-size(size)>> }\nmain() { echo { pack(<<1>>, 2) } }",
      ),
      #(
        "unaligned_payload",
        "pack(payload) { <<payload:bytes>> }\nmain() { echo { pack(<<1:1>>) } }",
      ),
      #(
        "unaligned_unit",
        "pack(payload) { <<payload:bits-unit(8)>> }\nmain() { echo { pack(<<1:1>>) } }",
      ),
    ],
    fn(example) {
      let report = run("codegen_dynamic_binary_" <> example.0, example.1)
      assert report.status == 1
      assert string.contains(report.stderr, "badarg")
    },
  )
}

pub fn invalid_dynamic_binary_patterns_fall_through_test() {
  assert output(
      "codegen_dynamic_binary_pattern_failure",
      "integer(bytes, size) { match bytes { <<value:size(size)>> -> Some(value)\n_ -> None } }\nfloat(bytes, size) { match bytes { <<value:float-size(size)>> -> Some(value)\n_ -> None } }\nbytes(payload) { match payload { <<rest:bytes>> -> Some(rest)\n_ -> None } }\nmain() { echo { #(integer(<<1>>, -1), integer(<<1>>, 16), float(<<1, 2, 3>>, 24), bytes(<<1:1>>), bytes(<<1>>)) } }",
    )
    == "#(None, None, None, None, Some(<<1>>))\n"
}

pub fn utf_prefix_patterns_execute_test() {
  assert output(
      "codegen_utf_pattern",
      "main() { echo { match <<\"Pooka\":utf8, 42>> { <<\"Pooka\":utf8, value:8>> -> value\n_ -> 0 } } }",
    )
    == "42\n"
}

pub fn nested_loops_break_at_the_nearest_boundary_test() {
  assert output(
      "codegen_loops",
      "main() { echo { loop { let x = loop { break 41 }\nbreak x + 1 } } }",
    )
    == "42\n"
}

pub fn io_observes_left_to_right_arguments_test() {
  assert output(
      "codegen_io_order",
      "mark(value: String) { echo(value)\nvalue }\npair(a: String, b: String) { a + b }\nmain() { echo(pair(mark(\"a\"), mark(\"b\")))\nNil }",
    )
    == "\"a\"\n\"b\"\n\"ab\"\n"
}

pub fn local_imports_execute_in_dependency_order_test() {
  use directory <- support.with_directory("codegen_modules")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/util/id.pooka",
    "module id\nidentity(value) { value }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport util/id as util\nmain() { echo { #(util.identity(42), util.identity(\"s\")) } }",
  )
  let report = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(report.stderr) == ""
  assert report.stdout == "#(42, \"s\")\n"
  assert report.status == 0
}

pub fn invalid_types_do_not_replace_existing_artifacts_test() {
  use directory <- support.with_directory("codegen_failed_build")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 42 } }",
  )
  let assert Ok(report) = build.build(directory)
  let target = report.directory <> "/pooka@app@main.beam"
  let assert Ok(before) = simplifile.read_bits(target)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 1 + \"bad\" } }",
  )
  let assert Error(_) = build.build(directory)
  assert simplifile.read_bits(target) == Ok(before)
}

pub fn runtime_failure_is_a_failed_command_test() {
  let report = run("codegen_panic", "main() { echo { panic as \"boom\" } }")
  assert report.status == 1
  assert string.contains(report.stderr, "panic: boom")
}

// Inspect the intermediate Erlang forms as well as runtime output. The
// snapshot makes changes in the translation visible before compile:forms
// consumes them.
/// The binding in this fixture has the following abstract-form shape. M0 is
/// the generated name used by this snapshot; annotations retain source lines.
///
/// ```erlang
/// {match, 2, {var, 2, 'M0'}, {integer, 2, 40}}
/// ```
///
/// Erlang expressions and matches:
/// https://www.erlang.org/doc/apps/erts/absform.html#expressions
pub fn direct_abstract_forms_snapshot_test() {
  let source = "module main\nmain() { let x = 40\nx + 2 }"
  let syntax = support.parse(source)
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  let assert Ok(generated) = erlang.generate(typed, "app", "main", dict.new())
  let assert Ok(_) = beam.compile(generated.forms)

  let snapshot =
    support.pretty(generated.forms) <> "\n---\n" <> beam.pretty(generated.forms)
  birdie.snap(snapshot, title: "codegen direct erlang abstract forms")
}

pub fn let_assert_messages_are_lazy_and_success_bindings_escape_test() {
  assert output(
      "codegen_let_assert_success",
      "main() { echo { let assert Some(value) = Some(42) as panic\nvalue } }",
    )
    == "42\n"
  let report =
    run(
      "codegen_let_assert_failure",
      "main() { echo { let assert Some(value) = None as \"missing value\"\nvalue } }",
    )
  assert report.status == 1
  assert string.contains(report.stderr, "assertion failed: missing value")
}

pub fn utf16_and_utf32_encoding_execute_test() {
  assert output(
      "codegen_utf_encodings",
      "main() { echo { let bytes = <<\"😀\":utf16-little>>\nlet <<\"😀\":utf16-little>> = bytes\n#(bytes == <<0x3d, 0xd8, 0, 0xde>>, <<\"a\":utf32-big>> == <<0, 0, 0, 97>>) } }",
    )
    == "#(True, True)\n"
}

pub fn tail_recursive_calls_do_not_need_propagation_handlers_test() {
  assert output(
      "codegen_tail_recursion",
      "count(n: Int, acc: Int) { match n { 0 -> acc\n_ -> count(n - 1, acc + 1) } }\nmain() { echo { count(100000, 0) } }",
    )
    == "100000\n"
}

pub fn compiled_test_blocks_can_access_private_helpers_test() {
  use directory <- support.with_directory("codegen_test_blocks")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 42 } }",
  )
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main\nimport main\n_private(value: Int) { value + 1 }\ntest \"private helper\" { assert _private(41) == 42 }\ntest \"imported main\" { assert main.main() == 42 }",
  )
  let result = support.cli_main(["test"], command.plain(directory))
  assert support.diagnostics(result.stderr) == ""
  assert result.status == 0
  assert string.contains(result.stdout, "✓ private helper")
  assert string.contains(result.stdout, "✓ imported main")
  assert string.contains(result.stdout, "2 tests, 2 passed")
}

pub fn test_failures_do_not_prevent_independent_tests_test() {
  use directory <- support.with_directory("codegen_test_failures")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n")
  support.write(
    directory <> "/test/main.spec.pooka",
    "module main\ntest \"fails\" { assert False as \"expected failure\" }\ntest \"passes later\" { assert True }",
  )
  let result = support.cli_main(["test"], command.plain(directory))
  assert result.status == 1
  assert string.contains(result.stdout, "✗ fails")
  assert string.contains(result.stdout, "expected failure")
  assert string.contains(result.stdout, "✓ passes later")
  assert string.contains(result.stdout, "2 tests, 1 passed, 1 failed")
}

pub fn build_rejects_unsupported_constructs_with_source_context_test() {
  let result =
    run(
      "codegen_unsupported_annotation",
      "interface Incomplete { read() }\nmain() { Nil }",
    )
  assert result.status == 1
  assert string.contains(result.stderr, "interface Incomplete")
  assert string.contains(result.stderr, "missing result type")
}

pub fn nonzero_arity_main_is_rejected_before_execution_test() {
  let result = run("codegen_main_arity", "main(value) { value }")
  assert result.status == 1
  assert string.contains(result.stderr, "requires")
  assert !string.contains(result.stderr, "undef")
}

pub fn ordinary_io_modules_execute_without_compiler_special_cases_test() {
  use directory <- support.with_directory("codegen_local_io")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/io.pooka",
    "module io\nprintln(value: Int) { value + 1 }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport io\nmain() { echo { io.println(41) } }",
  )
  let result = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(result.stderr) == ""
  assert result.status == 0
  assert result.stdout == "42\n"
}

pub fn module_path_mangling_distinguishes_flat_names_test() {
  assert erlang.module_name("app", "a/b") != erlang.module_name("app", "a_b")
  assert erlang.module_name("app", "a/b") == "pooka@app@a@b"
}

pub fn runner_handles_spaces_and_quotes_in_paths_test() {
  assert output("codegen path ' with spaces", "main() { echo { 42 } }")
    == "42\n"
}

pub fn selective_aliases_and_first_class_imports_execute_test() {
  use directory <- support.with_directory("codegen_selective_functions")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/util.pooka",
    "module util\nidentity(value) { value }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport util.{identity as id}\nmain() { echo { let f = util.identity\n#(id(42), f(\"s\"), True |> id()) } }",
  )
  let result = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(result.stderr) == ""
  assert result.stdout == "#(42, \"s\", True)\n"
  assert result.status == 0
}

pub fn program_arguments_are_passed_without_shell_interpolation_test() {
  use directory <- support.with_directory("codegen_argument_vector")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo { 42 } }",
  )
  let result =
    support.cli_main(
      ["run", "--", "a b", "'quoted'", "$(this_is_data)"],
      command.plain(directory),
    )
  assert support.diagnostics(result.stderr) == ""
  assert result.stdout == "42\n"
  assert result.status == 0
}

pub fn class_constructors_fields_and_methods_execute_test() {
  assert output(
      "codegen_classes",
      "class User { let name: String\nnew(name) { self.name = name }\ngreet() { \"Hello \" + name } }\nmain() { echo { let user = User(\"Pooka\")\n#(user.name, user.greet()) } }",
    )
    == "#(\"Pooka\", \"Hello Pooka\")\n"
}

pub fn generic_class_instances_keep_independent_field_types_test() {
  assert output(
      "codegen_generic_classes",
      "class Box(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\nmain() { echo { #(Box(42).get(), Box(\"Pooka\").get()) } }",
    )
    == "#(42, \"Pooka\")\n"
}

// A method reference saves one evaluated receiver. Re-evaluating its
// expression during each call would repeat effects and possibly select
// another object.
pub fn bound_methods_capture_the_receiver_once_test() {
  assert output(
      "codegen_bound_methods",
      "class Counter { let value: Int\nnew(value) { self.value = value }\nadd(amount: Int) { value + amount } }\ncreate() { echo(\"once\")\nCounter(40) }\nmain() { echo { let add = create().add\n#(add(1), add(2)) } }",
    )
    == "\"once\"\n#(41, 42)\n"
}

pub fn class_member_closures_capture_implicit_fields_test() {
  assert output(
      "codegen_member_closures",
      "class Number { let value: Int\nnew(value) { self.value = value }\nreader() { fn() { value } }\nchoose(value: String) { value } }\nmain() { echo { let n = Number(42)\nlet read = n.reader()\n#(read(), n.choose(\"shadow\")) } }",
    )
    == "#(42, \"shadow\")\n"
}

pub fn constructors_join_immutable_field_state_across_branches_test() {
  assert output(
      "codegen_constructor_branches",
      "class Number { let value: Int\nnew(flag: Bool) { match flag { True -> self.value = 41\nFalse -> self.value = 42 } } }\nmain() { echo { #(Number(True).value, Number(False).value) } }",
    )
    == "#(41, 42)\n"
}

pub fn nested_constructor_blocks_preserve_field_initialization_test() {
  assert output(
      "codegen_constructor_blocks",
      "class Pair { let first: Int\nlet second: Int\nnew(flag: Bool) { { self.first = 1 }\nmatch flag { True -> { self.second = 2 }\nFalse -> { self.second = 3 } } } }\nmain() { echo { let p = Pair(False)\n#(p.first, p.second) } }",
    )
    == "#(1, 3)\n"
}

pub fn empty_classes_default_fields_and_constructor_references_execute_test() {
  assert output(
      "codegen_class_defaults",
      "class Empty {}\nclass Value { let value = 42 }\nmain() { echo { let make = Value.new\n#(make().value, Empty() == Empty()) } }",
    )
    == "#(42, True)\n"
}

pub fn nominal_class_patterns_destructure_fields_test() {
  assert output(
      "codegen_class_patterns",
      "class Box(a) { let value: a\nnew(value) { self.value = value } }\nmain() { echo { let assert Box(value) = Box(42)\nvalue } }",
    )
    == "42\n"
}

pub fn method_result_propagation_is_its_own_callable_boundary_test() {
  assert output(
      "codegen_method_result",
      "class Reader { read(value: Result(Int, String)) { let n = value?\nOk(n + 1) } }\nmain() { echo { let r = Reader()\n#(r.read(Ok(41)), r.read(Error(\"missing\"))) } }",
    )
    == "#(Ok(42), Error(\"missing\"))\n"
}

pub fn annotated_generic_methods_transform_receiver_parameters_test() {
  assert output(
      "codegen_generic_map",
      "class Box(a) { let value: a\nnew(value) { self.value = value }\nmap(transform: fn(a) -> b) -> Box(b) { Box(transform(value)) } }\nmain() { echo { Box(42).map(fn(n) { n == 42 }).value } }",
    )
    == "True\n"
}

pub fn imported_class_aliases_preserve_nominal_identity_test() {
  use directory <- support.with_directory("codegen_imported_classes")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/box.pooka",
    "module box\nclass Box(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport box.{Box as Crate}\nread(value: Crate(Int)) { value.get() }\nmain() { echo { let make = box.Box.new\n#(read(make(42)), Crate(\"s\").value) } }",
  )
  let result = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(result.stderr) == ""
  assert result.stdout == "#(42, \"s\")\n"
  assert result.status == 0
}

/// Inspect the immutable tuple layout and the closure for a bound method.
/// This is a schematic tuple form, with Field standing for its lowered value:
///
/// ```erlang
/// {tuple, Anno, [{atom, Anno, 'pooka@class@main@Box'}, Field]}
/// ```
///
/// Erlang tuples and anonymous functions:
/// https://www.erlang.org/doc/apps/erts/absform.html#expressions
pub fn class_abstract_forms_snapshot_test() {
  let syntax =
    support.parse(
      "module main\nclass Box(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\nmain() { let get = Box(42).get\nget() }",
    )
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  let assert Ok(generated) = erlang.generate(typed, "app", "main", dict.new())
  let assert Ok(_) = beam.compile(generated.forms)

  birdie.snap(
    beam.pretty(generated.forms),
    title: "codegen immutable class abstract forms",
  )
}

pub fn constructor_lazy_assertion_messages_do_not_leak_field_state_test() {
  assert output(
      "codegen_constructor_lazy_assertions",
      "class Number { let value: Int\nnew() { self.value = 42\nassert True as { self.value = 0\n\"failed\" }\nlet assert _ = Nil as { self.value = 1\n\"failed\" } } }\nmain() { echo { Number().value } }",
    )
    == "42\n"
}

pub fn constructor_loops_preserve_field_initialization_on_break_test() {
  assert output(
      "constructor_loop",
      "class Value { let value: Int\nnew() { loop { self.value = 42\nbreak } } }\nmain() { echo { Value().value } }",
    )
    == "42\n"
}

// The break expression can itself initialize a field. Capture the constructor
// state after evaluating that value, or the escaping object loses the update.
pub fn constructor_loop_break_values_evaluate_before_capturing_state_test() {
  assert output(
      "constructor_break_value",
      "class Pair { let first: Int\nlet second: Int\nnew() { let result = loop { break { self.first = 20\n22 } }\nself.second = result } }\nmain() { echo { let pair = Pair()\npair.first + pair.second } }",
    )
    == "42\n"
}

pub fn nested_constructor_loops_break_at_the_nearest_boundary_test() {
  assert output(
      "constructor_nested_loops",
      "class Pair { let first: Int\nlet second: Int\nnew() { loop { loop { self.first = 20\nbreak }\nself.second = 22\nbreak } } }\nmain() { echo { let pair = Pair()\npair.first + pair.second } }",
    )
    == "42\n"
}

pub fn constructor_loop_branches_carry_field_state_to_the_exit_test() {
  assert output(
      "constructor_loop_branches",
      "class Value { let value: Int\nnew(flag: Bool) { loop { match flag { True -> { self.value = 41\nbreak }\nFalse -> { self.value = 42\nbreak } } } } }\nmain() { echo { #(Value(True).value, Value(False).value) } }",
    )
    == "#(41, 42)\n"
}

pub fn constructor_continue_preserves_already_initialized_fields_test() {
  use directory <- support.with_directory("constructor_continue")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/ffi/steps.erl",
    "-module(steps).\n-export([next/0]).\nnext() -> case get(step) of undefined -> put(step, true), false; _ -> true end.\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Step from erlang \"steps\" { next() -> Bool }\nclass Pair { let first: Int\nlet second: Int\nnew() { self.first = 40\nloop { match Step.next() { True -> { self.second = first + 2\nbreak }\nFalse -> continue } } } }\nmain() { echo { Pair().second } }",
  )
  let result = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(result.stderr) == ""
  assert result.status == 0
  assert result.stdout == "42\n"
}

pub fn subclass_constructor_loops_preserve_parent_initialization_test() {
  assert output(
      "constructor_loop_super",
      "class Parent { let first: Int\nnew(value) { self.first = value } }\nclass Child is Parent { let second: Int\nnew() { loop { super.new(40)\nself.second = 2\nbreak } } }\nmain() { echo { let child = Child()\nchild.first + child.second } }",
    )
    == "42\n"
}

pub fn unicode_codepoint_patterns_and_encodings_execute_test() {
  assert output(
      "codegen_codepoints",
      "main() { echo { let assert <<point:utf8_codepoint>> = <<\"😀\":utf8>>\nlet assert <<again:utf16_codepoint-little>> = <<point:utf16_codepoint-little>>\n#(point == again, <<point:utf32_codepoint-big>>, match <<255>> { <<_:utf8_codepoint>> -> False\n_ -> True }) } }",
    )
    == "#(True, <<0, 1, 246, 0>>, True)\n"
}

// Lowering may introduce helper functions for match fallbacks. Those
// generated functions must not steal the source-level boundary of ?.
pub fn result_propagation_in_match_fallbacks_stays_in_its_source_callable_test() {
  assert output(
      "codegen_propagate_later_branch",
      "read(values) -> Result(List(Int), String) { match values { [] -> Ok([])\n[first, ..rest] -> { let value = checked(first)?\nlet remaining = read(rest)?\nOk([value]) } } }\nchecked(value) -> Result(Int, String) { match value { 0 -> Error(\"zero\")\n_ -> Ok(value) } }\nmain() { echo #(read([1, 0]), read([]), 42) }",
    )
    == "#(Error(\"zero\"), Ok([]), 42)\n"
}
