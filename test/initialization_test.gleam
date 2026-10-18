//// Every returning path must finish furnishing the object.
////
//// Track direct fields through constructor branches, defaults, loops and
//// divergence. Only paths that complete construction owe initialized fields.
//// Closures, lazy messages and short-circuit expressions must contribute
//// effects only when the source evaluation order actually reaches them.
////
//// ```text
//// returning constructor path -> each required field initialized once
//// diverging path             -> no object is returned
//// ```

import birdie
import compiler/analysis/initialization
import gleam/list
import support

fn ids(body: String) -> List(String) {
  initialization.check(
    support.parse("module main\nclass User {\nlet x: Int\n" <> body <> "\n}"),
    support.path,
  )
  |> list.map(fn(value) { value.id })
}

pub fn field_initialized_once_test() {
  assert ids("new(x) { self.x = x }") == []
  assert ids("new(x) { { self.x = x } }") == []
}

pub fn missing_and_duplicate_assignments_test() {
  assert ids("new() { Nil }") == ["analysis.uninitialized_field"]
  assert ids("new() { self.x = 1\nself.x = 2 }")
    == ["analysis.field_initialized_twice"]
}

pub fn all_fields_are_checked_independently_test() {
  assert ids("let y: Int\nnew() { self.x = 1 }")
    == ["analysis.uninitialized_field"]
  assert ids("let y: Int\nnew() { self.y = 2\nself.x = 1 }") == []
}

// Joining branches keeps obligations from every completing path. Initializing
// in one branch cannot excuse a path that returns an unfinished object.
pub fn branches_must_all_initialize_test() {
  assert ids(
      "new(flag) { match flag { True -> { self.x = 1 }\nFalse -> { self.x = 2 } } }",
    )
    == []
  assert ids(
      "new(flag) { match flag { True -> { self.x = 1 }\nFalse -> Nil } }",
    )
    == ["analysis.uninitialized_field"]
  assert ids(
      "new(flag) { match flag { True -> { self.x = 1 }\nFalse -> Nil }\nself.x = 2 }",
    )
    == ["analysis.field_initialized_twice"]
}

// A path that never returns an object has no returned fields to initialize.
// Keep divergence distinct from a normal constructor exit.
pub fn panic_paths_do_not_complete_construction_test() {
  assert ids(
      "new(flag) { match flag { True -> { self.x = 1 }\nFalse -> panic } }",
    )
    == []
  assert ids("new() { panic }") == []
  assert ids("new() { todo }") == []
  assert ids("new() { assert False }") == []
  assert ids("new() { loop {} }") == []
}

pub fn assignments_after_divergence_are_not_executed_test() {
  assert ids("new() { panic\nself.x = 1\nself.x = 2 }") == []
  assert ids("new() { self.x = panic }") == []
}

pub fn loops_track_break_and_continue_paths_test() {
  assert ids("new() { loop { self.x = 1\nbreak } }") == []
  assert ids("new() { loop { break } }") == ["analysis.uninitialized_field"]
  assert ids("new() { loop { self.x = 1 } }")
    == ["analysis.field_initialized_twice"]
  assert ids("new() { loop { self.x = 1\ncontinue } }")
    == ["analysis.field_initialized_twice"]
}

// A loop body can initialize a field only when it runs. The empty-source path
// prevents the analyzer from treating one body visit as guaranteed.
pub fn iterating_loops_may_execute_zero_times_test() {
  let values = ids("new(xs) { loop item in xs { self.x = item\nbreak } }")
  assert values == ["analysis.uninitialized_field"]
  assert ids("new(xs) { loop item in xs { self.x = item\nbreak }\nself.x = 0 }")
    == ["analysis.field_initialized_twice"]
}

pub fn nested_loops_keep_their_own_control_exits_test() {
  assert ids("new() { loop { loop { break }\nself.x = 1\nbreak } }") == []
  assert ids("new() { loop { loop { self.x = 1\nbreak }\nbreak } }") == []
}

pub fn default_values_count_as_initialization_test() {
  let diagnostics =
    support.diagnostic_ids(
      "module main\nclass User { let x = 1\nnew() { self.x = 2 } }",
    )
  assert diagnostics == ["analysis.field_initialized_twice"]
  assert support.diagnostic_ids(
      "module main\nclass User { let x = 1\nnew() {} }",
    )
    == []
}

pub fn actor_fields_follow_constructor_initialization_rules_test() {
  assert support.diagnostic_ids(
      "module main\nactor Counter { var count: Int\nnew() {} }",
    )
    == ["analysis.uninitialized_field"]
  assert support.diagnostic_ids(
      "module main\nactor Counter { var count = 0\nnew() {} }",
    )
    == []
}

pub fn superclass_storage_is_not_a_direct_field_test() {
  assert support.diagnostic_ids(
      "module main\nclass Parent { let y: Int\nnew(y) { self.y = y } }\nclass Child is Parent { let x: Int\nnew(x) { super.new(1)\nself.x = x } }",
    )
    == []
}

// Creating a closure is not executing its body. A deferred assignment cannot
// furnish the object that the constructor is returning now.
pub fn closure_body_does_not_initialize_constructor_fields_test() {
  let diagnostics = ids("new() { let f = fn() { self.x = 1 } }")
  assert list.contains(diagnostics, "analysis.uninitialized_field")
}

pub fn short_circuit_paths_are_preserved_test() {
  assert ids("new(flag) { flag && { self.x = 1\nTrue } }")
    == ["analysis.uninitialized_field"]
  assert ids("new() { True && { self.x = 1\nTrue } }") == []
  assert ids("new() { False || { self.x = 1\nTrue } }") == []
}

pub fn guard_effects_reach_later_branches_test() {
  assert ids(
      "new(flag) { match flag { _ if { self.x = 1\nFalse } -> Nil\n_ -> { self.x = 2 } } }",
    )
    == ["analysis.field_initialized_twice"]
}

pub fn compound_assignment_is_not_initialization_test() {
  let diagnostics = ids("new() { self.x += 1 }")
  assert list.contains(diagnostics, "analysis.compound_field_initialization")
  assert list.contains(diagnostics, "analysis.uninitialized_field")
}

pub fn constructor_flow_snapshot_test() {
  support.rendered(
    "module main\nclass User {\n  let x: Int\n  let y: Int\n  new(flag) {\n    match flag {\n      True -> { self.x = 1 }\n      False -> Nil\n    }\n    self.x = 2\n  }\n}\n",
  )
  |> birdie.snap(title: "analysis: constructor initialization across branches")
}

pub fn irrefutable_assertion_message_is_not_evaluated_test() {
  assert ids(
      "new() { self.x = 1\nlet assert _ = 0 as { self.x = 2\n\"bad\" } }",
    )
    == []
}

// Evaluate the right-hand side before recording the outer field write.
// Effects inside that value can change whether the final assignment is a
// duplicate.
pub fn assignment_arguments_evaluate_before_the_outer_assignment_test() {
  assert ids("new() { self.x = call({ self.x = 1\n2 }) }")
    == ["analysis.field_initialized_twice"]
}

pub fn a_loop_with_guarded_break_paths_can_initialize_once_test() {
  assert ids(
      "new(flag) { loop { match flag { True -> { self.x = 1\nbreak }\nFalse -> continue } } }",
    )
    == []
}

pub fn explicit_field_reads_require_prior_initialization_test() {
  assert ids("new() { self.x = self.x }")
    == ["analysis.field_read_before_initialization"]
  assert ids("new() { self.x = 42\nself.x }") == []
  assert ids(
      "new(flag) { match flag { True -> self.x = 1\nFalse -> Nil }\nself.x\npanic }",
    )
    == ["analysis.field_read_before_initialization"]
}

pub fn implicit_field_reads_respect_lexical_shadowing_test() {
  assert ids("new() { self.x = x }")
    == ["analysis.field_read_before_initialization"]
  assert ids("new(x) { self.x = x }") == []
  assert ids("new() { let x = 42\nself.x = x }") == []
  assert ids("new() { { let x = 42\nx }\nself.x = x }")
    == ["analysis.field_read_before_initialization"]
  assert ids("new(value) { match value { x -> self.x = x } }") == []
}

pub fn receiver_escape_and_closure_capture_require_initialized_fields_test() {
  assert ids("new() { let escaped = self\nself.x = 42 }")
    == ["analysis.field_read_before_initialization"]
  assert ids("new() { let read = fn() { x }\nself.x = 42 }")
    == ["analysis.field_read_before_initialization"]
  assert ids("new() { self.x = 42\nlet read = fn() { x }\nread() }") == []
  assert ids("new() { let read = fn(x) { x }\nself.x = read(42) }") == []
}

pub fn method_references_require_a_complete_receiver_test() {
  assert ids("read() { x }\nnew() { let value = read()\nself.x = value }")
    == ["analysis.field_read_before_initialization"]
  assert ids("read() { x }\nnew(read) { self.x = read() }") == []
  assert ids("read() { x }\nnew() { let read = fn() { 42 }\nself.x = read() }")
    == []
  assert ids("read() { x }\nnew() { self.x = 42\nread() }") == []
}
