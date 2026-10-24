//// A recursive group has to make its promises together.
////
//// Order declaration dependencies, infer recursive components monomorphically,
//// then publish generalized signatures. Explicit generic annotations remain
//// universal inside their bodies. Independent errors, test scopes and deferred
//// primitive constraints must settle without leaking variables into later
//// groups.
////
//// ```text
//// prepare signatures -> check one recursive group -> generalize -> check callers
//// ```

import birdie
import compiler/analysis/function_group
import compiler/parser/ast
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import support
import utilities/colour

fn module(body: String) -> module_infer.Module {
  let syntax = support.parse("module main\n" <> body)
  let assert Ok(report) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  report
}

/// Publish readable signatures only after asserting that module inference
/// produced no diagnostics. A recovered error type must not masquerade as a
/// successful inferred interface.
fn signatures(body: String) -> List(#(String, String)) {
  let report = module(body)
  assert report.diagnostics == []
  list.map(report.functions, fn(value) {
    #(value.name.name, monotype.to_string(value.type_))
  })
}

/// Inspect function dependency groups separately from type inference. This
/// keeps ordering assertions sensitive to graph construction rather than its
/// later type results.
fn groups(body: String) -> List(List(String)) {
  let syntax = support.parse("module main\n" <> body)
  let functions =
    list.filter_map(syntax.declarations, fn(value) {
      case value {
        ast.FunctionDeclaration(value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  function_group.groups(functions)
  |> list.map(fn(group) { list.map(group, fn(value) { value.name.name }) })
}

pub fn dependencies_are_inferred_before_callers_test() {
  assert signatures(
      "main() { #(identity(1), identity(\"s\")) }\nidentity(x) { x }",
    )
    == [#("main", "fn() -> #(Int, String)"), #("identity", "fn(a) -> a")]
  assert groups("main() { identity(1) }\nidentity(x) { x }")
    == [["identity"], ["main"]]
}

pub fn top_level_identity_is_polymorphic_test() {
  assert signatures(
      "identity(x) { x }\nmain() { #(identity(1), identity(True), identity(\"s\")) }",
    )
    == [#("identity", "fn(a) -> a"), #("main", "fn() -> #(Int, Bool, String)")]
}

pub fn direct_recursion_uses_a_shared_signature_test() {
  assert signatures("forever(x) { forever(x) }") == [#("forever", "fn(a) -> b")]
  assert signatures(
      "factorial(n) { match n { 0 -> 1\n_ -> n * factorial(n - 1) } }",
    )
    == [#("factorial", "fn(Int) -> Int")]
}

// Prepare the whole recursive group before checking any body. Freshly
// instantiating recursive uses would invent polymorphic recursion inside an
// unfinished definition.
pub fn mutual_recursion_forms_one_monomorphic_group_test() {
  let body =
    "even(n) { match n { 0 -> True\n_ -> odd(n - 1) } }\nodd(n) { match n { 0 -> False\n_ -> even(n - 1) } }"
  assert groups(body) == [["even", "odd"]]
  assert signatures(body)
    == [#("even", "fn(Int) -> Bool"), #("odd", "fn(Int) -> Bool")]
}

// The group cannot call itself at unrelated argument types before its body
// is checked. Generalization happens outside this unfinished circle.
//
// ```text
// prepare one signature -> check recursive uses -> generalize for callers
// ```
pub fn polymorphic_recursion_is_not_invented_test() {
  let report = module("recur(x) { #(recur(1), recur(\"s\")) }")
  assert report.diagnostics != []
}

pub fn local_shadowing_does_not_create_false_dependencies_test() {
  assert groups("helper(x) { x }\nmain(helper) { helper(1) }")
    == [["helper"], ["main"]]
  assert groups(
      "helper(x) { x }\nmain() { let helper = fn(x) { x }\nhelper(1) }",
    )
    == [["helper"], ["main"]]
  assert groups(
      "helper(x) { x }\nmain(value) { match value { helper -> helper } }",
    )
    == [["helper"], ["main"]]
}

pub fn nested_closure_references_create_dependencies_test() {
  assert groups("main() { fn(x) { helper(x) } }\nhelper(x) { x }")
    == [["helper"], ["main"]]
  assert signatures("main() { fn(x) { helper(x) } }\nhelper(x) { x }")
    == [#("main", "fn() -> fn(a) -> a"), #("helper", "fn(a) -> a")]
}

pub fn independent_function_errors_are_all_reported_test() {
  let report = module("first() -> Int { \"s\" }\nsecond() -> Bool { 1 }")
  assert list.length(report.diagnostics) == 2
}

// After reporting the helper's own error, publish a poisoned result for
// recovery. Its callers should not repeat an unrelated cascade of type
// complaints.
pub fn erroneous_helpers_are_poisoned_for_callers_test() {
  let report = module("bad() -> Int { \"s\" }\nmain() { bad() }")
  assert list.length(report.diagnostics) == 1
  let assert [_, main] = report.functions
  assert main.type_ == monotype.FunctionType([], monotype.ErrorType)
}

pub fn unsupported_requirement_annotations_are_explicit_test() {
  let syntax =
    support.parse_module_with_errors(
      "module main\ninterface Incomplete { read() }\nmain() { Nil }",
    )
  let assert Error(_) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
}

pub fn module_inference_snapshot_test() {
  signatures(
    "identity(x) { x }\nwrap(value) { Ok(identity(value)) }\nmain() { #(wrap(1), identity(\"hello\")) }",
  )
  |> support.pretty
  |> birdie.snap(title: "types: dependency ordered function inference")
}

pub fn explicit_generic_function_signatures_are_preserved_test() {
  assert signatures(
      "identity(value: a) -> a { value }\nmain() { #(identity(1), identity(\"s\")) }",
    )
    == [#("identity", "fn(a) -> a"), #("main", "fn() -> #(Int, String)")]
  assert signatures(
      "first(values: List(a)) -> a { match values { [x, ..] -> x\n[] -> panic } }",
    )
    == [#("first", "fn(List(a)) -> a")]
}

pub fn written_generic_return_types_cannot_be_specialized_test() {
  assert module("wrong(value: a) -> a { 1 }").diagnostics != []
  assert module("wrong() -> a { 1 }").diagnostics != []
}

pub fn recursive_uses_cannot_specialize_a_universal_signature_test() {
  assert module("wrong(value: a) -> a { wrong(1) }").diagnostics != []
}

pub fn generic_annotation_diagnostic_snapshot_test() {
  let source = "module main\nwrong(value: a) -> a { 1 }\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  report.diagnostics
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "types: universal annotation cannot specialize")
}

pub fn external_signatures_are_available_before_function_bodies_test() {
  assert signatures(
      "main() { Native.read(1) }\nexternal Native from erlang \"native\" { read(value: Int) -> String }",
    )
    == [#("main", "fn() -> String")]
  assert signatures(
      "external Native from erlang \"native\" { identity(value: a) -> a }\nmain() { #(Native.identity(1), Native.identity(\"s\")) }",
    )
    == [#("main", "fn() -> #(Int, String)")]
}

pub fn external_namespaces_are_typed_test() {
  let report =
    module(
      "external Formatter from elixir \"Formatter\" {\n  double(n: Int) -> Int\n  label(n: Int, unit: String) -> String\n}",
    )
  let assert [namespace] = report.externals
  assert namespace.name.name == "Formatter"
  assert namespace.language == ast.Elixir
  assert namespace.module == "Formatter"
  assert list.map(namespace.functions, fn(function) {
      #(function.name.name, monotype.to_string(function.type_))
    })
    == [#("double", "fn(Int) -> Int"), #("label", "fn(Int, String) -> String")]

  assert report.functions == []
}

pub fn external_calls_are_type_checked_test() {
  let report =
    module(
      "external Math from erlang \"math_helpers\" { double(value: Int) -> Int }\nmain() { Math.double(\"ten\") }",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    |> list.contains("type.unification")
}

pub fn unknown_external_functions_are_reported_test() {
  let report =
    module(
      "external Math from erlang \"math_helpers\" { double(value: Int) -> Int }\nmain() { Math.triple(1) }",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_external_function"]
}

pub fn externals_cannot_invent_unannotated_boundary_types_test() {
  let syntax =
    support.parse_module_with_errors(
      "module main\nexternal Native from erlang \"native\" { read(value) -> String }",
    )
  let assert Error(_) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
}

pub fn test_blocks_see_generalized_module_functions_test() {
  assert signatures(
      "test \"identity\" { assert identity(1) == 1\nassert identity(\"s\") == \"s\" }\nidentity(value) { value }",
    )
    == [#("identity", "fn(a) -> a")]
}

pub fn independent_test_blocks_do_not_share_locals_test() {
  let report =
    module(
      "test \"first\" { let value = 1 }\ntest \"second\" { assert value == 1 }",
    )
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
  assert report.functions == []
}

pub fn test_blocks_cannot_propagate_results_test() {
  let report = module("test \"result\" { Ok(1)? }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.invalid_context"]
}

pub fn test_blocks_are_not_importable_declarations_test() {
  let report = module("test \"works\" { assert True }\nmain() { works() }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.unknown_name"]
}

pub fn raw_pid_external_signatures_are_supported_test() {
  assert signatures(
      "external Process from erlang \"pooka_process\" { current() -> Pid }\nmain() { Process.current() }",
    )
    == [#("main", "fn() -> Pid")]
}

pub fn return_annotations_can_resolve_operator_overloads_test() {
  assert signatures("add(a, b) -> Int { a + b }")
    == [#("add", "fn(Int, Int) -> Int")]
  assert signatures("concat(a, b) -> String { a + b }")
    == [#("concat", "fn(String, String) -> String")]
  assert signatures("negate(value) -> Float { -value }")
    == [#("negate", "fn(Float) -> Float")]
}

// Division always returns Float, so a return annotation cannot choose the
// operand types. One annotated operand still settles an unannotated partner.
pub fn division_operands_are_settled_by_their_own_annotations_test() {
  assert signatures("divide(a: Int, b) -> Float { a / b }")
    == [#("divide", "fn(Int, Int) -> Float")]
  assert signatures("divide(a: Float, b) { a / b }")
    == [#("divide", "fn(Float, Float) -> Float")]
  assert module("divide(a, b) -> Float { a / b }").diagnostics != []
}

pub fn recursive_group_constraints_can_resolve_earlier_operators_test() {
  assert signatures(
      "first(a, b) { let ignored = second(a, b)\na + b }\nsecond(a, b) -> Int { first(a, b) }",
    )
    == [#("first", "fn(Int, Int) -> Int"), #("second", "fn(Int, Int) -> Int")]
}

pub fn invalid_operator_domains_are_reported_after_constraints_settle_test() {
  let report = module("subtract(a, b) -> String { a - b }")
  assert list.map(report.diagnostics, fn(value) { value.id })
    == ["type.invalid_operator"]
}

pub fn ambiguous_operator_diagnostic_snapshot_test() {
  let source = "module main\nadd(left, right) { left + right }\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  report.diagnostics
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "types: ambiguous primitive operator")
}

pub fn annotated_generic_functions_may_call_themselves_test() {
  assert signatures(
      "len(items: List(a)) -> Int { match items { [] -> 0\n[_, ..rest] -> 1 + len(rest) } }\nmain() { #(len([1]), len([\"a\"])) }",
    )
    == [#("len", "fn(List(a)) -> Int"), #("main", "fn() -> #(Int, Int)")]
}

pub fn annotated_recursion_still_checks_the_body_test() {
  let report =
    module(
      "bad(items: List(a)) -> Int { match items { [] -> 0\n[first, ..rest] -> first + bad(rest) } }",
    )
  assert list.any(report.diagnostics, fn(value) {
    value.id == "type.unification"
  })
}

// Boundary signatures and later inference groups need disjoint variable
// identities. Reusing an ID would bind unrelated types merely because they
// were allocated at different times.
pub fn generic_externals_do_not_alias_later_type_variables_test() {
  assert signatures(
      "external Native from erlang \"native\" {\n  fail(message: String, expected: a, found: a) -> b\n}\nsame(found: a, expected: a) -> Nil { match found == expected { True -> Nil\nFalse -> Native.fail(\"no\", expected, found) } }\nmain() { #(same(1, 1), same(\"a\", \"a\")) }",
    )
    == [#("same", "fn(a, a) -> Nil"), #("main", "fn() -> #(Nil, Nil)")]
}

pub fn many_independent_function_groups_keep_source_order_test() {
  let names =
    list.repeat(Nil, 1000)
    |> list.index_map(fn(_, n) { "f" <> int.to_string(n) })
  let source =
    names |> list.map(fn(name) { name <> "() { Nil }" }) |> string.join("\n")
  assert groups(source) == list.map(names, fn(name) { [name] })
}

pub fn mixed_recursive_groups_keep_member_and_dependency_order_test() {
  assert groups("caller() { a() }\na() { b() }\nleaf() { Nil }\nb() { a() }")
    == [["a", "b"], ["caller"], ["leaf"]]
}
