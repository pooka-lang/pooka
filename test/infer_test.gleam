//// Let constraints arrive before deciding what a value can be.
////
//// Infer small expressions in a fresh environment and inspect both types and
//// diagnostics. Scope, captured variables, propagation and patterns share
//// constraints, while overloaded primitive operators may need later
//// annotations before settling. Error recovery must not turn one bad name into
//// many invented failures.
////
//// ```pooka
//// identity(value) { value }
//// main() { #(identity(1), identity("tea")) }
//// ```

import birdie
import compiler/parser/ast
import compiler/typesystem/infer
import compiler/typesystem/monotype as types
import compiler/typesystem/scheme
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import support

fn expression(source: String) -> infer.Inferred {
  let assert Ok(report) =
    infer.infer(
      support.expression(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

/// Reject diagnostics before displaying the inferred type. Tests that expect
/// recovery types inspect the full report instead of treating a displayed type
/// as success.
fn type_of(source: String) -> String {
  let report = expression(source)
  assert report.diagnostics == []
  types.to_string(report.type_)
}

pub fn literal_and_collection_types_test() {
  assert type_of("1") == "Int"
  assert type_of("1.5") == "Float"
  assert type_of("\"hello\"") == "String"
  assert type_of("True") == "Bool"
  assert type_of("Nil") == "Nil"
  assert type_of("[1, 2]") == "List(Int)"
  assert type_of("[]") == "List(a)"
  assert type_of("#(1, \"hello\", True)") == "#(Int, String, Bool)"
}

pub fn list_elements_must_agree_test() {
  let report = expression("[1, \"wrong\"]")
  assert list.length(report.diagnostics) == 1
  assert types.to_string(report.type_) == "List(Int)"
}

pub fn closure_and_application_inference_test() {
  assert type_of("fn(x) { x }") == "fn(a) -> a"
  assert type_of("{ let identity = fn(x) { x }\nidentity(1) }") == "Int"
  assert type_of(
      "{ let identity = fn(x) { x }\n#(identity(1), identity(\"s\")) }",
    )
    == "#(Int, String)"
}

// The closure may get fresh parameters at each use, but a captured value is
// still one shared value. Generalizing it would allow incompatible uses of
// the same capture.
pub fn captured_values_remain_monomorphic_test() {
  let report =
    expression(
      "fn(value) {\n  let captured = fn(_) { value }\n  let a: Int = captured(Nil)\n  let b: String = captured(Nil)\n  value\n}",
    )
  assert list.length(report.diagnostics) == 1
}

pub fn lexical_scope_does_not_leak_from_blocks_test() {
  let report = expression("{ { let x = 1 }\nx }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
  assert type_of("{ let x = 1\n{ let x = \"s\"\nx }\nx }") == "Int"
}

pub fn binding_annotations_and_discarded_bindings_test() {
  assert type_of("{ let x: Int = 1\nx }") == "Int"
  assert type_of("{ let _ = 1 }") == "Nil"
  assert type_of("{ let x = 1 }") == "Nil"
  let report = expression("{ let x: String = 1\nx }")
  assert list.length(report.diagnostics) == 1
  assert report.type_ == types.ErrorType
}

pub fn annotated_parameters_and_higher_order_calls_test() {
  assert type_of("fn(x: Int) { x }") == "fn(Int) -> Int"
  assert type_of("fn(f: fn(Int) -> String) { f(1) }")
    == "fn(fn(Int) -> String) -> String"
  assert type_of("fn(f, x) { f(x) }") == "fn(fn(a) -> b, a) -> b"
}

pub fn wrong_argument_types_and_arities_test() {
  let report = expression("{ let f = fn(x: Int) { x }\nf(\"wrong\") }")
  assert list.length(report.diagnostics) == 1
  let report = expression("{ let f = fn(x) { x }\nf() }")
  assert list.length(report.diagnostics) == 1
  let report = expression("{ let f = 1\nf() }")
  assert list.length(report.diagnostics) == 1
}

pub fn repeated_function_parameters_are_shared_types_test() {
  let report = expression("fn(f) { #(f(1), f(\"wrong\")) }")
  assert list.length(report.diagnostics) == 1
}

pub fn unknown_names_report_once_and_suppress_call_cascades_test() {
  let report = expression("missing(1)")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
  assert report.type_ == types.ErrorType
}

pub fn boolean_and_equality_operations_test() {
  assert type_of("!True") == "Bool"
  assert type_of("True && False") == "Bool"
  assert type_of("1 == 2") == "Bool"
  assert type_of("\"a\" != \"b\"") == "Bool"
  assert list.length(expression("1 && True").diagnostics) == 1
  assert list.length(expression("1 == \"s\"").diagnostics) == 1
}

// Applying a value to itself asks its type to contain itself. The occurs
// check rejects that infinite shape rather than recursing indefinitely.
pub fn self_application_fails_the_occurs_check_test() {
  let report = expression("fn(f) { f(f) }")
  assert list.length(report.diagnostics) == 1
  let assert [value] = report.diagnostics
  assert value.title == "infinite type"
}

pub fn unsupported_syntax_is_explicit_test() {
  let assert Error(_) =
    infer.infer(
      support.expression("fn(x: user.User) { x }"),
      dict.new(),
      unify.new(),
      support.path,
    )
}

pub fn named_function_return_annotations_are_checked_test() {
  let module = support.parse("module main\nf() -> String { 1 }")
  let assert [ast.FunctionDeclaration(function)] = module.declarations
  let assert Ok(report) =
    infer.infer_function(function, dict.new(), unify.new(), support.path)
  assert list.length(report.diagnostics) == 1
}

pub fn polymorphic_inference_snapshot_test() {
  expression(
    "{\n let identity = fn(x) { x }\n #(identity(1), identity(\"hello\"), identity(True))\n}",
  )
  |> fn(report) { #(types.to_string(report.type_), report.diagnostics) }
  |> support.pretty
  |> birdie.snap(title: "types: polymorphic expression inference")
}

pub fn arithmetic_follows_pooka_primitive_rules_test() {
  assert type_of("1 + 2") == "Int"
  assert type_of("1.0 + 2.0") == "Float"
  assert type_of("\"Hello, \" + \"Pooka\"") == "String"
  assert type_of("5 / 2") == "Float"
  assert type_of("5.0 / 2.0") == "Float"
  assert type_of("5 % 2") == "Int"
  assert type_of("5.0 % 2.0") == "Float"
  assert type_of("1 < 2") == "Bool"
  assert type_of("-1") == "Int"
  assert type_of("-1.0") == "Float"
}

pub fn mixed_numeric_operations_require_explicit_conversion_test() {
  assert list.length(expression("1 + 2.0").diagnostics) == 1
  assert list.length(expression("5.0 % 2").diagnostics) == 1
  assert type_of("5 / 2.0") == "Float"
  assert type_of("5.0 / 2") == "Float"
  assert list.length(expression("\"a\" < \"b\"").diagnostics) == 1
  assert list.length(expression("True + False").diagnostics) == 1
}

pub fn arithmetic_can_infer_from_one_concrete_operand_test() {
  assert type_of("fn(x) { x + 1 }") == "fn(Int) -> Int"
  assert type_of("fn(x: Float) { x * 2.0 }") == "fn(Float) -> Float"
}

pub fn pipes_insert_the_value_as_first_argument_test() {
  assert type_of("{ let identity = fn(x) { x }\n1 |> identity() }") == "Int"
  assert type_of("{ let first = fn(x, _) { x }\n1 |> first(\"other\") }")
    == "Int"
  assert type_of("{ let identity = fn(x) { x }\n1 |> identity }") == "Int"
}

pub fn core_option_and_result_constructors_are_polymorphic_test() {
  assert type_of("Some(1)") == "Option(Int)"
  assert type_of("None") == "Option(a)"
  assert type_of("Ok(1)") == "Result(Int, a)"
  assert type_of("Error(\"bad\")") == "Result(a, String)"
  assert type_of("#(Some(1), Some(\"s\"))") == "#(Option(Int), Option(String))"
}

pub fn tuple_and_list_bindings_infer_component_types_test() {
  assert type_of("{ let #(x, y) = #(1, \"s\")\n#(y, x) }") == "#(String, Int)"
  assert type_of("{ let [head, ..tail] = [1, 2]\n#(head, tail) }")
    == "#(Int, List(Int))"
  assert type_of("{ let #(f, _) = #(fn(x) { x }, Nil)\n#(f(1), f(\"s\")) }")
    == "#(Int, String)"
}

pub fn destructuring_type_mismatches_are_reported_test() {
  assert list.length(expression("{ let #(x, y) = 1\nx }").diagnostics) == 1
  assert list.length(expression("{ let [x] = 1\nx }").diagnostics) == 1
  assert list.length(expression("{ let #(x, y) = #(1)\nx }").diagnostics) == 1
}

pub fn match_branches_infer_shared_subject_and_result_types_test() {
  assert type_of("fn(value) { match value { True -> 1\nFalse -> 2 } }")
    == "fn(Bool) -> Int"
  assert type_of("fn(value) { match value { Some(x) -> x\nNone -> 0 } }")
    == "fn(Option(Int)) -> Int"
  assert type_of("fn(value) { match value { Ok(x) -> x\nError(_) -> 0 } }")
    == "fn(Result(Int, a)) -> Int"
  assert type_of("fn(xs) { match xs { [x, ..] -> x\n[] -> 0 } }")
    == "fn(List(Int)) -> Int"
}

pub fn match_branch_bindings_remain_monomorphic_test() {
  let report =
    expression("fn(value) { match value { f -> #(f(1), f(\"wrong\")) } }")
  assert list.length(report.diagnostics) == 1
}

pub fn branches_do_not_leak_bindings_test() {
  let report = expression("match Some(1) { Some(x) -> x\nNone -> x }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
  let report = expression("{ match Some(1) { Some(x) -> x\nNone -> 0 }\nx }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
}

pub fn branch_results_and_guards_are_checked_test() {
  assert list.length(
      expression("match True { True -> 1\nFalse -> \"wrong\" }").diagnostics,
    )
    == 1
  assert list.length(
      expression("match Some(1) { Some(x) if x -> x\n_ -> 0 }").diagnostics,
    )
    == 1
  assert type_of("match Some(1) { Some(x) if x > 0 -> x\n_ -> 0 }") == "Int"
}

pub fn core_constructor_pattern_arity_is_checked_test() {
  assert list.length(
      expression("match Some(1) { Some -> 1\nNone -> 0 }").diagnostics,
    )
    == 1
  assert list.length(expression("match None { None(x) -> x }").diagnostics) == 1
}

pub fn nested_constructor_patterns_infer_types_test() {
  assert type_of("fn(value) { match value { Some(Ok(#(x, _))) -> x\n_ -> 0 } }")
    == "fn(Option(Result(#(Int, a), b))) -> Int"
}

pub fn pattern_inference_snapshot_test() {
  expression(
    "fn(value) { match value { Some(Ok(#(x, _))) if x > 0 -> x\n_ -> 0 } }",
  )
  |> fn(report) { #(types.to_string(report.type_), report.diagnostics) }
  |> support.pretty
  |> birdie.snap(title: "types: nested pattern inference")
}

pub fn result_propagation_constrains_the_enclosing_callable_test() {
  assert type_of("fn(value) { let x = value?\nOk(x) }")
    == "fn(Result(a, b)) -> Result(a, b)"
  assert type_of("fn(value) { let x = value?\nOk(#(x, True)) }")
    == "fn(Result(a, b)) -> Result(#(a, Bool), b)"
  assert list.length(
      expression("fn(value: Result(Int, String)) { let x = value?\nx }").diagnostics,
    )
    == 1
  assert list.length(expression("fn() { Some(1)? }").diagnostics) == 1
}

// The Result error type belongs to the callable containing ?. A nested
// closure and its creator must not accidentally share that exit constraint.
pub fn propagation_boundaries_do_not_leak_between_closures_test() {
  assert type_of("fn(value) { let f = fn() { let x = Ok(value)?\nOk(x) }\n1 }")
    == "fn(a) -> Int"
  assert type_of(
      "fn() { let f = fn(value) { let x = value?\nOk(x) }\n#(f(Ok(1)), f(Ok(\"s\"))) }",
    )
    == "fn() -> #(Result(Int, a), Result(String, b))"
}

pub fn propagation_cannot_exit_a_guard_test() {
  let report =
    expression(
      "fn(value) { match value { x if Ok(True)? -> Ok(x)\n_ -> Ok(value) } }",
    )
  assert list.any(report.diagnostics, fn(value) {
    value.id == "type.invalid_context"
  })
  assert type_of(
      "fn(value) { match value { x if (fn(f) { True })(fn() { let y = Ok(True)?\nOk(y) }) -> x\n_ -> value } }",
    )
    != ""
}

pub fn panic_and_todo_are_polymorphic_nonreturning_expressions_test() {
  assert type_of("fn() { panic }") == "fn() -> a"
  assert type_of("fn() { todo as \"pending\" }") == "fn() -> a"
  assert type_of("match True { True -> 1\nFalse -> panic }") == "Int"
  assert list.length(expression("panic as 1").diagnostics) == 1
}

pub fn assertion_types_and_failure_scope_are_checked_test() {
  assert type_of("assert True as \"message\"") == "Nil"
  assert list.length(expression("assert 1").diagnostics) == 1
  assert list.length(expression("assert True as 1").diagnostics) == 1
  assert type_of("{ let assert Some(value) = Some(1)\nvalue }") == "Int"
  let report =
    expression("{ let assert Some(value) = Some(1) as value\nvalue }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
}

pub fn loop_break_values_are_unified_test() {
  assert type_of("loop { break 1 }") == "Int"
  assert type_of("loop { break }") == "Nil"
  assert type_of("loop {}") == "a"
  assert type_of(
      "fn(flag) { loop { match flag { True -> break 1\nFalse -> continue } } }",
    )
    == "fn(Bool) -> Int"
  assert list.length(
      expression(
        "fn(flag) { loop { match flag { True -> break 1\nFalse -> break \"wrong\" } } }",
      ).diagnostics,
    )
    == 1
}

pub fn loop_boundaries_do_not_cross_closures_test() {
  assert type_of("loop { let inner = loop { break \"s\" }\nbreak 1 }") == "Int"
  let report = expression("loop { let f = fn() { break 1 }\nbreak 2 }")
  assert list.any(report.diagnostics, fn(value) {
    value.id == "type.invalid_context"
  })
  assert list.length(expression("break").diagnostics) == 1
  assert list.length(expression("continue").diagnostics) == 1
}

pub fn propagation_inference_snapshot_test() {
  expression("fn(value) { let x = value?\nOk(#(x, True)) }")
  |> fn(report) { #(types.to_string(report.type_), report.diagnostics) }
  |> support.pretty
  |> birdie.snap(title: "types: result propagation boundary")
}

pub fn explicit_generic_parameters_remain_universal_test() {
  assert type_of("fn(value: a) { value }") == "fn(a) -> a"
  assert type_of(
      "fn(values: List(a)) { match values { [first, ..] -> first\n[] -> panic } }",
    )
    == "fn(List(a)) -> a"
  assert list.length(expression("fn(value: a) { value + 1 }").diagnostics) == 1
  assert list.length(
      expression("fn(left: a, right: b) { left == right }").diagnostics,
    )
    == 1
}

pub fn outer_generic_names_are_visible_to_nested_annotations_test() {
  assert type_of(
      "fn(value: a) { let checked: a = value\nfn(other: a) { checked } }",
    )
    == "fn(a) -> fn(a) -> a"
  assert type_of("fn(value: a) { fn(other: b) { value } }")
    == "fn(a) -> fn(b) -> a"
}

pub fn new_universal_variables_cannot_escape_to_captured_bindings_test() {
  let report = expression("fn(consume) { fn(value: a) { consume(value) } }")
  assert list.any(report.diagnostics, fn(value) {
    value.id == "type.generic_escape"
  })
}

pub fn explicit_generics_are_opened_for_polymorphic_uses_test() {
  assert type_of(
      "{ let identity = fn(value: a) { value }\n#(identity(1), identity(\"s\")) }",
    )
    == "#(Int, String)"
}

pub fn module_interfaces_are_distinct_from_local_values_test() {
  let #(generic, state) = unify.fresh(unify.new())
  let identity =
    scheme.generalize(types.FunctionType([generic], generic), [], state)
  let environment =
    dict.from_list([
      #(
        "helpers",
        infer.ModuleBinding(
          "helpers",
          dict.from_list([#("identity", identity)]),
          dict.new(),
        ),
      ),
    ])
  let assert Ok(report) =
    infer.infer(
      support.expression("#(helpers.identity(1), helpers.identity(\"s\"))"),
      environment,
      state,
      support.path,
    )
  assert report.diagnostics == []
  assert types.to_string(report.type_) == "#(Int, String)"
  let assert Ok(report) =
    infer.infer(support.expression("helpers"), environment, state, support.path)
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.module_as_value"]
  let assert Ok(shadowed) =
    infer.infer(
      support.expression("fn(helpers) { helpers.identity(1) }"),
      environment,
      state,
      support.path,
    )
  assert list.map(shadowed.diagnostics, fn(value) { value.id })
    == ["type.invalid_member_subject"]
}

pub fn unknown_module_members_propagate_poison_test() {
  let environment =
    dict.from_list([
      #("helpers", infer.ModuleBinding("helpers", dict.new(), dict.new())),
    ])
  let assert Ok(report) =
    infer.infer(
      support.expression("helpers.missing()"),
      environment,
      unify.new(),
      support.path,
    )
  assert report.type_ == types.ErrorType
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_module_member"]
}

pub fn imported_monomorphic_values_are_not_accidentally_generalized_test() {
  let #(value, state) = unify.fresh(unify.new())
  let environment =
    dict.from_list([
      #(
        "data",
        infer.ModuleBinding(
          "data",
          dict.from_list([#("value", scheme.monomorphic(value))]),
          dict.new(),
        ),
      ),
    ])
  let assert Ok(report) =
    infer.infer(
      support.expression(
        "{ let fetch = fn() { data.value }\nlet x: Int = fetch()\nlet y: String = fetch()\nNil }",
      ),
      environment,
      state,
      support.path,
    )
  assert list.length(report.diagnostics) == 1
}

pub fn bit_array_segment_types_are_inferred_test() {
  assert type_of("<<>>") == "BitArray"
  assert type_of("<<1, 2, 3>>") == "BitArray"
  assert type_of("<<1.5:float, 1:int-size(16)>>") == "BitArray"
  assert type_of("fn(size, payload) { <<size:16, payload:bits>> }")
    == "fn(Int, BitArray) -> BitArray"
  assert type_of("fn(payload) { <<payload:bytes>> }")
    == "fn(BitArray) -> BitArray"
}

pub fn utf_text_construction_requires_string_values_test() {
  assert type_of("<<\"Pooka\":utf8>>") == "BitArray"
  assert type_of("fn(value) { <<value:utf16>> }") == "fn(String) -> BitArray"
  assert type_of("<<\"Pooka\":utf32>>") == "BitArray"
  assert list.length(expression("<<1:utf8>>").diagnostics) == 1
}

pub fn bit_array_size_and_unit_values_must_be_int_test() {
  assert type_of("fn(size, payload) { <<payload:bits-size(size)-unit(8)>> }")
    == "fn(Int, BitArray) -> BitArray"
  assert list.length(expression("<<1:size(\"wrong\")>>").diagnostics) == 1
  assert list.length(expression("<<1:unit(1.5)>>").diagnostics) == 1
}

pub fn bit_array_patterns_bind_typed_segments_test() {
  assert type_of(
      "fn(bytes) { let <<header:8, rest:bits>> = bytes\n#(header, rest) }",
    )
    == "fn(BitArray) -> #(Int, BitArray)"
  assert type_of(
      "fn(bytes) { let <<value:float, rest:bits>> = bytes\n#(value, rest) }",
    )
    == "fn(BitArray) -> #(Float, BitArray)"
  assert type_of(
      "fn(bytes) { match bytes { <<length:8, value:size(length)>> -> value\n_ -> 0 } }",
    )
    == "fn(BitArray) -> Int"
}

pub fn bit_array_pattern_sizes_observe_source_binding_order_test() {
  let report =
    expression(
      "fn(bytes) { let <<value:size(length), length:8>> = bytes\nvalue }",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
  assert list.length(expression("{ let <<value:8>> = 1\nvalue }").diagnostics)
    == 1
}

pub fn conflicting_and_unknown_segment_options_are_errors_test() {
  let report = expression("<<1:int-float>>")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.conflicting_bit_array_options"]
  let report = expression("<<1:unknown_option>>")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_bit_array_option"]
}

pub fn numeric_segment_modifiers_preserve_the_value_type_test() {
  assert type_of("fn(value) { <<value:int-signed-little-size(16)>> }")
    == "fn(Int) -> BitArray"
  assert type_of("fn(value) { <<value:float-big-size(64)>> }")
    == "fn(Float) -> BitArray"
}

pub fn unicode_codepoints_are_distinct_from_integers_test() {
  assert list.length(expression("<<1:utf8_codepoint>>").diagnostics) == 1
  assert type_of(
      "fn(bytes) { let assert <<point:utf8_codepoint>> = bytes\npoint }",
    )
    == "fn(BitArray) -> UtfCodepoint"
  let assert Error(_) =
    infer.infer(
      support.expression("fn(bytes) { let <<value:utf8>> = bytes\nvalue }"),
      dict.new(),
      unify.new(),
      support.path,
    )
}

pub fn bit_array_inference_snapshot_test() {
  expression(
    "fn(bytes) { let <<length:8, payload:size(length)-bits>> = bytes\n#(length, payload) }",
  )
  |> fn(report) { #(types.to_string(report.type_), report.diagnostics) }
  |> support.pretty
  |> birdie.snap(title: "types: bit array construction and pattern inference")
}

// Do not settle an overloaded primitive operator at its first appearance. A
// later annotation can supply the concrete domain needed to choose its
// result.
pub fn operator_domains_can_be_resolved_by_later_annotations_test() {
  assert type_of(
      "{ let add: fn(Int, Int) -> Int = fn(a, b) { a + b }\nadd(1, 2) }",
    )
    == "Int"
  assert type_of("fn(a, b) { <<1:size(a + b)>> }") == "fn(Int, Int) -> BitArray"
  assert type_of("(fn(a, b) { a + b })(1, 2)") == "Int"
}

pub fn captured_operator_types_wait_for_the_enclosing_scope_test() {
  assert type_of(
      "fn(outer) { let plus = fn(value) { outer + value }\nlet checked: Int = outer\nplus(checked) }",
    )
    == "fn(Int) -> Int"
}

pub fn ambiguous_operator_types_are_diagnostics_not_unsupported_syntax_test() {
  let report = expression("fn(a, b) { a + b }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.ambiguous_operator"]
  assert report.type_ == types.ErrorType
  let report = expression("fn(a, b) { #(a + b, a - b) }")
  assert list.length(report.diagnostics) == 1
  let assert [value] = report.diagnostics
  assert value.suggestions == ["Supported operand types: Int or Float."]
}

// An unresolved primitive constraint is not unrestricted polymorphism.
// Generalizing it too early would admit types the operator can never handle.
pub fn ambiguous_let_bound_operators_are_not_generalized_as_unrestricted_functions_test() {
  let report = expression("{ let add = fn(a, b) { a + b }\nadd(1, 2) }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.ambiguous_operator"]
}
