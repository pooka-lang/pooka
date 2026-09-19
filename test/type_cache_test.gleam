//// A cached signature must keep all the parameters on its label.
////
//// Reuse inferred interfaces only while their dependencies and layouts still
//// agree. Generic parameter order and even unused parameter arity affect
//// identity. Compare cached results with clean inference so reuse cannot
//// quietly change the meaning of a client.

import builder/infer
import gleam/list
import simplifile
import support

fn setup(dir: String) {
  support.write(dir <> "/pooka.toml", "name = \"app\"\nversion = \"0.1.0\"\n")
  support.write(dir <> "/src/helper.pooka", "module helper\nanswer() { 41 }\n")
  support.write(
    dir <> "/src/other.pooka",
    "module other\nidentity(value) { value }\n",
  )
  support.write(
    dir <> "/src/main.pooka",
    "module main\nimport helper\nmain() { helper.answer() }\n",
  )
}

pub fn inferred_interfaces_reuse_unchanged_clients_and_independent_modules_test() {
  use dir <- support.with_directory("type_cache_interfaces")
  setup(dir)
  let assert Ok(first) = infer.preview(dir)
  assert list.length(first.checked_modules) == 3
  let assert Ok(warm) = infer.preview(dir)
  assert warm.checked_modules == []
  support.write(dir <> "/src/helper.pooka", "module helper\nanswer() { 42 }\n")
  let assert Ok(changed) = infer.preview(dir)
  assert changed.checked_modules == ["helper"]
  support.write(
    dir <> "/src/helper.pooka",
    "module helper\nanswer(value: Int) { value }\n",
  )
  let assert Ok(incompatible) = infer.preview(dir)
  assert list.contains(incompatible.checked_modules, "main")
  assert !list.contains(incompatible.checked_modules, "other")
  assert incompatible.diagnostics != []
}

pub fn cached_generic_interfaces_and_class_layout_changes_agree_with_clean_inference_test() {
  use dir <- support.with_directory("type_cache_nominal")
  setup(dir)
  support.write(
    dir <> "/src/helper.pooka",
    "module helper\nclass Box(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\n",
  )
  support.write(
    dir <> "/src/main.pooka",
    "module main\nimport helper.{Box}\nmain() { #(Box(42).get(), Box(\"text\").get()) }\n",
  )
  let assert Ok(_) = infer.preview(dir)
  support.write(
    dir <> "/src/helper.pooka",
    "//// New documentation.\nmodule helper\nclass Box(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\n",
  )
  let assert Ok(changed) = infer.preview(dir)
  assert changed.checked_modules == ["helper"]
  let assert Ok(Nil) = simplifile.delete(dir <> "/build/analysis")
  let assert Ok(clean) = infer.preview(dir)
  assert changed.diagnostics == clean.diagnostics
  support.write(
    dir <> "/src/helper.pooka",
    "module helper\nclass Box(a) { let value: a\nlet extra: Int = 0\nnew(value) { self.value = value }\nget() { value } }\n",
  )
  let assert Ok(layout_change) = infer.preview(dir)
  assert list.contains(layout_change.checked_modules, "main")
}

// Even an unused parameter occupies a position in the public type
// constructor. Omitting it from the fingerprint can reuse a client against
// the wrong interface shape.
pub fn interface_parameter_order_and_unused_arity_invalidate_clients_test() {
  use dir <- support.with_directory("type_cache_interface_parameters")
  setup(dir)
  support.write(
    dir <> "/src/helper.pooka",
    "module helper\ninterface Pair(a, b) { first() -> a\nsecond() -> b }\n",
  )
  support.write(
    dir <> "/src/main.pooka",
    "module main\nimport helper.{Pair}\nfirst(pair: Pair(Int, String)) -> Int { pair.first() }\n",
  )
  let assert Ok(first) = infer.preview(dir)
  assert first.diagnostics == []
  support.write(
    dir <> "/src/helper.pooka",
    "module helper\ninterface Pair(a, b) { first() -> b\nsecond() -> a }\n",
  )
  let assert Ok(changed) = infer.preview(dir)
  assert list.contains(changed.checked_modules, "main")
  assert changed.diagnostics != []
  let assert Ok(Nil) = simplifile.delete(dir <> "/build/analysis")
  let assert Ok(clean) = infer.preview(dir)
  assert changed.diagnostics == clean.diagnostics
}
