//// The slash always arrives with a fraction in its pocket.
////
//// Division follows Python 3: every combination of Int and Float operands
//// returns a Float, even when the quotient is whole, so a type never depends
//// on a particular value. Integer division belongs to `int.divide`. Zero
//// divisors remain runtime failures, distinct from compile-time operand
//// compatibility.
////
//// ```pooka
//// main() { #(7 / 2, -7 / 2, 4 / 2, 7.0 / 2) }
//// ```

import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import gleam/dict
import support

pub fn all_numeric_division_combinations_typecheck_test() {
  let assert Ok(report) =
    module_infer.infer(
      support.parse(
        "module main\nii(a: Int, b: Int) -> Float { a / b }\nfi(a: Float, b: Int) -> Float { a / b }\nff(a: Float, b: Float) -> Float { a / b }\nifloat(a: Int, b: Float) -> Float { a / b }",
      ),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert report.diagnostics == []
}

pub fn integer_division_cannot_claim_an_int_return_test() {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\ndivide(a: Int, b: Int) -> Int { a / b }"),
      dict.new(),
      unify.new(),
      support.path,
    )
  assert report.diagnostics != []
}

// Whole quotients stay Float, so `4 / 2` is `2.0`, not `2`. Negative and
// huge operands follow Erlang's float division.
pub fn division_runtime_always_returns_float_test() {
  use directory <- support.with_directory("division_primitive_semantics")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nii(a: Int, b: Int) -> Float { a / b }\nfi(a: Float, b: Int) -> Float { a / b }\nff(a: Float, b: Float) -> Float { a / b }\nifloat(a: Int, b: Float) -> Float { a / b }\nmain() { assert ii(5, 2) == 2.5\nassert ii(-5, 2) == -2.5\nassert ii(4, 2) == 2.0\nassert ii(0, 2) == 0.0\nassert fi(5.0, 2) == 2.5\nassert ff(5.0, 2.0) == 2.5\nassert ifloat(5, 2.0) == 2.5\nassert ii(100000000000000000000, 2) == 50000000000000000000.0\necho #(5 / 2, 4 / 2, 5.0 / 2, 5.0 / 2.0, 5 / 2.0) }",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 0
  assert outcome.stdout == "#(2.5, 2.0, 2.5, 2.5, 2.5)\n"
}

pub fn division_by_zero_still_fails_at_runtime_test() {
  use directory <- support.with_directory("division_zero")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { let zero = 0\necho (1 / zero) }",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 1
}
