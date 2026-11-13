//// Two small operators, several rooms to visit.
////
//// Follow & and | through tokens, precedence, integer constraints, constant
//// evaluation, BEAM execution and formatting. A bar in a match pattern is a
//// separate syntax question: accepting bitwise-or must not quietly invent
//// alternative patterns.
////
//// ```pooka
//// main() { (12 & 10) | 1 }
//// ```

import birdie
import cli/command
import compiler/constant
import compiler/lexer/token
import compiler/parser/ast
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import support
import tools/formatter

fn front(body: String) -> List(String) {
  support.diagnostic_ids("module main\n" <> body)
}

fn check(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> body),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

fn types(body: String) -> List(String) {
  check(body).diagnostics |> list.map(fn(value) { value.id })
}

fn type_of(body: String, name: String) -> String {
  let report = check(body)
  let assert Ok(function) =
    list.find(report.functions, fn(function) { function.name.name == name })
  monotype.to_string(unify.apply(function.type_, report.state))
}

fn output(name: String, body: String) -> String {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> body)
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
  outcome.stdout
}

fn grouping(expression: ast.Expression) -> String {
  case expression {
    ast.Binary(operator, left, right, _) ->
      "("
      <> grouping(left)
      <> " "
      <> symbol(operator)
      <> " "
      <> grouping(right)
      <> ")"
    ast.IntLiteral(value, _) -> value
    ast.Variable(name, _) -> name
    ast.Unary(ast.Negate, operand, _) -> "-" <> grouping(operand)
    ast.Unary(ast.Not, operand, _) -> "!" <> grouping(operand)
    _ -> "?"
  }
}

fn symbol(operator: ast.BinaryOperator) -> String {
  case operator {
    ast.Add -> "+"
    ast.Subtract -> "-"
    ast.Multiply -> "*"
    ast.Divide -> "/"
    ast.Remainder -> "%"
    ast.Equal -> "=="
    ast.NotEqual -> "!="
    ast.Less -> "<"
    ast.LessOrEqual -> "<="
    ast.Greater -> ">"
    ast.GreaterOrEqual -> ">="
    ast.And -> "&&"
    ast.Or -> "||"
    ast.BitAnd -> "&"
    ast.BitOr -> "|"
    ast.PipeOperator -> "|>"
  }
}

fn grouped(source: String) -> String {
  grouping(support.expression(source))
}

// Single marks are bitwise tokens; doubled marks retain Boolean meaning and
// |> remains a pipe. The neighbouring lexical cases protect those shared
// prefixes.
pub fn ampersand_and_bar_are_tokens_test() {
  assert support.tokens("a & b | c")
    == [
      token.Name("a"),
      token.Ampersand,
      token.Name("b"),
      token.Bar,
      token.Name("c"),
    ]
}

pub fn without_spaces_test() {
  assert support.tokens("a&b|c")
    == [
      token.Name("a"),
      token.Ampersand,
      token.Name("b"),
      token.Bar,
      token.Name("c"),
    ]
}

pub fn doubled_characters_stay_boolean_operators_test() {
  assert support.tokens("a && b || c")
    == [
      token.Name("a"),
      token.DoubleAmpersand,
      token.Name("b"),
      token.DoubleBar,
      token.Name("c"),
    ]
}

pub fn the_pipe_is_still_one_token_test() {
  assert support.tokens("a |> f")
    == [token.Name("a"), token.Pipe, token.Name("f")]
}

pub fn three_bars_are_or_then_bar_test() {
  assert support.tokens("|||") == [token.DoubleBar, token.Bar]
  assert support.tokens("&&&") == [token.DoubleAmpersand, token.Ampersand]
}

pub fn the_tokens_print_as_written_test() {
  assert token.to_source(token.Ampersand) == "&"
  assert token.to_source(token.Bar) == "|"
  assert token.describe(token.Bar) == "`|`"
}

pub fn ampersand_and_bar_are_no_longer_lexical_errors_test() {
  assert front("f(a: Int, b: Int) { a & b }\n") == []
  assert front("f(a: Int, b: Int) { a | b }\n") == []
}

pub fn caret_and_tilde_remain_lexical_errors_test() {
  assert front("f(a: Int, b: Int) { a ^ b }\n") == ["lex.unexpected_characters"]
  assert front("f(a: Int) { ~a }\n") == ["lex.unexpected_characters"]
}

pub fn a_bitwise_and_expression_test() {
  let assert ast.Binary(
    ast.BitAnd,
    ast.Variable("a", _),
    ast.IntLiteral("1", _),
    _,
  ) = support.expression("a & 1")
}

pub fn a_bitwise_or_expression_test() {
  let assert ast.Binary(
    ast.BitOr,
    ast.Variable("a", _),
    ast.IntLiteral("1", _),
    _,
  ) = support.expression("a | 1")
}

pub fn and_binds_tighter_than_or_test() {
  assert grouped("a | b & c") == "(a | (b & c))"
  assert grouped("a & b | c") == "((a & b) | c)"
}

pub fn both_are_left_associative_test() {
  assert grouped("a & b & c") == "((a & b) & c)"
  assert grouped("a | b | c") == "((a | b) | c)"
}

pub fn arithmetic_binds_tighter_than_bitwise_test() {
  assert grouped("a + 1 & b") == "((a + 1) & b)"
  assert grouped("a * 2 | b - 1") == "((a * 2) | (b - 1))"
}

pub fn comparison_binds_looser_than_bitwise_test() {
  assert grouped("flags & mask != 0") == "((flags & mask) != 0)"
  assert grouped("a | b == c") == "((a | b) == c)"
  assert grouped("a & b < c") == "((a & b) < c)"
}

pub fn boolean_operators_bind_looser_than_bitwise_test() {
  assert grouped("a & b == 0 && c | d == 1")
    == "(((a & b) == 0) && ((c | d) == 1))"
}

pub fn unary_minus_binds_tighter_test() {
  assert grouped("-a & b") == "(-a & b)"
}

pub fn parentheses_override_precedence_test() {
  assert grouped("(a | b) & c") == "((a | b) & c)"
}

pub fn the_expression_span_covers_both_operands_test() {
  let source = "module main\nf(a: Int) { a & 255 }\n"
  let module = support.parse(source)
  let assert [ast.FunctionDeclaration(function)] = module.declarations
  let assert [ast.ExpressionStatement(expression)] = function.body.statements
  assert support.text_at(source, ast.expression_span(expression)) == "a & 255"
}

pub fn an_operator_continues_onto_the_next_line_test() {
  let assert [ast.ExpressionStatement(ast.Binary(ast.BitOr, _, _, _))] =
    support.parse_body("a\n  | b")
}

pub fn a_missing_right_operand_is_a_syntax_error_test() {
  assert front("f(a: Int) { a & }\n") != []
  assert front("f(a: Int) { a | }\n") != []
}

pub fn a_leading_operator_is_a_syntax_error_test() {
  assert front("f(a: Int) { & a }\n") != []
}

// Pattern bars belong to the arm header; expression bars keep their old job.
pub fn bar_between_patterns_is_accepted_test() {
  assert front("f(v: Int) { match v { 1 | 2 -> \"small\"\n_ -> \"big\" } }")
    == []
}

pub fn several_alternatives_keep_their_patterns_and_span_test() {
  let source = "module main\nf(v: Int) { match v { 1 | 2 | 3 -> 0\n_ -> 1 } }"
  let module = support.parse(source)
  let assert [ast.FunctionDeclaration(function)] = module.declarations
  let assert [ast.ExpressionStatement(ast.Match(branches: [first, second], ..))] =
    function.body.statements
  let assert ast.AlternativePattern(
    [ast.IntPattern("1", _), ast.IntPattern("2", _), ast.IntPattern("3", _)],
    span,
  ) = first.pattern
  assert support.text_at(source, span) == "1 | 2 | 3"
  let assert ast.DiscardPattern(_) = second.pattern
}

pub fn enum_alternatives_are_accepted_test() {
  assert front(
      "enum Light { Red, Green }\nf(v: Light) { match v { Light.Red | Light.Green -> 0 } }",
    )
    == []
}

pub fn an_alternative_with_a_guard_is_accepted_test() {
  assert front("f(v: Int) { match v { 1 | 2 if v > 0 -> 0\n_ -> 1 } }") == []
}

pub fn bitwise_or_inside_a_guard_is_fine_test() {
  assert front(
      "f(v: Int) {\n  match v {\n    x if x | 1 == 3 -> 0\n    _ -> 1\n  }\n}\n",
    )
    == []
}

pub fn the_result_is_an_int_test() {
  assert type_of("f(a: Int, b: Int) { a & b }\n", "f") == "fn(Int, Int) -> Int"
  assert type_of("f(a: Int, b: Int) { a | b }\n", "f") == "fn(Int, Int) -> Int"
}

pub fn operands_are_inferred_as_ints_test() {
  assert type_of("f(a, b) { a & b }\n", "f") == "fn(Int, Int) -> Int"
  assert type_of("f(a) { a | 1 }\n", "f") == "fn(Int) -> Int"
}

pub fn a_flag_test_is_a_bool_test() {
  assert type_of("has(flags, mask) { flags & mask != 0 }\n", "has")
    == "fn(Int, Int) -> Bool"
}

pub fn floats_are_rejected_test() {
  assert types("f() { 1.5 & 2 }\n") == ["type.unification"]
  assert types("f() { 1 | 2.0 }\n") == ["type.unification"]
}

pub fn strings_are_rejected_test() {
  assert types("f() { \"a\" | \"b\" }\n")
    == ["type.unification", "type.unification"]
}

// The hint belongs to Boolean operands that probably meant && or ||. An
// ordinary integer mismatch must not receive that same advice.
pub fn booleans_are_rejected_with_a_hint_test() {
  let report = check("f() { True | False }\n")
  let assert [first, ..] = report.diagnostics
  assert first.id == "type.unification"
  assert first.suggestions == ["Boolean disjunction is written `||`."]
  let report = check("f(a: Bool) { a & True }\n")
  let assert [first, ..] = report.diagnostics
  assert first.suggestions == ["Boolean conjunction is written `&&`."]
}

pub fn integer_mismatches_get_no_boolean_hint_test() {
  let report = check("f() { 1.5 & 2 }\n")
  let assert [first] = report.diagnostics
  assert first.suggestions == []
}

pub fn a_bool_parameter_is_rejected_test() {
  assert types("f(a: Bool, b: Int) { a | b }\n") == ["type.unification"]
}

pub fn the_result_cannot_be_used_as_a_bool_test() {
  assert types("f(a: Int) -> Bool { a & 1 }\n") == ["type.unification"]
}

pub fn custom_types_are_rejected_test() {
  assert types("class Flag {}\nf() { Flag() | Flag() }\n")
    == ["type.unification", "type.unification"]
}

pub fn constant_expressions_fold_test() {
  assert constant.integer(support.expression("12 & 10")) == Ok(8)
  assert constant.integer(support.expression("12 | 10")) == Ok(14)
  assert constant.integer(support.expression("1 | 2 & 3")) == Ok(3)
  assert constant.integer(support.expression("0xF0 | 0x0F")) == Ok(255)
}

pub fn bitwise_sizes_in_bit_arrays_test() {
  assert types("f() { <<1:size(8 | 8)>> }\n") == []
  assert output(
      "bitwise_size",
      "main() { echo <<1:size(8 | 8), 2:size(24 & 16)>> }\n",
    )
    == "<<1, 0, 2>>\n"
}

pub fn and_and_or_run_test() {
  assert output(
      "bitwise_basic",
      "main() {\n  echo 12 & 10\n  echo 12 | 10\n  echo 0b1100 & 0b1010\n  echo 0xF0 | 0x0F\n}\n",
    )
    == "8\n14\n8\n255\n"
}

pub fn precedence_at_runtime_test() {
  assert output(
      "bitwise_precedence",
      "main() {\n  echo 1 | 2 & 3\n  echo 6 & 3 == 2\n  echo 1 + 2 & 3\n  echo (1 | 2) & 2\n}\n",
    )
    == "3\nTrue\n3\n2\n"
}

pub fn negative_numbers_test() {
  assert output(
      "bitwise_negative",
      "main() {\n  echo -8 & 15\n  echo -1 & 1234\n  echo -16 | 1\n  echo 0 | -1\n}\n",
    )
    == "8\n1234\n-15\n-1\n"
}

pub fn large_integers_test() {
  assert output(
      "bitwise_large",
      "main() {\n  echo 18_446_744_073_709_551_616 | 1\n  echo 18_446_744_073_709_551_617 & 1\n}\n",
    )
    == "18446744073709551617\n1\n"
}

pub fn flags_test() {
  assert output(
      "bitwise_flags",
      "has(flags: Int, flag: Int) -> Bool { flags & flag != 0 }\nmain() {\n  let read = 4\n  let write = 2\n  let execute = 1\n  let mode = read | execute\n  echo #(has(mode, read), has(mode, write), has(mode, execute))\n  echo mode | write\n}\n",
    )
    == "#(True, False, True)\n7\n"
}

// A correct bitwise answer alone would miss reversed effects. This runtime
// fixture also observes the order in which its operands are evaluated.
pub fn operands_are_evaluated_left_to_right_test() {
  assert output(
      "bitwise_order",
      "main() {\n  echo { echo 1 } | { echo 2 }\n}\n",
    )
    == "1\n2\n3\n"
}

pub fn bitwise_results_in_guards_and_patterns_test() {
  assert output(
      "bitwise_guards",
      "parity(n: Int) -> String {\n  match n & 1 {\n    0 -> \"even\"\n    _ -> \"odd\"\n  }\n}\nmain() {\n  echo parity(10)\n  echo parity(7)\n}\n",
    )
    == "\"even\"\n\"odd\"\n"
}

pub fn operators_are_spaced_test() {
  assert formatter.format("module main\n\nf(a: Int) {\n  a&1|2\n}\n")
    == Ok("module main\n\nf(a: Int) {\n  a & 1 | 2\n}\n")
}

pub fn continued_lines_are_indented_test() {
  assert formatter.format("module main\n\nf(a: Int) {\n  a\n  | 1\n  & 2\n}\n")
    == Ok("module main\n\nf(a: Int) {\n  a\n    | 1\n    & 2\n}\n")
}

pub fn formatted_operators_are_stable_test() {
  let source = "module main\n\nf(a: Int) {\n  a & 0xFF | 0x100\n}\n"
  assert formatter.format(source) == Ok(source)
}

pub fn bitwise_diagnostics_snapshot_test() {
  let source =
    "module main\nmain() {\n  let a = True | False\n  let b = 1.5 & 2\n  a\n}\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  let text =
    "Source:\n"
    <> source
    <> "\n---\n"
    <> support.render_all(report.diagnostics, source)
  birdie.snap(text, title: "bitwise operators: type errors")
}
