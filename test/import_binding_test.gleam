//// An import gives a name a particular owner.
////
//// Check collisions between module qualifiers, selected exports and local
//// declarations. Aliasing must not open private declarations, and a selective
//// import still leaves the module qualifier available. Duplicate bindings
//// should produce one useful complaint.

import birdie
import compiler/analysis/import_binding
import gleam/list
import support

fn ids(imports: String) -> List(String) {
  import_binding.check(support.parse("module main\n" <> imports), support.path)
  |> list.map(fn(value) { value.id })
}

pub fn module_qualifier_collisions_test() {
  assert ids("import account/user\nimport admin/user")
    == ["analysis.import_collision"]
  assert ids("import user\nimport user") == ["analysis.import_collision"]
  assert ids("import account/user as account\nimport admin/user as admin") == []
}

pub fn selective_name_collisions_test() {
  assert ids("import account.{User}\nimport admin.{User}")
    == ["analysis.import_collision"]
  assert ids("import account.{User}\nimport admin.{User as User}")
    == ["analysis.import_collision"]
  assert ids("import account.{User}\nimport admin.{User as AdminUser}") == []
  assert ids("import account.{User, User}") == ["analysis.import_collision"]
}

// Selecting one export adds a local binding without deleting the module
// qualifier. Both ways of naming the imported module remain available.
pub fn selective_import_keeps_module_qualifier_test() {
  assert ids("import account.{User}\naccount() {}")
    == ["analysis.import_collision"]
  assert ids("import account.{load as account}")
    == ["analysis.import_collision"]
}

pub fn imports_and_declarations_cannot_shadow_test() {
  assert ids("import account.{User}\nclass User {}")
    == ["analysis.import_collision"]
  assert ids("import account.{User}\nactor User {}")
    == ["analysis.import_collision"]
  assert ids("import account.{User}\ninterface User {}")
    == ["analysis.import_collision"]
  assert ids(
      "import account.{Native}\nexternal Native from erlang \"native\" { load() -> Nil }",
    )
    == ["analysis.import_collision"]
}

pub fn declaration_duplicates_are_reported_once_test() {
  assert support.diagnostic_ids("module main\nf() {}\nf() {}")
    == ["analysis.duplicate_declaration"]
}

pub fn private_names_cannot_be_imported_even_with_aliases_test() {
  assert ids("import account.{_secret}") == ["analysis.private_import"]
  assert ids("import account.{_secret as secret}")
    == ["analysis.private_import"]
  assert ids("import account.{load as _load}") == []
}

pub fn local_lexical_shadowing_remains_valid_test() {
  assert ids("import account.{load}\nf(load) { load }") == []
  assert ids("import account\nf(account) { account }") == []
}

pub fn import_diagnostics_snapshot_test() {
  support.rendered(
    "module main\nimport account.{User, _secret as secret}\nimport admin.{User}\naccount() {}\n",
  )
  |> birdie.snap(title: "analysis: import collisions and private declarations")
}
