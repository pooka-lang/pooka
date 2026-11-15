//// The same word can answer a different door.
////
//// A module's new function is an ordinary value. Inside a class or actor,
//// the existing constructor syntax still belongs to that declaration.

import birdie
import cli/command
import compiler/compiler
import compiler/parser/ast
import gleam/list
import gleam/string
import support
import tools/formatter

pub fn module_new_functions_have_ordinary_function_syntax_test() {
  let syntax =
    support.parse(
      "module jar\nnew(value: Int) -> Int { value }\nmain() { new(42) }\n",
    )
  let assert [ast.FunctionDeclaration(function), ..] = syntax.declarations
  assert function.name.name == "new"
  assert support.diagnostic_ids("module main\nnew() { 1 }\nmain() { new() }")
    == []
}

pub fn new_is_a_function_value_and_keeps_its_constructor_context_test() {
  use directory <- support.with_directory("module_new_runtime")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/jar.pooka",
    "module jar\nclass Jar(contents: String)\nnew(contents: String) -> Jar { Jar(contents) }\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport jar.{new as make}\nclass Box { let value: Int\n new(value) { self.value = value } }\nactor Worker { new() {} }\nnew(value: Int) -> Int { value + 1 }\nmain() { let create = new\nassert create(2) == 3\nassert Box(4).value == 4\nassert jar.new(\"jam\").contents == \"jam\"\nassert make(\"tea\").contents == \"tea\"\nNil }\n",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 0
}

pub fn imported_new_can_keep_its_name_test() {
  use directory <- support.with_directory("module_new_import")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(directory <> "/src/jar.pooka", "module jar\nnew() { 42 }\n")
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport jar.{new}\nmain() { assert new() == 42 }\n",
  )
  assert support.cli_main(["run"], command.plain(directory)).status == 0
}

pub fn formatting_module_new_is_stable_test() {
  let source = "module main\nnew(value:Int)->Int{value}\nmain(){new(42)}\n"
  let assert Ok(formatted) = formatter.format(source)
  assert formatter.format(formatted) == Ok(formatted)
  assert string.contains(formatted, "new(value: Int) -> Int")
  birdie.snap(formatted, "module new function formatting")
}

pub fn other_reserved_function_names_remain_rejected_test() {
  list.each(["let", "class", "match", "panic"], fn(word) {
    let checked =
      compiler.check_source(
        "src/main.pooka",
        "module main\n" <> word <> "() {}\n",
      )
    assert checked.parsed.errors != []
  })
  assert compiler.check_source(
      "src/main.pooka",
      "module main\nmain() { let new = 1 }",
    ).parsed.errors
    != []
}
