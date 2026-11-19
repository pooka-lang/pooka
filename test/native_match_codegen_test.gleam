//// Plain match arms can be Erlang clauses without building a ladder of funs.
//// Keep a structural regression beside runtime checks: timing alone would be
//// a noisy way to notice that the fallback allocations had crept back in.

// SPDX-License-Identifier: Apache-2.0

import birdie
import cli/command
import compiler/codegen/beam
import compiler/codegen/erlang
import compiler/codegen/forms as f
import compiler/typesystem/module_infer
import compiler/typesystem/typed_ast
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string
import support

fn generate(source: String) -> erlang.Output {
  let syntax = support.parse("module main\n" <> source)
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  let assert Ok(generated) = erlang.generate(typed, "app", "main", dict.new())
  let assert Ok(_) = beam.compile(generated.forms)
  generated
}

fn funs(term: f.Term) -> Int {
  case term {
    f.Tuple([f.Atom("fun"), _, f.Tuple([f.Atom("clauses"), body])]) ->
      1 + funs(body)
    f.Tuple(fields) | f.Sequence(fields) ->
      list.fold(fields, 0, fn(total, field) { total + funs(field) })
    _ -> 0
  }
}

fn run(name: String, source: String) -> command.Outcome {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
  support.cli_main(["run"], command.plain(directory))
}

pub fn unguarded_binary_and_list_matches_do_not_allocate_fallback_funs_test() {
  let generated =
    generate(
      "read(bytes: BitArray) -> Int { match bytes { <<13, 10, rest:bytes>> -> read(rest)\n<<_, rest:bytes>> -> 1 + read(rest)\n<<>> -> 0\n_ -> -1 } }\nfirst(values: List(Int)) { match values { [head, ..tail] -> head\n[] -> 0 } }",
    )
  assert funs(f.Sequence(generated.forms)) == 0
  birdie.snap(
    beam.pretty(generated.forms),
    title: "native match erlang clauses",
  )
}

pub fn overlapping_binary_patterns_keep_their_order_and_partial_bit_fallback_test() {
  let result =
    run(
      "native_match_binary_order",
      "read(bytes: BitArray) { match bytes { <<13, 10, 13, 10, rest:bytes>> -> #(4, rest)\n<<13, 10, rest:bytes>> -> #(2, rest)\n<<byte, rest:bytes>> -> #(byte, rest)\n<<>> -> #(0, <<>>)\n_ -> #(-1, <<>>) } }\nmain() { assert read(<<13, 10, 13, 10, 7>>) == #(4, <<7>>)\nassert read(<<13, 10, 8>>) == #(2, <<8>>)\nassert read(<<9, 8>>) == #(9, <<8>>)\nassert read(<<>>) == #(0, <<>>)\nassert read(<<1:size(1)>>) == #(-1, <<>>) }",
    )
  assert result.status == 0
  assert support.diagnostics(result.stderr) == ""
}

pub fn native_clauses_restore_outer_bindings_after_branch_local_shadowing_test() {
  let result =
    run(
      "native_match_shadowing",
      "read(pair: #(Int, Int)) { let x = 99\nlet chosen = match pair { #(x, 0) -> x\n#(0, x) -> x\n_ -> x }\n#(chosen, x) }\nmain() { assert read(#(4, 0)) == #(4, 99)\nassert read(#(0, 7)) == #(7, 99)\nassert read(#(1, 2)) == #(99, 99) }",
    )
  assert result.status == 0
}

pub fn a_false_effectful_guard_falls_into_native_clauses_without_leaking_bindings_test() {
  let result =
    run(
      "native_match_guard_order",
      "subject() { echo \"subject\"\nSome(4) }\nguard(value: Int) -> Bool { echo value\nFalse }\nmain() { let value = 99\nlet chosen = match subject() { Some(value) if guard(value) -> panic\nSome(4) -> value\n_ -> 0 }\necho chosen }",
    )
  assert result.status == 0
  assert result.stdout == "\"subject\"\n4\n99\n"
}

pub fn non_catch_all_native_matches_keep_the_runtime_failure_clause_test() {
  let generated =
    generate("choose(value: Bool) { match value { True -> 1\nFalse -> 2 } }")
  let text = beam.pretty(generated.forms)
  assert funs(f.Sequence(generated.forms)) == 0
  assert string.contains(text, "pooka_match_failure")
}

pub fn local_function_calls_name_the_function_directly_test() {
  let generated = generate("step(n: Int) -> Int { n + 1 }\nmain() { step(2) }")
  let text = beam.pretty(generated.forms)
  assert string.contains(text, "step(")
  assert !string.contains(text, "fun step/1")
}

pub fn local_function_values_and_shadowing_keep_their_meaning_test() {
  let outcome =
    run(
      "direct_call_shadowing",
      "step(n: Int) -> Int { n + 1 }\napply(step: fn(Int) -> Int) { step(5) }\nmain() { let saved = step\nlet step = fn(n: Int) { n * 2 }\nassert step(4) == 8\nassert saved(4) == 5\nassert apply(step) == 10 }",
    )
  assert outcome.status == 0
}

pub fn guard_safe_guards_become_erlang_clause_guards_test() {
  let generated =
    generate(
      "digits(bytes: BitArray, total: Int) -> Int { match bytes { <<c, rest:bytes>> if c >= 48 && c <= 57 -> digits(rest, total * 10 + c - 48)\n<<>> -> total\n_ -> -1 } }",
    )
  assert funs(f.Sequence(generated.forms)) == 0
}

pub fn guards_erlang_cannot_evaluate_keep_the_ordered_path_test() {
  let generated =
    generate(
      "even(n: Int) -> Bool { n % 2 == 0 }\npick(values: List(Int)) -> Int { match values { [n, ..] if even(n) -> n\n[n, ..] if n / 2 > 1.0 -> n + 1\n_ -> 0 } }",
    )
  assert funs(f.Sequence(generated.forms)) > 0
}

pub fn native_guards_fall_through_in_order_and_see_pattern_and_outer_bindings_test() {
  let result =
    run(
      "native_match_guards",
      "classify(pair: #(Int, Int), limit: Int) -> String { match pair { #(a, b) if a > limit && b > limit -> \"both\"\n#(a, _) if a > limit -> \"first\"\n#(_, b) if b > limit || b == -1 -> \"second\"\n#(a, b) if a == b -> \"same\"\n_ -> \"neither\" } }\nmain() { assert classify(#(5, 6), 3) == \"both\"\nassert classify(#(5, 1), 3) == \"first\"\nassert classify(#(1, 9), 3) == \"second\"\nassert classify(#(1, -1), 3) == \"second\"\nassert classify(#(2, 2), 3) == \"same\"\nassert classify(#(1, 2), 3) == \"neither\" }",
    )
  assert result.status == 0
  assert support.diagnostics(result.stderr) == ""
}

pub fn a_guard_that_fails_every_arm_is_a_match_failure_test() {
  let result =
    run(
      "native_match_guard_failure",
      "pick(n: Int) -> Int { match n { x if x > 10 -> x\n0 -> 0 } }\nmain() { assert pick(11) == 11\nassert pick(0) == 0\nlet _ = pick(5) }",
    )
  assert result.status != 0
}

pub fn floating_arithmetic_guards_keep_errors_on_the_ordered_path_test() {
  let generated =
    generate(
      "pick(n: Float) -> Int { match n { x if x * x > 1.0 -> 1\n_ -> 0 } }",
    )
  assert funs(f.Sequence(generated.forms)) > 0
  let outcome =
    run(
      "overflowing_match_guard",
      "pick(n: Float) -> Int { match n { x if x * x > 1.0 -> 1\n_ -> 0 } }\nmain() { let _ = pick(1.0e308) }",
    )
  assert outcome.status != 0
}

pub fn integer_arithmetic_and_boolean_guards_need_no_fallback_funs_test() {
  let generated =
    generate(
      "pick(n: Int, enabled: Bool) -> Int { match n { x if !enabled || ((x + 2) * 3 - 1 & 7 | 8) != 0 -> x\n_ -> 0 } }",
    )
  assert funs(f.Sequence(generated.forms)) == 0
}
