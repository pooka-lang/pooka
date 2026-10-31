//// A private island does not become reachable by calling itself.
////
//// Track import usage and reachability from public or test roots. Private
//// recursive cycles, lexical shadowing and field initialization must not count
//// as genuine reads. Warning fixes must preserve unrelated source bytes and
//// remaining import bindings.

import birdie
import compiler/analysis/resolve
import compiler/analysis/unused
import compiler/compiler
import compiler/parser/ast
import diagnostics/diagnostic
import diagnostics/fix
import diagnostics/render
import gleam/dict
import gleam/list
import support
import utilities/colour

fn warnings(body: String) -> List(diagnostic.Diagnostic) {
  let syntax = support.parse("module main\n" <> body)
  let resolved = resolve.resolve_with_exports(syntax, support.path, dict.new())
  assert resolved.diagnostics == []
  unused.check(syntax, support.path, resolved.uses)
}

fn ids(body: String) -> List(String) {
  warnings(body) |> list.map(fn(value) { value.id })
}

pub fn whole_unused_imports_produce_one_warning_each_test() {
  assert ids("import database\nf() { Nil }") == ["analysis.unused_import"]
  assert ids("import database.{User, load}\nf() { Nil }")
    == ["analysis.unused_import"]
  let assert [value] = warnings("import database")
  assert value.severity == diagnostic.WarningSeverity
  let assert [edit] = value.fixes
  assert edit.applicability == diagnostic.Automatic
}

pub fn qualified_selective_and_type_only_imports_count_as_used_test() {
  assert ids("import database\nf() { database.load() }") == []
  assert ids("import database.{User}\nf(value: User) { value }") == []
  assert ids("import database as db\nf(value: db.User) { value }") == []
  assert ids("import database.{User as Account}\nf(value: Account) { value }")
    == []
  assert ids(
      "import database.{User}\nf(value) { match value { User(name) -> name } }",
    )
    == []
}

pub fn unused_selected_names_are_reported_when_the_module_is_used_test() {
  assert ids("import database.{load}\nf() { database.other() }")
    == ["analysis.unused_imported_name"]
  assert ids("import database.{User, load}\nf(value: User) { value }")
    == ["analysis.unused_imported_name"]
}

pub fn local_pattern_and_member_shadowing_does_not_keep_imports_alive_test() {
  assert ids("import database\nf(database) { database.value }")
    == ["analysis.unused_import"]
  assert ids(
      "import database\nf(value) { match value { database -> database } }",
    )
    == ["analysis.unused_import"]
  assert ids(
      "import database\nclass C { let database = Nil\nf() { database.value } }",
    )
    == ["analysis.unused_import"]
  assert ids("import database.{load}\nf(load) { database.other()\nload }")
    == ["analysis.unused_imported_name"]
}

pub fn closures_and_type_qualifiers_preserve_real_import_uses_test() {
  assert ids("import database\nf() { fn() { database.load() } }") == []
  assert ids("import database\nf(database, value: database.User) { database }")
    == []
  assert ids(
      "import database.{User}\nexternal Store from erlang \"store\" { create(value: User) -> Nil }",
    )
    == []
}

pub fn public_declarations_are_not_considered_unused_test() {
  assert ids(
      "f() { Nil }\nclass User {}\ninterface Printable {}\nactor Counter {}",
    )
    == []
}

pub fn private_declarations_must_be_reachable_from_a_public_root_test() {
  assert ids("_helper() { Nil }") == ["analysis.unused_private_declaration"]
  assert ids("_helper() { Nil }\nmain() { _helper() }") == []
  assert ids("_first() { _second() }\n_second() { Nil }")
    == [
      "analysis.unused_private_declaration",
      "analysis.unused_private_declaration",
    ]
  assert ids("_first() { _second() }\n_second() { Nil }\nmain() { _first() }")
    == []
}

// A private cycle can be internally busy and still unreachable from every
// public root. Its members do not become used merely by keeping one another
// company.
pub fn private_recursive_cycles_do_not_keep_themselves_alive_test() {
  assert ids("_loop() { _loop() }") == ["analysis.unused_private_declaration"]
  assert ids("_first() { _second() }\n_second() { _first() }")
    == [
      "analysis.unused_private_declaration",
      "analysis.unused_private_declaration",
    ]
}

pub fn same_module_tests_are_usage_roots_test() {
  assert ids("_helper() { Nil }\ntest \"helper\" { _helper() }") == []
}

pub fn private_types_can_be_used_by_signatures_and_inheritance_test() {
  assert ids("class _Hidden {}\nf(value: _Hidden) { value }") == []
  assert ids("class _Parent {}\nclass Child is _Parent {}") == []
  assert ids("interface _Printable {}\nclass User with _Printable {}") == []
  assert ids("class _Hidden {}\n_unused(value: _Hidden) { value }")
    == [
      "analysis.unused_private_declaration",
      "analysis.unused_private_declaration",
    ]
}

pub fn underscore_visibility_does_not_suppress_declaration_or_import_warnings_test() {
  assert ids("class _Hidden {}\ninterface _Printable {}\nactor _Counter {}")
    == [
      "analysis.unused_private_declaration",
      "analysis.unused_private_declaration",
      "analysis.unused_private_declaration",
    ]
  assert ids("import database as _database") == ["analysis.unused_import"]
}

fn apply_selected_edit(body: String) -> ast.Module {
  let source = "module main\n" <> body
  let syntax = support.parse(source)
  let resolved = resolve.resolve_with_exports(syntax, support.path, dict.new())
  let assert [warning] = unused.check(syntax, support.path, resolved.uses)
  let assert [edit] = warning.fixes
  let assert Ok(updated) = fix.apply(source, [edit])
  let checked = compiler.check_source(support.path, updated)
  assert !diagnostic.has_errors(checked.diagnostics)
  checked.parsed.module
}

pub fn selected_name_fixes_preserve_commas_and_remaining_bindings_test() {
  let first =
    apply_selected_edit(
      "import database.{Unused, Used}\nf(value: Used) { value }",
    )
  let middle =
    apply_selected_edit(
      "import database.{Used, Unused, Other}\nf(a: Used, b: Other) { #(a, b) }",
    )
  let last =
    apply_selected_edit(
      "import database.{Used, Unused,}\nf(value: Used) { value }",
    )
  let assert [first] = first.imports
  let assert [middle] = middle.imports
  let assert [last] = last.imports
  assert list.map(first.items, fn(value) { value.name.name }) == ["Used"]
  assert list.map(middle.items, fn(value) { value.name.name })
    == ["Used", "Other"]
  assert list.map(last.items, fn(value) { value.name.name }) == ["Used"]
}

pub fn removing_the_only_selected_name_keeps_qualified_module_access_test() {
  let syntax =
    apply_selected_edit("import database.{Unused}\nf() { database.used() }")
  let assert [imported] = syntax.imports
  assert imported.items == []
  assert imported.module.segments == ["database"]
}

// Removing an unused import should not reformat the rest of the file. Compare
// the untouched bytes so a helpful fix cannot smuggle in unrelated edits.
pub fn automatic_import_fixes_preserve_other_source_bytes_test() {
  let source = "module main\r\n// Καλημέρα\r\nimport unused\r\nf() { Nil }\r\n"
  let checked = compiler.check_source(support.path, source)
  let edits = fix.automatic(checked.diagnostics, support.path)
  let assert Ok(updated) = fix.apply(source, edits)
  assert updated == "module main\r\n// Καλημέρα\r\n\r\nf() { Nil }\r\n"
}

pub fn warning_snapshot_test() {
  let source =
    "module main\nimport database.{load}\nimport unused\n_helper() { Nil }\nmain() { database.other() }\n"
  let resolved =
    resolve.resolve_with_exports(
      support.parse(source),
      support.path,
      dict.new(),
    )
  unused.check(support.parse(source), support.path, resolved.uses)
  |> render.render_all(
    dict.from_list([#(support.path, source)]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(
    title: "analysis: unused imports and unreachable private declarations",
  )
}

pub fn read_private_members_are_used_test() {
  assert ids(
      "class Counter {\n  let _start: Int = 1\n  start() { _start + _step() }\n  _step() { 1 }\n}",
    )
    == []
}

pub fn unread_private_fields_and_methods_are_reported_test() {
  assert ids(
      "class Counter {\n  let _start: Int = 1\n  _step() { 1 }\n  value() { 2 }\n}",
    )
    == ["analysis.unused_private_member", "analysis.unused_private_member"]
}

// A required constructor write proves initialization, not observation. A
// private field that is never read can still deserve an unused warning.
pub fn initializing_a_field_is_not_reading_it_test() {
  assert ids(
      "class Token {\n  let _secret: Int\n  new(secret) { self._secret = secret }\n}",
    )
    == ["analysis.unused_private_member"]
}

pub fn reading_another_instance_counts_test() {
  assert ids(
      "class Token {\n  let _secret: Int = 1\n  same(other: Token) { other._secret }\n}",
    )
    == []
}

pub fn destructuring_a_private_field_counts_test() {
  assert ids(
      "class Token {\n  let _secret: Int = 1\n  peek(other: Token) { match other { Token(secret) -> secret } }\n}",
    )
    == []
  assert ids(
      "class Token {\n  let _secret: Int = 1\n  peek(other: Token) { match other { Token(_) -> 0 } }\n}",
    )
    == ["analysis.unused_private_member"]
}

pub fn a_local_binding_shadows_a_member_test() {
  assert ids(
      "class Token {\n  let _secret: Int = 1\n  peek() { let _secret = 2\n_secret }\n}",
    )
    == ["analysis.unused_private_member"]
}

pub fn unused_private_actor_members_are_reported_test() {
  assert ids(
      "actor Counter {\n  var _count = 0\n  be _tick() { Nil }\n  value() { 1 }\n}",
    )
    == ["analysis.unused_private_member", "analysis.unused_private_member"]
  assert ids(
      "actor Counter {\n  var _count = 0\n  be tick() { _count += 1 }\n  value() { _count }\n}",
    )
    == []
}

pub fn public_members_are_never_reported_test() {
  assert ids("class User {\n  let name: String = \"x\"\n  greet() { 1 }\n}")
    == []
}

pub fn unused_private_member_snapshot_test() {
  let source =
    "module main\nclass Counter {\n  let _start: Int = 1\n  value() { 2 }\n}\n"
  let syntax = support.parse(source)
  let resolved = resolve.resolve_with_exports(syntax, support.path, dict.new())
  unused.check(syntax, support.path, resolved.uses)
  |> support.render_all(source)
  |> birdie.snap(title: "analysis: unused private member")
}
