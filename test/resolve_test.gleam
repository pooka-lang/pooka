//// A name should know which desk it belongs to.
////
//// Check lexical binding, imports, member visibility and assignment rules
//// before inference. Shadowing changes value lookup without erasing type
//// qualifiers. Suggestions must preserve surrounding syntax, and unknown
//// receivers must not breed misleading follow-up diagnostics.

import birdie
import compiler/analysis/resolve
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/set
import support
import utilities/colour

fn ids(source: String) -> List(String) {
  resolve.check(support.parse("module main\n" <> source), support.path)
  |> list.map(fn(value) { value.id })
}

pub fn declarations_are_visible_before_their_definitions_test() {
  assert ids("main() { helper() }\nhelper() { Nil }") == []
  assert ids("main() { User() }\nclass User {}") == []
  assert ids("a() { b() }\nb() { a() }") == []
}

pub fn unknown_value_and_type_names_are_distinct_test() {
  assert ids("f() { missing }") == ["analysis.unknown_name"]
  assert ids("f(value: Missing) -> Int { 1 }") == ["analysis.unknown_type"]
  assert ids("f() -> Missing { Nil }") == ["analysis.unknown_type"]
}

pub fn parameters_and_core_constructors_are_in_scope_test() {
  assert ids(
      "f(value, _ignored, _) { #(value, _ignored, Some(1), None, Ok(1), Error(\"s\")) }",
    )
    == []
}

// Resolve the initializer in the outer scope before introducing its new
// binding. Seeing the unfinished name would accidentally create a recursive
// local definition.
pub fn initializer_does_not_see_its_own_binding_test() {
  assert ids("f() { let value = value }") == ["analysis.unknown_name"]
  assert ids("f(value) { let value = value }") == []
}

pub fn nested_blocks_do_not_leak_bindings_test() {
  assert ids("f() { { let value = 1 }\nvalue }") == ["analysis.unknown_name"]
  assert ids("f(value) { { let value = \"s\"\nvalue }\nvalue }") == []
}

pub fn anonymous_functions_capture_outer_scope_without_leaking_parameters_test() {
  assert ids("f(value) { fn(other) { #(value, other) } }") == []
  assert ids("f() { let g = fn(value) { value }\nvalue }")
    == ["analysis.unknown_name"]
}

pub fn match_bindings_are_available_in_their_own_guard_and_body_test() {
  assert ids("f(value) { match value { Some(x) if x > 0 -> x\nNone -> 0 } }")
    == []
  assert ids("f(value) { match value { Some(x) -> x\nNone -> x } }")
    == ["analysis.unknown_name"]
  assert ids("f(value) { match value { x -> x }\nx }")
    == ["analysis.unknown_name"]
}

pub fn tuple_list_and_nested_patterns_bind_all_names_test() {
  assert ids("f(value) { let #(x, Some([y, ..ys])) = value\n#(x, y, ys) }")
    == []
  assert ids("f(xs) { loop #(x, y) in xs { #(x, y) } }") == []
  assert ids("f(xs) { loop x in xs { x }\nx }") == ["analysis.unknown_name"]
}

// Bindings from a successful pattern do not exist when that pattern fails.
// Resolve the lazy failure message in the scope available on the failure
// path.
pub fn assertion_failure_messages_use_the_outer_scope_test() {
  assert ids("f(value) { let assert Some(x) = value as x\nx }")
    == ["analysis.unknown_name"]
  assert ids("f(value, x) { let assert Some(x) = value as x\nx }") == []
}

pub fn bit_array_sizes_see_earlier_segment_bindings_test() {
  assert ids("f(bytes) { let <<size:8, value:size(size)>> = bytes\nvalue }")
    == []
  assert ids("f(bytes) { let <<value:size(size), size:8>> = bytes\nvalue }")
    == ["analysis.unknown_name"]
  assert ids("f(bytes) { let <<size:size(size)>> = bytes }")
    == ["analysis.unknown_name"]
}

pub fn module_aliases_and_selective_imports_bind_names_test() {
  assert ids(
      "import users.{User, load as fetch}\nf() { #(users.load(), User(), fetch()) }",
    )
    == []
  assert ids("import http/client as web\nf(value: web.Response) { web.get() }")
    == []
  assert ids("import http/client\nf(value: client.Response) { client.get() }")
    == []
}

pub fn qualified_types_and_patterns_require_imports_test() {
  assert ids("f(value: users.User) { value }")
    == ["analysis.unknown_module_qualifier"]
  assert ids("f(value) { match value { users.User(x) -> x } }")
    == ["analysis.unknown_module_qualifier"]
  assert ids("f(value) { match value { Unknown(x) -> x } }")
    == ["analysis.unknown_name"]
}

pub fn type_annotations_are_walked_recursively_test() {
  assert ids(
      "f(value: List(Missing)) -> #(Int, fn(Missing) -> Other) { value }",
    )
    == [
      "analysis.unknown_type",
      "analysis.unknown_type",
      "analysis.unknown_type",
    ]
  assert ids("class Box(a) { let value: a\nnew(value) { self.value = value } }")
    == []
}

pub fn member_scope_includes_fields_methods_and_private_members_test() {
  assert ids(
      "class User { let _name: String\nnew(name) { self._name = name }\ngreet() { _greet(_name) }\n_greet(name) { name } }",
    )
    == []
  assert ids(
      "actor Counter { var count = 0\nbe increment() { count += 1 }\nvalue() { count } }",
    )
    == []
}

pub fn inherited_public_members_are_in_scope_test() {
  assert ids(
      "class Parent { let name: String\ngreet() { name } }\nclass Child is Parent { describe() { greet() } }",
    )
    == []
  assert ids(
      "class Parent { let _name: String }\nclass Child is Parent { get() { _name } }",
    )
    == ["analysis.unknown_name"]
}

pub fn cyclic_parent_trees_do_not_hang_resolution_test() {
  assert ids("class A is B { a() { b() } }\nclass B is A { b() { a() } }") == []
}

pub fn independent_fields_and_methods_do_not_share_parameters_test() {
  assert ids("class User { set(value) { value }\nget() { value } }")
    == ["analysis.unknown_name"]
}

pub fn externals_interfaces_and_tests_resolve_annotations_and_bodies_test() {
  assert ids("external Io from erlang \"io\" { read(value: Missing) -> Int }")
    == ["analysis.unknown_type"]
  assert ids("external Io from erlang \"io\" { read() -> Missing }")
    == ["analysis.unknown_type"]
  assert ids("interface Readable { read() -> Missing }")
    == ["analysis.unknown_type"]
  assert ids("test \"works\" { missing() }") == ["analysis.unknown_name"]
  assert ids("test \"first\" { let value = 1 }\ntest \"second\" { value }")
    == ["analysis.unknown_name"]
}

pub fn unknown_names_have_suggested_fixes_test() {
  let assert [value] =
    resolve.check(
      support.parse("module main\ngreet(name) { nmae }"),
      support.path,
    )
  let assert [fix] = value.fixes
  assert fix.replacement == "name"
  assert fix.applicability == diagnostic.Suggested
}

pub fn resolution_diagnostic_snapshot_test() {
  let source = "module main\ngreet(name: String) {\n  nmae\n}\n"
  resolve.check(support.parse(source), support.path)
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "analysis: unknown local name with a suggestion")
}

pub fn parameters_and_local_bindings_cannot_be_reassigned_test() {
  assert ids("f(value) { value = 1 }") == ["analysis.immutable_local"]
  assert ids("f() { let value = 1\nvalue += 2 }")
    == ["analysis.immutable_local"]
  assert ids("f(pair) { let #(x, y) = pair\nx = y }")
    == ["analysis.immutable_local"]
}

pub fn class_fields_are_immutable_outside_construction_test() {
  assert ids("class User { let age = 1\nchange() { age = 2 } }")
    == ["analysis.immutable_field"]
  assert ids(
      "class Parent { let age = 1 }\nclass Child is Parent { change() { age += 1 } }",
    )
    == ["analysis.immutable_field"]
}

pub fn actor_mutable_state_is_assignable_by_the_owning_implementation_test() {
  assert ids(
      "actor Counter { var count = 0\nbe increment() { count += 1 }\nreset() { count = 0 } }",
    )
    == []
  assert ids(
      "actor Counter { let label = \"counter\"\nrename() { label = \"other\" } }",
    )
    == ["analysis.immutable_field"]
}

// A local name that resembles mutable actor state is still a local immutable
// binding. Permission to mutate follows the resolved owner, not the spelling.
pub fn local_shadowing_does_not_make_actor_state_assignable_test() {
  assert ids("actor Counter { var count = 0\nset(count) { count = 1 } }")
    == ["analysis.immutable_local"]
  assert ids(
      "actor Counter { var count = 0\nset() { let count = 1\ncount += 1 } }",
    )
    == ["analysis.immutable_local"]
}

pub fn constructor_field_assignment_requires_self_test() {
  assert ids("actor Counter { var count: Int\nnew() { count = 0 } }")
    == ["analysis.constructor_assignment_requires_self"]
  assert ids("class User { let age: Int\nnew() { age = 0 } }")
    == ["analysis.constructor_assignment_requires_self"]
  assert ids("class User { let age: Int\nnew() { self.age = 0 } }") == []
}

pub fn self_assignment_must_target_a_directly_declared_field_test() {
  assert ids("class User { new() { self.unknown = 1 } }")
    == ["analysis.unknown_field"]
  assert ids(
      "class Parent { let age = 1 }\nclass Child is Parent { new() { self.age = 2 } }",
    )
    == ["analysis.inherited_field_initialization"]
  assert ids("actor Counter { new() { self.unknown = 1 } }")
    == ["analysis.unknown_field"]
}

pub fn field_mutation_through_other_values_is_not_available_test() {
  assert ids("f(user) { user.name = \"other\" }")
    == ["analysis.invalid_field_assignment"]
  assert ids("actor Counter { var count = 0\ncopy(other) { other.count = 1 } }")
    == ["analysis.invalid_field_assignment"]
}

pub fn unknown_assignment_subjects_do_not_produce_cascades_test() {
  assert ids("f() { missing.name = 1 }") == ["analysis.unknown_name"]
  assert ids("f() { missing = 1 }") == ["analysis.unknown_name"]
}

pub fn declarations_cannot_be_reassigned_test() {
  assert ids("helper() {}\nf() { helper = 1 }")
    == ["analysis.invalid_assignment_target"]
  assert ids("import io\nf() { io = 1 }")
    == ["analysis.invalid_assignment_target"]
}

pub fn field_initializers_cannot_mutate_actor_state_test() {
  assert ids("actor Counter { var count = 0\nlet other = { count = 1\n0 } }")
    == ["analysis.state_assignment_in_initializer"]
}

pub fn closures_keep_captured_bindings_immutable_test() {
  assert ids("f(value) { fn() { value = 1 } }") == ["analysis.immutable_local"]
}

pub fn assignment_diagnostic_snapshot_test() {
  let source =
    "module main\nactor Counter {\n  var count = 0\n  set(count) { count = 1 }\n}\n"
  resolve.check(support.parse(source), support.path)
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "analysis: local binding shadows mutable actor state")
}

pub fn qualified_private_module_declarations_are_inaccessible_test() {
  assert ids("import account\nf() { account._helper() }")
    == ["analysis.private_declaration"]
  assert ids("import account as users\nf() { users._helper() }")
    == ["analysis.private_declaration"]
  assert ids("import account.{User}\nf() { account._helper() }")
    == ["analysis.private_declaration"]
}

pub fn qualified_private_types_and_patterns_are_inaccessible_test() {
  assert ids("import account\nf(value: account._Internal) { value }")
    == ["analysis.private_declaration"]
  assert ids(
      "import account\nf(value) { match value { account._Internal -> Nil } }",
    )
    == ["analysis.private_declaration"]
}

pub fn module_alias_shadowing_uses_value_member_lookup_test() {
  assert ids("import account\nf(account) { account._field }") == []
  assert ids("import account\nf(value) { let account = value\naccount._field }")
    == []
  assert ids(
      "import account\nf(value) { match value { account -> account._field } }",
    )
    == []
}

pub fn member_names_shadow_module_aliases_test() {
  assert ids(
      "import account\nclass User { let account = Nil\nf() { account._field } }",
    )
    == []
  assert ids(
      "import account\nactor User { var account = Nil\nf() { account._field } }",
    )
    == []
}

pub fn shadowed_qualifiers_are_restored_after_nested_blocks_test() {
  assert ids(
      "import account\nf(value) { { let account = value\naccount._field }\naccount._helper() }",
    )
    == ["analysis.private_declaration"]
}

pub fn type_qualifiers_are_independent_of_value_shadowing_test() {
  assert ids("import account\nf(account, value: account._Internal) { account }")
    == ["analysis.private_declaration"]
}

pub fn same_module_private_declarations_remain_accessible_test() {
  assert ids("_helper() { Nil }\nf() { _helper() }") == []
  assert ids("class _Internal {}\nf(value: _Internal) { value }") == []
}

pub fn unknown_qualifiers_do_not_also_report_private_access_test() {
  assert ids("f(value: account._Internal) { value }")
    == ["analysis.unknown_module_qualifier"]
}

pub fn qualified_private_diagnostic_snapshot_test() {
  let source = "module main\nimport account as users\nf() { users._helper() }\n"
  resolve.check(support.parse(source), support.path)
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "analysis: private qualified module declaration")
}

fn local_exports(source: String) -> List(diagnostic.Diagnostic) {
  resolve.check_with_exports(
    support.parse("module main\nimport account as users\n" <> source),
    support.path,
    dict.from_list([#("account", set.from_list(["User", "load"]))]),
  )
}

pub fn qualified_names_are_checked_against_known_local_exports_test() {
  assert local_exports("f() { users.load() }") == []
  let assert [value] = local_exports("f() { users.missing() }")
  assert value.id == "analysis.unknown_module_member"
  assert local_exports("f(value: users.User) { value }") == []
  let assert [value] = local_exports("f(value: users.Missing) { value }")
  assert value.id == "analysis.unknown_module_member"
}

pub fn qualified_patterns_use_local_export_names_test() {
  assert local_exports("f(value) { match value { users.User(x) -> x } }") == []
  let assert [value] =
    local_exports("f(value) { match value { users.Missing(x) -> x } }")
  assert value.id == "analysis.unknown_module_member"
}

pub fn shadowed_module_values_do_not_use_the_export_index_test() {
  assert local_exports("f(users) { users.missing }") == []
  assert local_exports("class C { let users = Nil\nf() { users.missing } }")
    == []
}

// A spelling correction should replace only the mistaken name. Preserve its
// type arguments and nested pattern payload rather than erasing useful source
// around it.
pub fn name_suggestions_never_delete_type_arguments_or_nested_patterns_test() {
  let assert [value] = local_exports("f(value: users.Usre(Int)) { value }")
  assert value.fixes == []
  let assert [value] =
    local_exports("f(value) { match value { users.Usre(x) -> x } }")
  assert value.fixes == []
  let assert [value] = local_exports("f() { users.loda() }")
  let assert [fix] = value.fixes
  assert fix.replacement == "load"
}

pub fn unqualified_pattern_suggestions_preserve_pattern_arguments_test() {
  let diagnostics =
    resolve.check(
      support.parse(
        "module main\nclass User {}\nf(value) { match value { Usre(x) -> x } }",
      ),
      support.path,
    )
  let assert [value] = diagnostics
  assert value.fixes == []
}

pub fn qualified_name_diagnostic_snapshot_test() {
  let source = "module main\nimport account as users\nf() { users.loda() }\n"
  local_exports("f() { users.loda() }")
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(
    title: "analysis: unknown qualified declaration with a suggestion",
  )
}

pub fn raw_pid_is_a_core_type_without_type_arguments_test() {
  assert ids(
      "external Process from erlang \"pooka_process\" { current() -> Pid }\nf(value: Pid) { value }",
    )
    == []
  assert ids("f(value: Pid(Int)) { value }") == ["analysis.type_arity"]
}

pub fn core_type_constructor_arities_are_checked_test() {
  assert ids("f(value: Int(String)) { value }") == ["analysis.type_arity"]
  assert ids("f(value: List) { value }") == ["analysis.type_arity"]
  assert ids("f(value: Result(Int)) { value }") == ["analysis.type_arity"]
  assert ids("f(value: Option(Int, String)) { value }")
    == ["analysis.type_arity"]
}

pub fn local_class_interface_and_actor_arities_are_checked_test() {
  assert ids("class Box(a) {}\nf(value: Box(Int)) { value }") == []
  assert ids("class Box(a) {}\nf(value: Box) { value }")
    == ["analysis.type_arity"]
  assert ids("interface Mapper(a) {}\nf(value: Mapper) { value }")
    == ["analysis.type_arity"]
  assert ids("actor Worker(a) {}\nf(value: Worker(Int, String)) { value }")
    == ["analysis.type_arity"]
}

pub fn imported_type_arities_are_deferred_to_their_resolved_interfaces_test() {
  assert ids("import data.{Value as List}\nf(value: List) { value }") == []
  assert ids("import data\nf(value: data.Value(Int)) { value }") == []
}

pub fn type_arity_diagnostic_snapshot_test() {
  let source = "module main\nf(value: Result(Int)) { value }\n"
  resolve.check(support.parse(source), support.path)
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "analysis: core type constructor arity")
}
