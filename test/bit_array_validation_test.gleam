//// Measure the parcel before sealing it.
////
//// Check segment modifiers, constant widths and alignment before code
//// generation. Static layout proofs must reject impossible literals without
//// allocating their declared size. Unknown dynamic layouts remain runtime
//// questions, and an earlier type error must not grow a second forest of
//// layout errors.
////
//// ```pooka
//// main() { <<1:8, 2:8>> }
//// ```

import birdie
import compiler/typesystem/infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string
import support

fn check(source: String) -> infer.Inferred {
  let assert Ok(report) =
    infer.infer(
      support.expression(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

fn ids(source: String) -> List(String) {
  list.map(check(source).diagnostics, fn(value) { value.id })
}

// A segment can accumulate compatible options in either order, but duplicate
// or contradictory choices must be diagnosed before lowering.
pub fn duplicate_and_conflicting_modifiers_test() {
  list.each(
    [
      "<<1:big-little>>",
      "<<1:signed-unsigned>>",
      "<<1:size(8)-size(16)>>",
      "<<1:unit(1)-unit(2)>>",
      "<<1:big-big>>",
    ],
    fn(source) {
      assert ids(source) == ["type.duplicate_bit_array_option"]
    },
  )
}

pub fn modifiers_depend_on_representation_in_any_order_test() {
  list.each(
    [
      "<<1.0:float-signed>>",
      "<<1.0:unsigned-float>>",
      "<<\"x\":utf8-little>>",
      "<<\"x\":big-utf8>>",
      "<<<<1>>:bytes-native>>",
      "<<<<1>>:signed-bits>>",
      "<<\"x\":utf16-size(16)>>",
      "<<\"x\":unit(8)-utf32>>",
    ],
    fn(source) {
      assert ids(source) == ["type.incompatible_bit_array_option"]
    },
  )
  assert ids(
      "<<1:signed-little, 1.0:float-big, \"x\":utf16-little, \"x\":native-utf32>>",
    )
    == []
}

pub fn literal_sizes_and_unit_bounds_test() {
  assert ids("<<1:size(-1)>>") == ["type.invalid_bit_array_size"]
  assert ids("<<1:unit(0)>>") == ["type.invalid_bit_array_unit"]
  assert ids("<<1:unit(257)>>") == ["type.invalid_bit_array_unit"]
  assert ids("<<1:unit(-1)>>") == ["type.invalid_bit_array_unit"]
  assert ids("<<1:size(0), 1:unit(256), 1:unit(1)>>") == []
  assert ids("fn(size) { <<1:size(size)-unit(2 * 4)>> }") == []
  assert ids("fn(size, unit) { <<1:size(size)-unit(unit)>> }")
    == ["type.non_constant_bit_array_unit"]
}

pub fn float_width_accounts_for_units_test() {
  assert ids("<<1.0:float-size(8)>>") == ["type.invalid_float_segment_size"]
  assert ids("<<1.0:float-size(0)>>") == ["type.invalid_float_segment_size"]
  assert ids("<<1.0:float-unit(2)>>") == ["type.invalid_float_segment_size"]
  assert ids("<<1.0:float-size(2)-unit(8), 1.0:float-size(32), 1.0:float>>")
    == []
  assert ids("fn(size) { <<1.0:float-size(size)>> }") == []

  assert ids("<<1.0:float-size(-1)>>") == ["type.invalid_bit_array_size"]
}

pub fn unsized_binary_patterns_must_be_last_test() {
  assert ids("fn(bytes) { let <<rest:bits, value:8>> = bytes\nvalue }")
    == ["type.unsized_bit_array_pattern_segment"]
  assert ids("fn(bytes) { let <<rest:bytes, value:8>> = bytes\nvalue }")
    == ["type.unsized_bit_array_pattern_segment"]
  assert ids("fn(bytes) { let <<rest:bits-size(8), value:8>> = bytes\nvalue }")
    == []
  assert ids("fn(bytes) { let <<value:8, rest:bits>> = bytes\nvalue }") == []
  assert ids("fn(rest) { <<rest:bits, 1>> }") == []
}

pub fn pattern_options_receive_the_same_validation_test() {
  assert ids("fn(bytes, unit) { let <<value:unit(unit)>> = bytes\nvalue }")
    == ["type.non_constant_bit_array_unit"]
  assert ids("fn(bytes) { let <<value:unit(0)>> = bytes\nvalue }")
    == ["type.invalid_bit_array_unit"]
  assert ids("fn(bytes) { let <<value:float-size(8)>> = bytes\nvalue }")
    == ["type.invalid_float_segment_size"]
}

pub fn bit_array_validation_diagnostics_snapshot_test() {
  [
    "<<1:big-little>>",
    "<<\"x\":utf8-size(8)>>",
    "<<1.0:float-size(8)>>",
    "fn(unit) { <<1:unit(unit)>> }",
    "fn(bytes) { let <<rest:bits, value:8>> = bytes\nvalue }",
  ]
  |> list.map(fn(source) {
    support.render_all(
      check(source).diagnostics,
      "module main\n\nexample() {\n" <> source <> "\n}\n",
    )
  })
  |> string.join("\n---\n")
  |> birdie.snap(title: "types bit array validation diagnostics")
}

pub fn literal_binary_alignment_and_length_test() {
  assert ids("<<<<1:1>>:bytes>>") == ["type.unaligned_bit_array_segment"]
  assert ids("<<<<1:1>>:bits>>") == []
  assert ids("<<<<1:1>>:bits-unit(8)>>") == ["type.unaligned_bit_array_segment"]
  assert ids("<<<<1>>:bits-size(9)>>") == ["type.short_bit_array_segment"]
  assert ids("<<<<1>>:bytes-size(2)>>") == ["type.short_bit_array_segment"]
  assert ids("<<<<1, 2>>:bytes-size(1)>>") == []
  assert ids("<<<<1:1>>:bits-size(0)>>") == []
  assert ids("fn(payload, size) { <<payload:bytes-size(size)>> }") == []
}

pub fn unicode_literal_widths_count_encoded_bits_test() {
  assert ids("<<<<\"\\u{1f600}\":utf8>>:bytes-size(4)>>") == []
  assert ids("<<<<\"😀\":utf16>>:bytes-size(4)>>") == []
  assert ids("<<<<\"😀\":utf32>>:bytes-size(4)>>") == []
  assert ids("<<<<\"é\":utf8>>:bytes-size(3)>>")
    == ["type.short_bit_array_segment"]
  assert ids("<<<<\"é\":utf16>>:bytes-size(3)>>")
    == ["type.short_bit_array_segment"]
  assert ids("<<<<\"é\":utf32>>:bytes-size(4)>>") == []
}

// Static analysis needs the resulting width and low bits, not a materialized
// binary of that size. Very large declared widths make accidental allocation
// costly.
pub fn numeric_values_truncate_and_static_widths_do_not_allocate_test() {
  assert ids("<<256:8, -1:8, 1:size(100000000000000000000)>>") == []
  assert ids("fn(value) { <<<<value:1>>:bytes>> }")
    == ["type.unaligned_bit_array_segment"]

  assert ids("<<<<<<1:1>>:bytes>>:bytes-size(2)>>")
    == ["type.unaligned_bit_array_segment"]
}

pub fn nested_literal_layout_diagnostics_snapshot_test() {
  ["<<<<1:1>>:bytes>>", "<<<<1>>:bytes-size(2)>>"]
  |> list.map(fn(source) {
    support.render_all(
      check(source).diagnostics,
      "module main\n\nexample() {\n" <> source <> "\n}\n",
    )
  })
  |> string.join("\n---\n")
  |> birdie.snap(title: "types literal binary layout diagnostics")
}

pub fn arithmetic_constant_layout_proofs_test() {
  assert ids("<<1:size(4 - 5)>>") == ["type.invalid_bit_array_size"]
  assert ids("<<1:unit(128 * 3)>>") == ["type.invalid_bit_array_unit"]
  assert ids("<<1.0:float-size(2 * 8)>>") == []
  assert ids("<<1.0:float-size(2 * 7)>>") == ["type.invalid_float_segment_size"]
  assert ids("<<<<1:size(2 * 4)>>:bytes-size(1 + 1)>>")
    == ["type.short_bit_array_segment"]
  assert ids("<<<<1:size(2 + 6)>>:bytes>>") == []
  // Division always produces a Float, which can never be a segment size.
  assert ids("<<1:size(8 / 2)>>") != []
}

pub fn utf_literal_prefix_patterns_infer_typed_binary_tails_test() {
  let report =
    check("fn(bytes) { let <<\"Pooka\":utf8, rest:bits>> = bytes\nrest }")
  assert monotype.to_string(report.type_) == "fn(BitArray) -> BitArray"
  assert ids(
      "fn(bytes) { match bytes { <<\"Pooka\":utf8, rest:bits>> -> rest\n_ -> <<>> } }",
    )
    == []
  assert ids(
      "fn(bytes) { let <<\"😀\":utf16-little, rest:bits>> = bytes\nrest }",
    )
    == []
  assert ids("fn(bytes) { let <<\"\\u{61}\":utf32-big>> = bytes\nNil }") == []
  assert ids("fn(bytes) { let <<\"x\":utf8-size(8)>> = bytes\nNil }")
    == ["type.incompatible_bit_array_option"]
}

// Nested constant parcels must not send layout analysis around an unbounded
// recursive walk. This fixture exercises the depth handling without
// allocating the promised payload.
pub fn deeply_nested_literal_layout_analysis_terminates_test() {
  let source =
    list.fold(list.repeat(Nil, 40), "<<1>>", fn(source, _) {
      "<<" <> source <> ":bytes>>"
    })
  assert ids(source) == []
}

// Once the payload type is wrong, a second speculative layout complaint adds
// no useful information. Keep the first error and stop that cascade.
pub fn nested_payload_type_failures_suppress_layout_cascades_test() {
  assert ids("<<<<\"bad\":8>>:bytes-size(2)>>") == ["type.unification"]
  assert ids("<<<<<<<<1:1>>:bytes>>:bytes-size(1)>>:bytes-size(2)>>")
    == ["type.unaligned_bit_array_segment"]
}
