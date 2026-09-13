//// A confused parser should still find the next page.
////
//// Exercise malformed input, language-specific syntax restrictions and
//// recovery. Missing punctuation must be distinguished from a different nearby
//// error, and later declarations should remain inspectable. Rendering checks
//// keep those recovery decisions tied to useful source labels.

import birdie
import compiler/lexer/token
import compiler/parser/parse_error
import gleam/list
import gleam/string
import support

fn body_ids(body: String) -> List(String) {
  support.diagnostic_ids("module main\n\nmain() {\n" <> body <> "\n}\n")
  |> list.filter(fn(id) { !string.starts_with(id, "analysis.") })
}

fn module_ids(declarations: String) -> List(String) {
  support.diagnostic_ids("module main\n\n" <> declarations <> "\n")
  |> list.filter(fn(id) { !string.starts_with(id, "analysis.") })
}

pub fn unexpected_token_test() {
  let assert [
    parse_error.UnexpectedToken(
      found: token.Lexeme(token: token.RightParen, ..),
      expected: parse_error.ExpectExpression,
    ),
  ] = support.parse_errors("module main\n\nmain() {\n  let value = )\n}\n")
}

pub fn missing_closing_parenthesis_test() {
  let assert [
    parse_error.UnclosedDelimiter(
      close: token.RightParen,
      found: token.Lexeme(token: token.LeftBrace, ..),
      context: parse_error.ParameterList,
      ..,
    ),
  ] = support.parse_errors("module math\n\nadd(a: Int, b: Int {\n  a + b\n}\n")
}

// The closing delimiter may already be present. Diagnose the missing
// separator instead of asking the author to add a parenthesis they have
// written.
pub fn missing_comma_is_not_a_missing_parenthesis_test() {
  let assert [
    parse_error.UnexpectedToken(
      expected: parse_error.ExpectOneOf([token.Comma, token.RightParen]),
      ..,
    ),
  ] = support.parse_errors("module main\n\nmain() {\n  add(1 2)\n}\n")
}

pub fn unclosed_block_test() {
  let assert [
    parse_error.UnclosedDelimiter(
      close: token.RightBrace,
      context: parse_error.BlockBody,
      found: token.Lexeme(token: token.EndOfFile, ..),
      ..,
    ),
  ] = support.parse_errors("module main\n\nmain() {\n  let x = 1\n")
}

pub fn unclosed_list_test() {
  let assert [
    parse_error.UnclosedDelimiter(context: parse_error.ListLiteral, ..),
  ] = support.parse_errors("module main\n\nmain() {\n  [1, 2\n}\n")
}

pub fn two_statements_on_one_line_test() {
  assert body_ids("  let x = a b") == ["parse.unexpected_token"]
}

pub fn reserved_word_as_a_name_test() {
  assert body_ids("  let match = 1") == ["parse.reserved_word"]
  assert module_ids("f(class) {}") == ["parse.reserved_word"]
}

pub fn missing_module_header_test() {
  assert support.diagnostic_ids("main() {}\n")
    == ["parse.missing_module_header"]
  assert support.diagnostic_ids("") == ["parse.missing_module_header"]
}

pub fn module_header_after_imports_test() {
  assert support.diagnostic_ids("import io\nmodule main\n")
    == ["parse.missing_module_header", "parse.module_header_not_first"]
}

pub fn duplicate_module_header_test() {
  assert support.diagnostic_ids("module main\nmodule main\n")
    == ["parse.duplicate_module_header"]
}

pub fn misplaced_module_documentation_test() {
  assert module_ids("//// Late documentation.\nmain() {}")
    == ["parse.misplaced_module_documentation"]
}

pub fn import_inside_a_block_test() {
  assert body_ids("  import database") == ["parse.import_inside_block"]
}

pub fn top_level_expression_test() {
  assert support.diagnostic_ids(
      "module main\n\nimport io\n\nio.println(\"starting\")\n",
    )
    == ["parse.top_level_expression"]
}

pub fn top_level_bindings_test() {
  assert module_ids("let x = 1") == ["parse.top_level_binding"]

  assert module_ids("var cache = 1") == ["parse.top_level_mutable_state"]
}

pub fn named_function_with_fn_test() {
  assert module_ids("fn add(a, b) { a + b }")
    == ["parse.named_function_with_fn"]
}

pub fn named_function_with_fn_keeps_the_declaration_test() {
  let assert [_] =
    support.parse_errors("module main\n\nfn add(a, b) { a + b }\n")
}

pub fn visibility_modifiers_test() {
  assert module_ids("pub class Animal {}") == ["parse.visibility_modifier"]
  assert module_ids("pub greet() {}") == ["parse.visibility_modifier"]
  assert module_ids("class A {\n  private secret() {}\n}")
    == ["parse.visibility_modifier"]
}

pub fn mutable_class_field_test() {
  assert module_ids("class User {\n  var age = 42\n}")
    == ["parse.mutable_class_field"]
}

pub fn behaviour_outside_an_actor_test() {
  assert module_ids("class User {\n  be greet() {}\n}")
    == ["parse.behaviour_outside_actor"]
  assert module_ids("be greet() {}") == ["parse.behaviour_outside_actor"]
}

pub fn multiple_inheritance_test() {
  let assert [
    parse_error.MultipleInheritance(class_name: "Chimera", first: "Lion", ..),
  ] =
    support.parse_errors(
      "module zoo\n\nclass Chimera is Lion, Goat, Snake {}\n",
    )
}

pub fn superclass_after_interfaces_test() {
  assert module_ids("class Dog with Printable is Animal {}")
    == ["parse.superclass_after_interfaces"]
}

pub fn interface_inheritance_test() {
  assert module_ids("interface Ordered is Equatable {}")
    == ["parse.interface_inheritance"]
}

pub fn actor_inheritance_test() {
  assert module_ids("actor Worker is Process {}") == ["parse.actor_inheritance"]
}

pub fn interface_rules_test() {
  assert module_ids(
      "interface Printable {\n  print() -> String {\n    \"default\"\n  }\n}",
    )
    == ["parse.interface_method_body"]
  assert module_ids("interface Named {\n  let name: String\n}")
    == ["parse.interface_field"]
  assert module_ids("interface Made {\n  new() {}\n}")
    == ["parse.interface_constructor"]
  assert module_ids("interface Async {\n  be run() -> Nil\n}")
    == ["parse.interface_behaviour"]
}

pub fn external_without_a_namespace_test() {
  assert module_ids("external now() -> Int")
    == ["parse.external_without_namespace"]
}

pub fn external_errors_test() {
  assert module_ids("external Clock from python \"clock\" { now() -> Int }")
    == ["parse.unsupported_foreign_language"]
  assert module_ids("external Clock from erlang \"\" { now() -> Int }")
    == ["parse.empty_foreign_module"]
  assert module_ids("external Clock from erlang \"clock\" { now(): Int }")
    == ["parse.external_colon_return"]
  assert module_ids("external Clock from erlang \"clock\" { now() }")
    == ["parse.external_missing_return_type"]
  assert module_ids("external Clock from erlang \"clock\" { at(zone) -> Int }")
    == ["parse.external_parameter_type"]
  assert module_ids("external Clock erlang \"clock\" { now() -> Int }")
    == ["parse.unexpected_token"]
  assert module_ids("external Clock from erlang clock { now() -> Int }")
    == ["parse.unexpected_token"]
  assert module_ids("external Clock from erlang \"clock\" {\n  let now: Int\n}")
    == ["parse.reserved_word"]
  assert module_ids("external Clock from erlang \"clock\" {\n  now() -> Int\n")
    == ["parse.unclosed_delimiter"]
}

pub fn external_errors_rendering_test() {
  support.rendered(
    "module main\n\nexternal now() -> Int\n\nexternal Clock from python \"clock\" {\n  now(): Int\n  at(zone) -> Int\n}\n",
  )
  |> birdie.snap(title: "parse diagnostic: external declaration mistakes")
}

pub fn external_with_a_body_test() {
  assert module_ids(
      "external Clock from erlang \"clock\" {\n  now() -> Int {\n    0\n  }\n}",
    )
    == ["parse.external_with_body"]
}

pub fn unsupported_keywords_test() {
  [
    "return x",
    "while ready {",
    "for item in items {",
    "throw error",
    "try load()",
  ]
  |> list.each(fn(body) {
    assert list.first(body_ids("  " <> body)) == Ok("parse.unsupported_keyword")
  })
}

pub fn names_that_merely_look_like_keywords_are_fine_test() {
  assert body_ids("  let for = 1\n  for") == []
  assert body_ids("  return(1)") == []
}

pub fn if_outside_a_guard_test() {
  assert body_ids("  if ready { start() }") == ["parse.if_outside_guard"]
}

pub fn invalid_assignment_target_test() {
  assert body_ids("  load() = 1") == ["parse.invalid_assignment_target"]
}

pub fn independent_errors_are_all_reported_test() {
  let source =
    "module main\n\nfirst() {\n  let x =\n}\n\nsecond() {\n  let y = )\n}\n\nthird() {\n  Nil\n}\n"
  assert list.length(support.parse_errors(source)) == 2
}

// Malformed input should not erase the rest of the file. Check that
// synchronization recovers a later declaration as well as recording the
// earlier failure.
pub fn recovery_keeps_later_declarations_test() {
  let source = "module main\n\nbroken() {\n  let = 1\n}\n\nfine() {\n  Nil\n}\n"
  let module = support.parse_module_with_errors(source)
  assert list.length(module.declarations) == 1
}

// The lexer has already explained the damaged token. Suppress parser noise
// caused by that same damage without hiding independent errors elsewhere.
pub fn errors_on_a_line_with_a_lex_error_are_suppressed_test() {
  assert body_ids("  let name = \"Lucy") == ["lex.unterminated_string"]
}

pub fn unexpected_token_rendering_test() {
  support.rendered("module main\n\nmain() {\n  let value = )\n}\n")
  |> birdie.snap(title: "parse diagnostic: unexpected token")
}

pub fn missing_parenthesis_rendering_test() {
  support.rendered("module math\n\nadd(a: Int, b: Int {\n  a + b\n}\n")
  |> birdie.snap(title: "parse diagnostic: missing closing parenthesis")
}

pub fn unclosed_block_rendering_test() {
  support.rendered("module main\n\nmain() {\n  let x = 1\n  x\n")
  |> birdie.snap(title: "parse diagnostic: unclosed block")
}

pub fn pooka_rule_errors_rendering_test() {
  support.rendered(
    "module zoo\n\npub class Animal {}\n\nclass Chimera is Lion, Goat {}\n\nclass Point {\n  var x = 0.0\n  be move() {}\n}\n\ninterface Printable is Showable {\n  print() -> String { \"default\" }\n}\n\nactor Worker is Process {}\n\nfn add(a, b) { a + b }\n",
  )
  |> birdie.snap(title: "parse diagnostic: Pooka rules about declarations")
}

pub fn missing_keyword_rendering_test() {
  support.rendered(
    "module main\n\nfirst() {\n  return 1\n}\n\nsecond() {\n  while ready {\n    work()\n  }\n}\n\nthird() {\n  if ready { go() }\n}\n",
  )
  |> birdie.snap(title: "parse diagnostic: keywords Pooka does not have")
}

pub fn module_structure_rendering_test() {
  support.rendered(
    "import io\n\nmodule main\n\nmodule other\n\nlet x = 1\n\nio.println(\"hi\")\n",
  )
  |> birdie.snap(title: "parse diagnostic: module structure")
}

pub fn module_header_path_rendering_test() {
  support.rendered("module database/pool\n")
  |> birdie.snap(title: "parse diagnostic: module header with directories")
}

pub fn several_errors_rendering_test() {
  support.rendered(
    "module main\n\nfirst() {\n  let x =\n}\n\nsecond() {\n  add(1 2)\n}\n\nthird() {\n  let name = \"Lucy\n}\n",
  )
  |> birdie.snap(title: "parse diagnostic: several independent errors")
}

pub fn interface_requirements_state_their_full_signature_test() {
  assert module_ids("interface Reader {\n  read() -> String\n}") == []
  assert module_ids("interface Reader {\n  read()\n}")
    == ["parse.requirement_missing_return_type"]
  assert module_ids("interface Reader {\n  read(count) -> String\n}")
    == ["parse.requirement_parameter_type"]
}
