//// The lantern should illuminate a value without changing it.
////
//// Echo returns the value it prints, evaluates it once and carries useful
//// source information. Check prefix syntax, pipes, lexical shadowing and
//// actual terminal detection in fresh VMs. Colour overrides belong to the
//// runtime boundary as well as the compiler.
////
//// ```pooka
//// main() { [1, 2, 3] |> echo }
//// ```

import birdie
import cli/cli as raw_cli

import cli/command
import compiler/parser/ast
import compiler/typesystem/infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string
import pooka
import support

fn output(name: String, body: String) -> String {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> body)
  let report = support.cli_main(["run"], command.plain(directory))
  assert report.status == 0
  assert support.diagnostics(report.stderr) == ""
  report.stdout
}

pub fn echo_is_a_polymorphic_identity_function_test() {
  let assert Ok(report) =
    infer.infer(
      support.expression(
        "{ let inspect = echo\n#(inspect(42), inspect(True), inspect([1, 2])) }",
      ),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert report.diagnostics == []
  assert unify.apply(report.type_, report.state)
    == monotype.TupleType([
      monotype.IntType,
      monotype.BoolType,
      monotype.ListType(monotype.IntType),
    ])
}

pub fn echo_prints_arbitrary_values_and_preserves_pipeline_results_test() {
  assert output(
      "echo_values",
      "main() { let inspect = echo\nlet value = 41 |> echo\necho #(value + 1, inspect(True), inspect(Some(2))) }",
    )
    == "41\nTrue\nSome(2)\n#(42, True, Some(2))\n"
}

// Printing must not reconstruct the value or evaluate its expression twice.
// Closures and actor references make identity changes easier to expose.
pub fn echo_evaluates_once_and_preserves_closures_and_actor_identity_test() {
  let printed =
    output(
      "echo_identity",
      "actor Counter { var value = 0\nnext() { value += 1\nvalue } }\nmain() { let original = Counter.new()\nlet copied = echo(original)\nlet next = echo(fn() { original.next() })\necho #(original == copied, echo(next()), original.next()) }",
    )
  assert string.contains(printed, "Counter(<")
  assert string.contains(printed, "fn() { ... }")
  assert string.ends_with(printed, "1\n#(True, 1, 2)\n")
}

pub fn local_functions_can_shadow_echo_test() {
  assert output(
      "echo_shadow",
      "echo(value) { value + 1 }\nmain() { let echo = fn(value) { value * 2 }\nassert (echo(21)) == 42 }",
    )
    == ""
  assert output(
      "echo_module_shadow",
      "echo(value) { value + 1 }\nmain() { assert (echo(41)) == 42 }",
    )
    == ""
}

pub fn echo_checks_arity_test() {
  let assert Ok(report) =
    infer.infer(
      support.expression("{ let inspect = echo\ninspect(1, 2) }"),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert list.length(report.diagnostics) == 1
}

// Prefix echo should observe the full expression following it. Stopping at
// its first operand would print a different value while leaving plausible-
// looking syntax.
pub fn prefix_echo_consumes_the_complete_expression_test() {
  let assert ast.Call(
    ast.Variable("echo", _),
    [ast.Binary(ast.Add, _, _, _)],
    _,
  ) = support.expression("echo 40 + 2")
  assert output(
      "echo_prefix",
      "main() { let value = echo 40 + 2\necho #(value, True) }",
    )
    == "42\n#(42, True)\n"
  assert output(
      "echo_prefix_block",
      "main() { echo { let value = 40\nvalue + 2 } }",
    )
    == "42\n"
}

pub fn main_return_values_are_not_implicitly_printed_test() {
  assert output("silent_integer_main", "main() { 42 }") == ""
  assert output("silent_tuple_main", "main() { #(6, 2, 3, 2) }") == ""
  assert output("silent_string_main", "main() { \"no automatic output\" }")
    == ""
}

pub fn echo_debug_metadata_and_clean_values_are_preserved_in_real_output_test() {
  use directory <- support.with_directory("echo_debug_format")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nclass Box { let value: String\nnew(value) { self.value = value } }\nmain() {\n  echo #(\"hello\", True, Some(2), Error(\"invalid port\"))\n  echo Box(\"Pooka\")\n}\n",
  )
  let report = raw_cli.main(["run"], pooka.version, command.plain(directory))
  assert report.status == 0
  assert report.stdout
    == "src/main.pooka:5\n#(\"hello\", True, Some(2), Error(\"invalid port\"))\nsrc/main.pooka:6\nBox(\"Pooka\")\n"
  birdie.snap(report.stdout, "echo source metadata and clean syntax")
}

@external(erlang, "echo_test_ffi", "coloured")
fn coloured(no_colour: Bool) -> String

pub fn echo_location_is_light_grey_and_value_remains_uncoloured_test() {
  assert coloured(False)
    == "\u{001b}[38;2;139;148;168msrc/main.pooka:3\u{001b}[0m\n42\n"
  assert coloured(True) == "src/main.pooka:3\n42\n"
}
