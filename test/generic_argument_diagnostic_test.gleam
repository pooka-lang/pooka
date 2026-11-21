//// A generic disagreement needs both ends of the thread.
////
//// The factory is not wrong on its own. Its result disagrees with the type
//// carried by the key, so the diagnostic must retain that earlier constraint.

// SPDX-License-Identifier: Apache-2.0

import birdie
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import support

const declarations =
  "module main\nclass Device {}\nactor Worker { new() {} }\nclass Key(a) {}\nchild(key: Key(a), start: fn() -> a) { #(key, start) }\n"

fn check(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse(declarations <> body),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

pub fn conflicting_key_and_factory_keep_both_argument_locations_test() {
  let body =
    "main() {\n  let key: Key(Device) = Key()\n  child(key, fn() { Worker() })\n}\n"
  let report = check(body)
  let assert [error] = report.diagnostics
  assert list.length(error.labels) == 3
  support.render_all(report.diagnostics, declarations <> body)
  |> birdie.snap(title: "types generic key and factory constraint origins")
}

pub fn matching_key_and_factory_remain_valid_test() {
  assert check(
      "main() { let key: Key(Worker) = Key()\nchild(key, fn() { Worker() }) }",
    ).diagnostics
    == []
}

pub fn ordinary_generic_conflicts_keep_the_earlier_argument_test() {
  let report =
    check(
      "pair(first: a, second: a) { #(first, second) }\nmain() { pair(1, True) }",
    )
  let assert [error] = report.diagnostics
  assert list.length(error.labels) == 3
}
