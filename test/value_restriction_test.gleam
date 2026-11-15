//// One allocated capability must not become several unrelated static types.

import compiler/typesystem/module_infer
import compiler/typesystem/unify
import diagnostics/diagnostic
import gleam/dict
import support

fn errors(source: String) -> Bool {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> source),
      dict.new(),
      unify.new(),
      support.path,
    )
  diagnostic.has_errors(report.diagnostics)
}

const cell =
  "class Cell(a) {}\nexternal Bridge from erlang \"cell_fixture\" { create() -> Cell(a)\nput(cell: Cell(a), value: a) -> Nil\nget(cell: Cell(a)) -> a }\n"

pub fn allocated_cells_are_not_retyped_between_uses_test() {
  assert errors(
    cell
    <> "main() { let cell = Bridge.create()\nBridge.put(cell, 7)\nlet text: String = Bridge.get(cell)\ntext }",
  )
}

pub fn aliases_and_destructured_containers_preserve_the_cell_type_test() {
  assert errors(
    cell
    <> "main() { let cell = Bridge.create()\nlet alias = cell\nBridge.put(cell, 7)\nlet text: String = Bridge.get(alias)\ntext }",
  )
  assert errors(
    cell
    <> "main() { let #(cell, _) = #(Bridge.create(), Nil)\nBridge.put(cell, 7)\nlet text: String = Bridge.get(cell)\ntext }",
  )
}

pub fn fresh_factories_and_syntactic_functions_remain_polymorphic_test() {
  assert !errors(
    cell
    <> "main() { let factory = fn() { Bridge.create() }\nlet ints = factory()\nlet strings = factory()\nBridge.put(ints, 7)\nBridge.put(strings, \"owl\")\n#(ints, strings) }",
  )
  assert !errors(
    "main() { let identity = fn(value) { value }\n#(identity(1), identity(\"owl\")) }",
  )
}

pub fn immutable_syntactic_values_can_still_be_reused_test() {
  assert !errors(
    "main() { let empty = []\nlet ints: List(Int) = empty\nlet strings: List(String) = empty\n#(ints, strings) }",
  )
}
