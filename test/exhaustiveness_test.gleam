//// An uncovered corner still belongs to the room.
////
//// Check coverage and unreachable branches for finite constructors, recursive
//// lists, tuples and binary layouts. Guards do not establish totality. Static
//// bit proofs must account for encoding, alignment and lengths without turning
//// an unknown dynamic layout into a false guarantee.
////
//// ```pooka
//// main(flag: Bool) { match flag { True -> 1 False -> 0 } }
//// ```

import birdie
import compiler/parser/ast
import compiler/typesystem/exhaustiveness
import compiler/typesystem/infer
import compiler/typesystem/monotype as types
import compiler/typesystem/unify
import diagnostics/diagnostic
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import support
import utilities/location

fn check(source: String) -> List(diagnostic.Diagnostic) {
  let assert Ok(report) =
    infer.infer(
      support.expression(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  report.diagnostics
}

fn ids(source: String) -> List(String) {
  list.map(check(source), fn(value) { value.id })
}

pub fn finite_constructor_domains_test() {
  assert ids("match True { True -> 1 }") == ["type.non_exhaustive_match"]
  assert ids("match Nil { Nil -> 1 }") == []
  assert ids("match Some(True) { Some(True) -> 1\nNone -> 0 }")
    == ["type.non_exhaustive_match"]
  assert ids("match Ok(True) { Ok(True) -> 1\nOk(False) -> 2\nError(_) -> 0 }")
    == []
  assert ids(
      "match Some(True) { Some(True) -> 1\nSome(False) -> 2\nNone -> 0 }",
    )
    == []
}

pub fn tuples_require_all_combinations_test() {
  assert ids("match #(True, False) { #(True, _) -> 1\n#(_, True) -> 2 }")
    == ["type.non_exhaustive_match"]
  assert ids(
      "match #(True, False) { #(True, _) -> 1\n#(False, True) -> 2\n#(False, False) -> 3 }",
    )
    == []
}

pub fn recursive_lists_terminate_and_preserve_lengths_test() {
  assert ids("match [True] { [] -> 0\n[_, ..] -> 1 }") == []
  assert ids("match [True] { [] -> 0\n[_] -> 1 }")
    == ["type.non_exhaustive_match"]
  assert ids("match [True] { [] -> 0\n[True, ..] -> 1\n[False, ..] -> 2 }")
    == []
  assert ids("match [True] { [] -> 0\n[_, ..] -> 1\n[True, False] -> 2 }")
    == ["type.unreachable_pattern"]
}

// A matching pattern with a failing guard leaves the subject uncovered.
// Coverage must account for that path even if the body would return a value.
pub fn guards_do_not_establish_coverage_test() {
  assert ids("match True { True if True -> 1\nFalse -> 0 }")
    == ["type.non_exhaustive_match"]
  assert ids("match True { True if True -> 1\nTrue -> 2\nFalse -> 0 }") == []
  assert ids("match True { _ -> 0\nTrue if True -> 1 }")
    == ["type.unreachable_pattern"]
}

pub fn equivalent_literal_spellings_are_unreachable_test() {
  assert ids("match 16 { 0x10 -> 1\n1_6 -> 2\n_ -> 0 }")
    == ["type.unreachable_pattern"]
  assert ids("match 1.0 { 1.0 -> 1\n1.00e0 -> 2\n_ -> 0 }")
    == ["type.unreachable_pattern"]
  assert ids("match \"a\" { \"a\" -> 1\n\"\\u{61}\" -> 2\n_ -> 0 }")
    == ["type.unreachable_pattern"]
  assert ids("match 1 { 1 -> 0\n2 -> 1 }") == ["type.non_exhaustive_match"]
}

pub fn binary_layouts_require_coverage_but_prior_errors_do_not_cascade_test() {
  assert ids("match <<1>> { <<x:8>> -> x }") == ["type.non_exhaustive_match"]
  assert ids("match #(<<1>>, True) { #(<<x:8>>, True) -> x }")
    == ["type.non_exhaustive_match"]
  assert ids("match True { True -> 1\nFalse -> \"bad\" }")
    == ["type.unification"]
}

pub fn coverage_diagnostics_snapshot_test() {
  [
    "match Some(True) { None -> 0\nSome(True) -> 1 }",
    "match #(True, False) { #(True, _) -> 1\n#(_, True) -> 2 }",
    "match [True] { [] -> 0\n[_] -> 1 }",
    "match True { _ -> 0\nTrue -> 1 }",
  ]
  |> list.map(fn(source) {
    support.render_all(
      check(source),
      "module main\n\nexample() {\n" <> source <> "\n}\n",
    )
  })
  |> string.join("\n---\n")
  |> birdie.snap(title: "types match coverage and unreachable branches")
}

// A small finite domain supplies an independent reference. Compare the
// coverage decision with enumeration of the actual Boolean pairs.
pub fn boolean_pair_coverage_matches_finite_enumeration_test() {
  let span = location.between(location.start(), location.start())
  let shapes = [
    #(1, 1),
    #(1, 2),
    #(2, 1),
    #(2, 2),
    #(0, 1),
    #(0, 2),
    #(1, 0),
    #(2, 0),
    #(0, 0),
  ]
  let subsets =
    list.fold(shapes, [[]], fn(subsets, shape) {
      list.append(subsets, list.map(subsets, fn(subset) { [shape, ..subset] }))
    })
  list.each(subsets, fn(shapes) {
    let branches =
      list.map(shapes, fn(shape) {
        ast.Branch(
          ast.TuplePattern(
            [boolean_pattern(shape.0, span), boolean_pattern(shape.1, span)],
            span,
          ),
          None,
          ast.NilLiteral(span),
          span,
        )
      })
    let expected =
      list.all([#(1, 1), #(1, 2), #(2, 1), #(2, 2)], fn(value) {
        list.any(shapes, fn(shape) {
          { shape.0 == 0 || shape.0 == value.0 }
          && { shape.1 == 0 || shape.1 == value.1 }
        })
      })
    let diagnostics =
      exhaustiveness.check(
        types.TupleType([types.BoolType, types.BoolType]),
        branches,
        support.path,
        span,
      )
    let missing =
      list.any(diagnostics, fn(value) {
        value.id == "type.non_exhaustive_match"
      })
    assert missing == !expected

    let #(_, redundant) =
      list.fold(shapes, #([], 0), fn(acc, shape) {
        let #(covered, redundant) = acc
        let values =
          list.filter([#(1, 1), #(1, 2), #(2, 1), #(2, 2)], fn(value) {
            { shape.0 == 0 || shape.0 == value.0 }
            && { shape.1 == 0 || shape.1 == value.1 }
          })
        let adds_value =
          list.any(values, fn(value) { !list.contains(covered, value) })
        #(
          list.unique(list.append(covered, values)),
          redundant
            + case adds_value {
            True -> 0
            False -> 1
          },
        )
      })
    assert list.count(diagnostics, fn(value) {
        value.id == "type.unreachable_pattern"
      })
      == redundant
  })
}

fn boolean_pattern(value: Int, span: location.Span) -> ast.Pattern {
  case value {
    0 -> ast.DiscardPattern(span)
    1 -> ast.BoolPattern(True, span)
    _ -> ast.BoolPattern(False, span)
  }
}

pub fn binary_patterns_cover_static_prefixes_and_empty_bitstrings_test() {
  assert ids(
      "match <<>> { <<>> -> 0\n<<0:1, _:bits>> -> 1\n<<1:1, _:bits>> -> 2 }",
    )
    == []
  assert ids("match <<>> { <<0:1, _:bits>> -> 1\n<<1:1, _:bits>> -> 2 }")
    == ["type.non_exhaustive_match"]
  assert ids("match <<>> { <<>> -> 0\n<<_:1, _:bits>> -> 1 }") == []
}

pub fn binary_pattern_coverage_finds_duplicate_and_subsumed_prefixes_test() {
  assert ids(
      "match <<>> { <<1:1, _:bits>> -> 1\n<<1:1, 0:1, _:bits>> -> 2\n_ -> 0 }",
    )
    == ["type.unreachable_pattern"]
  assert ids("match <<>> { <<_:bits>> -> 1\n<<>> -> 0 }")
    == ["type.unreachable_pattern"]
  assert ids("match <<>> { <<1>> -> 1\n<<0x01:8>> -> 2\n_ -> 0 }")
    == ["type.unreachable_pattern"]
}

pub fn binary_pattern_proofs_respect_endianness_and_text_encoding_test() {
  assert ids(
      "match <<>> { <<0x1234:16-big>> -> 1\n<<0x3412:16-little>> -> 2\n_ -> 0 }",
    )
    == ["type.unreachable_pattern"]
  assert ids("match <<>> { <<\"a\":utf8>> -> 1\n<<97:8>> -> 2\n_ -> 0 }")
    == ["type.unreachable_pattern"]
  assert ids(
      "match <<>> { <<\"a\":utf16-little>> -> 1\n<<97:8, 0:8>> -> 2\n_ -> 0 }",
    )
    == ["type.unreachable_pattern"]
}

pub fn binary_coverage_checks_nested_patterns_and_guards_test() {
  assert ids(
      "match Some(<<>>) { None -> 0\nSome(<<>>)-> 1\nSome(<<_:1, _:bits>>)-> 2 }",
    )
    == []
  assert ids(
      "match #(<<>>, True) { #(<<_:bits>>, _) -> 0\n#(<<1>>, True) -> 1 }",
    )
    == ["type.unreachable_pattern"]
  assert ids("match <<>> { <<_:bits>> if True -> 1 }")
    == ["type.non_exhaustive_match"]
}

// A dynamic width is not a constant proof, and byte alignment does not cover
// every bitstring. Keep uncertainty rather than declaring an incomplete match
// total.
pub fn dynamic_and_aligned_layouts_cannot_establish_false_totality_test() {
  assert ids(
      "fn(size: Int, bits: BitArray) { match bits { <<_:size(size)>> -> Nil } }",
    )
    == ["type.non_exhaustive_match"]
  assert ids("match <<>> { <<_:bytes>> -> Nil }")
    == ["type.non_exhaustive_match"]
  assert ids("match <<>> { <<_:bits-unit(8)>> -> Nil }")
    == ["type.non_exhaustive_match"]
  assert ids("match <<>> { <<_:1000000000>> -> Nil\n_ -> Nil }") == []
}

pub fn binary_missing_witness_snapshot_test() {
  check("match <<>> { <<>> -> 0\n<<0:1, _:bits>> -> 1 }")
  |> support.pretty
  |> birdie.snap(title: "types binary pattern missing witness")
}

pub fn binary_prefix_partitions_cover_all_lengths_only_when_complete_test() {
  let patterns = ["<<>>", "<<0:1, _:bits>>", "<<1:1, _:bits>>"]
  list.each([1, 2, 3, 4, 5, 6, 7], fn(mask) {
    let branches =
      list.index_map(patterns, fn(pattern, index) {
        #(pattern, int.bitwise_shift_left(1, index))
      })
      |> list.filter_map(fn(pair) {
        case int.bitwise_and(mask, pair.1) != 0 {
          True -> Ok(pair.0 <> " -> 0")
          False -> Error(Nil)
        }
      })
      |> string.join("\n")
    let diagnostics = ids("match <<>> { " <> branches <> " }")
    assert list.contains(diagnostics, "type.non_exhaustive_match")
      == { mask != 7 }
  })
}

pub fn partial_little_endian_and_signed_literals_have_exact_bit_proofs_test() {
  assert ids(
      "match <<>> { <<0xabc:12-little>> -> 1\n<<0xbc:8, 0xa:4>> -> 2\n_ -> 0 }",
    )
    == ["type.unreachable_pattern"]
  assert ids("match <<>> { <<-1:8-signed>> -> 1\n<<255:8>> -> 2\n_ -> 0 }")
    == ["type.unreachable_pattern"]
}
