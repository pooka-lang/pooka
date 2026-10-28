//// The parent's room must be ready as well.
////
//// Track superclass constructor obligations independently of direct-field
//// initialization. Every completing path calls the parent exactly once with
//// its substituted signature. Divergence and loop exits alter which paths
//// complete; ordinary methods must not reopen construction.

import birdie
import support

fn ids(body: String) -> List(String) {
  support.diagnostic_ids(
    "module main\nclass Parent { let x: Int\nnew(x) { self.x = x } }\nclass Child is Parent {\n"
    <> body
    <> "\n}",
  )
}

pub fn superclass_constructor_is_required_test() {
  assert ids("new(x) { super.new(x) }") == []
  assert ids("new(x) { Nil }") == ["analysis.super_not_initialized"]
}

pub fn superclass_constructor_is_called_exactly_once_test() {
  assert ids("new(x) { super.new(x)\nsuper.new(x) }")
    == ["analysis.super_initialized_twice"]
}

pub fn every_completing_branch_initializes_the_parent_test() {
  assert ids(
      "new(flag) { match flag { True -> super.new(1)\nFalse -> super.new(2) } }",
    )
    == []
  assert ids("new(flag) { match flag { True -> super.new(1)\nFalse -> Nil } }")
    == ["analysis.super_not_initialized"]
}

// Furnishing the child does not initialize the parent, and calling the parent
// does not fill the child's required fields. Track both obligations at the
// join.
pub fn parent_and_own_field_obligations_are_independent_test() {
  assert ids("let y: Int\nnew(x, y) { super.new(x)\nself.y = y }") == []
  assert ids("let y: Int\nnew(x) { super.new(x) }")
    == ["analysis.uninitialized_field"]
  assert ids("let y: Int\nnew(y) { self.y = y }")
    == ["analysis.super_not_initialized"]
}

pub fn superclass_constructor_arguments_match_the_signature_test() {
  assert ids("new() { super.new() }") == ["analysis.super_constructor_arity"]
  assert ids("new() { super.new(1, 2) }")
    == ["analysis.super_constructor_arity"]
}

pub fn diverging_constructor_paths_do_not_require_super_initialization_test() {
  assert ids("new() { panic }") == []
  assert ids(
      "new(flag) { match flag { True -> super.new(1)\nFalse -> panic } }",
    )
    == []
}

pub fn loops_track_super_initialization_test() {
  assert ids("new() { loop { super.new(1)\nbreak } }") == []
  assert ids("new() { loop { super.new(1) } }")
    == ["analysis.super_initialized_twice"]
}

pub fn super_new_cannot_run_in_an_ordinary_method_test() {
  assert ids("get() { super.new(1) }")
    == ["analysis.super_constructor_outside_constructor"]
  assert ids("new() { let f = fn() { super.new(1) } }")
    == [
      "analysis.super_constructor_outside_constructor",
      "analysis.super_not_initialized",
    ]
}

pub fn inherited_constructor_type_substitution_does_not_change_arity_test() {
  assert support.diagnostic_ids(
      "module main\nclass Parent(a) { new(x) {} }\nclass Child is Parent(Int) { new() { super.new(1) } }",
    )
    == []
}

pub fn missing_implicit_constructor_rules_are_not_guessed_test() {
  assert support.diagnostic_ids(
      "module main\nclass Parent {}\nclass Child is Parent {}",
    )
    == []
}

pub fn superclass_initialization_snapshot_test() {
  support.rendered(
    "module main\nclass Parent { new(value) {} }\nclass Child is Parent {\n  new(flag) {\n    match flag {\n      True -> super.new(1)\n      False -> Nil\n    }\n  }\n}\n",
  )
  |> birdie.snap(title: "analysis: superclass initialization on every path")
}
