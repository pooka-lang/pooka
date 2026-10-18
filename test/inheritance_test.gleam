//// A closed family needs a boundary the compiler can see.
////
//// Check which declarations may extend classes and how inheritance errors are
//// located. Class hierarchies stay within their defining module, while
//// interface implementations remain open across modules. Unknown and cyclic
//// parents must fail without trapping the analysis.

import birdie
import support

fn ids(body: String) -> List(String) {
  support.diagnostic_ids("module main\n" <> body)
}

pub fn same_module_inheritance_is_allowed_test() {
  assert ids("class Animal {}\nclass Dog is Animal {}") == []
  assert ids("class Dog is Animal {}\nclass Animal {}") == []
}

pub fn imported_superclasses_are_rejected_test() {
  assert ids("import animal.{Animal}\nclass Dog is Animal {}")
    == ["analysis.external_superclass"]
  assert ids("import animal.{Animal as Parent}\nclass Dog is Parent {}")
    == ["analysis.external_superclass"]
}

pub fn qualified_imported_superclasses_are_rejected_test() {
  assert ids("import pets/animal\nclass Dog is animal.Animal {}")
    == ["analysis.external_superclass"]
  assert ids("import pets/animal as pets\nclass Dog is pets.Animal {}")
    == ["analysis.external_superclass"]
  assert ids("import pets/animal.{Animal}\nclass Dog is animal.Animal {}")
    == ["analysis.external_superclass"]
}

// The closed boundary applies to class inheritance. It must not accidentally
// close interface implementation to declarations in other modules.
pub fn interfaces_remain_open_across_modules_test() {
  assert ids("import printable.{Printable}\nclass Dog with Printable {}") == []
  assert ids("import printable\nactor Dog with printable.Printable {}") == []
}

pub fn unknown_parent_names_are_reported_test() {
  assert ids("class Dog is Unknown {}") == ["analysis.unknown_superclass"]
  assert ids("class Dog is unknown.Animal {}")
    == ["analysis.unknown_module_qualifier"]
}

pub fn inheritance_diagnostic_snapshot_test() {
  support.rendered(
    "module main\nimport pets/animal.{Animal as Parent}\nclass Dog is Parent {}\n",
  )
  |> birdie.snap(title: "analysis: class inheritance is closed by module")
}

pub fn superclass_kind_must_be_a_local_class_test() {
  assert ids("actor Parent {}\nclass Child is Parent {}")
    == ["analysis.invalid_superclass"]
  assert ids("interface Parent {}\nclass Child is Parent {}")
    == ["analysis.invalid_superclass"]
  assert ids("class Child is Int {}") == ["analysis.invalid_superclass"]
  assert ids("class Child(a) is a {}") == ["analysis.invalid_superclass"]
  assert ids("class Child is #(Int, String) {}")
    == ["analysis.invalid_superclass"]
  assert ids("class Child is fn(Int) -> Int {}")
    == ["analysis.invalid_superclass"]
}

pub fn superclass_generic_arity_is_checked_test() {
  assert ids("class Box(a) {}\nclass Child is Box(Int) {}") == []
  assert ids("class Box(a) {}\nclass Child is Box {}")
    == ["analysis.superclass_arity"]
  assert ids("class Box(a) {}\nclass Child is Box(Int, String) {}")
    == ["analysis.superclass_arity"]
  assert ids("class Parent {}\nclass Child is Parent(Int) {}")
    == ["analysis.superclass_arity"]
}

pub fn self_inheritance_is_a_cycle_test() {
  assert ids("class User is User {}") == ["analysis.inheritance_cycle"]
}

pub fn longer_inheritance_cycles_are_reported_once_test() {
  assert ids("class A is B {}\nclass B is C {}\nclass C is A {}")
    == ["analysis.inheritance_cycle"]
  assert ids("class Entry is A {}\nclass A is B {}\nclass B is A {}")
    == ["analysis.inheritance_cycle"]
}

pub fn independent_inheritance_cycles_are_all_reported_test() {
  assert ids(
      "class A is B {}\nclass B is A {}\nclass C is D {}\nclass D is C {}",
    )
    == ["analysis.inheritance_cycle", "analysis.inheritance_cycle"]
}

pub fn acyclic_branches_and_forward_references_are_valid_test() {
  assert ids(
      "class Left is Parent {}\nclass Right is Parent {}\nclass Parent is Root {}\nclass Root {}",
    )
    == []
}

pub fn inherited_type_arguments_are_checked_without_specializing_variables_test() {
  assert ids("class Box(a) {}\nclass Child(b) is Box(b) {}") == []
}

pub fn inheritance_cycle_snapshot_test() {
  support.rendered(
    "module main\nclass A is B {}\nclass B is C {}\nclass C is A {}\n",
  )
  |> birdie.snap(title: "analysis: inheritance cycle")
}
