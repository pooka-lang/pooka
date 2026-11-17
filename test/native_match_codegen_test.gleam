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
