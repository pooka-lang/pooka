//// Stand back far enough to see the whole tree.
////
//// Snapshot complete representative ASTs for declarations, patterns and
//// control flow. The smaller parser suites check individual nodes; these
//// fixtures keep their nesting and source metadata visible together.

import birdie
import support

pub fn function_tree_test() {
  support.parse(
    "module math\n\n/// Adds two numbers.\nadd(a: Int, b: Int) -> Int {\n  a + b * 2\n}\n",
  )
  |> support.pretty
  |> birdie.snap(title: "syntax tree: a documented function")
}

pub fn class_tree_test() {
  support.parse(
    "module user\n\nclass User is Person with Printable {\n  let name: String\n\n  new(name) {\n    self.name = name\n  }\n\n  greet() { \"Hello, \" + name }\n}\n",
  )
  |> support.pretty
  |> birdie.snap(title: "syntax tree: a class")
}

pub fn actor_tree_test() {
  support.parse(
    "module counter\n\nactor Counter {\n  var count = 0\n\n  be increment() { count += 1 }\n\n  value() -> Int { count }\n}\n",
  )
  |> support.pretty
  |> birdie.snap(title: "syntax tree: an actor")
}

pub fn imports_tree_test() {
  support.parse(
    "//// Docs.\n\nmodule main\n\nimport io\nimport user as users\nimport account.{User as AccountUser, load}\n",
  )
  |> support.pretty
  |> birdie.snap(title: "syntax tree: module header and imports")
}

pub fn match_tree_test() {
  support.expression(
    "match result {\n  Ok([first, ..rest]) if first > 0 -> first\n  Ok(_) -> 0\n  Error(error) -> panic as \"failed\"\n}",
  )
  |> support.pretty
  |> birdie.snap(title: "syntax tree: a match expression")
}

pub fn loop_tree_test() {
  support.expression(
    "loop item in items {\n  match valid(item) {\n    True -> break item\n    False -> continue\n  }\n}",
  )
  |> support.pretty
  |> birdie.snap(title: "syntax tree: an iteration loop")
}

// Snapshot the pipeline structure before lowering inserts its first argument.
// This makes grouping changes visible independently of runtime behavior.
pub fn pipeline_tree_test() {
  support.expression("input\n|> parse()?\n|> list.map(fn(x) { x * 2 })")
  |> support.pretty
  |> birdie.snap(title: "syntax tree: a pipeline")
}
