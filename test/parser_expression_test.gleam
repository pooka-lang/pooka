//// Precedence is the seating plan for operators.
////
//// Inspect expression and statement trees before assigning meaning or types.
//// Calls, pipes, propagation and line boundaries must group as written; blocks
//// and match branches retain their own statement structure. A newline can end
//// a statement without ending every continuation.
////
//// ```text
//// 1 + 2 * 3 -> 1 + (2 * 3)
//// value |> f(2) -> a pipeline node, before call lowering
//// ```

import compiler/parser/ast
import gleam/option.{None, Some}
import support

pub fn literals_test() {
  let assert ast.IntLiteral("1_000", _) = support.expression("1_000")
  let assert ast.FloatLiteral("1.5e-4", _) = support.expression("1.5e-4")
  let assert ast.StringLiteral("Hello", _) = support.expression("\"Hello\"")
  let assert ast.BoolLiteral(True, _) = support.expression("True")
  let assert ast.BoolLiteral(False, _) = support.expression("False")
  let assert ast.NilLiteral(_) = support.expression("Nil")
}

pub fn names_test() {
  let assert ast.Variable("user", _) = support.expression("user")
  let assert ast.TypeName("User", _) = support.expression("User")
  let assert ast.SelfExpression(_) = support.expression("self")
}

pub fn collections_test() {
  let assert ast.ListExpression([], _) = support.expression("[]")
  let assert ast.ListExpression([_, _, _], _) = support.expression("[1, 2, 3,]")
  let assert ast.TupleExpression(
    [ast.StringLiteral("Lucy", _), ast.IntLiteral("42", _)],
    _,
  ) = support.expression("#(\"Lucy\", 42)")
  let assert ast.BitArrayExpression([_, _, _], _) =
    support.expression("<<1, 2, 3>>")
}

pub fn bit_array_segment_options_test() {
  let assert ast.BitArrayExpression(
    [
      ast.BitArraySegment(
        value: ast.Variable("size", _),
        options: [ast.SizeOption(ast.IntLiteral("16", _), _)],
        ..,
      ),
      ast.BitArraySegment(
        value: ast.Variable("payload", _),
        options: [
          ast.NamedOption("bits", _),
          ast.UnitOption(ast.IntLiteral("8", _), _),
        ],
        ..,
      ),
    ],
    _,
  ) = support.expression("<<size:16, payload:bits-unit(8)>>")
}

pub fn multiplication_binds_tighter_than_addition_test() {
  let assert ast.Binary(
    ast.Add,
    ast.IntLiteral("1", _),
    ast.Binary(ast.Multiply, _, _, _),
    _,
  ) = support.expression("1 + 2 * 3")
}

pub fn operators_are_left_associative_test() {
  let assert ast.Binary(
    ast.Subtract,
    ast.Binary(ast.Subtract, ast.IntLiteral("1", _), ast.IntLiteral("2", _), _),
    ast.IntLiteral("3", _),
    _,
  ) = support.expression("1 - 2 - 3")
}

pub fn the_full_precedence_ladder_test() {
  let assert ast.Binary(
    ast.PipeOperator,
    _,
    ast.Binary(
      ast.Or,
      _,
      ast.Binary(
        ast.And,
        _,
        ast.Binary(
          ast.Equal,
          _,
          ast.Binary(
            ast.Less,
            _,
            ast.Binary(
              ast.Add,
              _,
              ast.Binary(
                ast.Multiply,
                ast.Unary(ast.Negate, _, _),
                ast.Call(..),
                _,
              ),
              _,
            ),
            _,
          ),
          _,
        ),
        _,
      ),
      _,
    ),
    _,
  ) = support.expression("a |> b || c && d == e < f + -g * h()")
}

pub fn grouping_test() {
  let assert ast.Binary(ast.Multiply, ast.Binary(ast.Add, _, _, _), _, _) =
    support.expression("(a + b) * c")
}

pub fn unary_operators_test() {
  let assert ast.Unary(ast.Negate, ast.IntLiteral("42", _), _) =
    support.expression("-42")
  let assert ast.Unary(ast.Not, ast.Variable("enabled", _), _) =
    support.expression("!enabled")
  let assert ast.Unary(ast.Not, ast.Unary(ast.Not, _, _), _) =
    support.expression("!!x")
}

pub fn every_binary_operator_test() {
  let operator = fn(source) {
    let assert ast.Binary(operator:, ..) = support.expression(source)
    operator
  }
  assert operator("a + b") == ast.Add
  assert operator("a - b") == ast.Subtract
  assert operator("a * b") == ast.Multiply
  assert operator("a / b") == ast.Divide
  assert operator("a % b") == ast.Remainder
  assert operator("a == b") == ast.Equal
  assert operator("a != b") == ast.NotEqual
  assert operator("a < b") == ast.Less
  assert operator("a <= b") == ast.LessOrEqual
  assert operator("a > b") == ast.Greater
  assert operator("a >= b") == ast.GreaterOrEqual
  assert operator("a && b") == ast.And
  assert operator("a || b") == ast.Or
  assert operator("a |> b") == ast.PipeOperator
}

pub fn multi_line_pipes_test() {
  let assert ast.Binary(
    ast.PipeOperator,
    ast.Binary(ast.PipeOperator, ast.Variable("input", _), ast.Call(..), _),
    ast.Call(..),
    _,
  ) = support.expression("input\n  |> parse()\n  |> validate()")
}

pub fn calls_test() {
  let assert ast.Call(ast.Variable("add", _), [_, _], _) =
    support.expression("add(1, 2)")
  let assert ast.Call(ast.Variable("load_config", _), [], _) =
    support.expression("load_config()")
  let assert ast.Call(_, [_, _, _], _) =
    support.expression("create_user(\n  \"Lucy\",\n  42,\n  True,\n)")
}

pub fn method_calls_test() {
  let assert ast.Call(
    ast.FieldAccess(ast.Variable("user", _), ast.Name("greet", _), _),
    [],
    _,
  ) = support.expression("user.greet()")
}

pub fn constructors_test() {
  let assert ast.Call(ast.TypeName("User", _), [_, _], _) =
    support.expression("User(\"Lucy\", 42)")

  let assert ast.FieldAccess(ast.TypeName("User", _), ast.Name("new", _), _) =
    support.expression("User.new")
  let assert ast.Call(
    ast.FieldAccess(ast.SuperExpression(_), ast.Name("new", _), _),
    [_],
    _,
  ) = support.expression("super.new(name)")
}

pub fn qualified_calls_test() {
  let assert ast.Call(
    ast.FieldAccess(ast.Variable("io", _), ast.Name("println", _), _),
    [ast.StringLiteral(..)],
    _,
  ) = support.expression("io.println(\"Hello\")")
}

pub fn propagation_test() {
  let assert ast.FieldAccess(
    ast.Propagate(ast.Call(ast.Variable("parse", _), _, _), _),
    ast.Name("name", _),
    _,
  ) = support.expression("parse(source)?.name")

  let assert ast.Unary(ast.Not, ast.Propagate(..), _) =
    support.expression("!ready()?")
}

// Keep ? attached to the result of the intended pipeline expression. A small
// precedence mistake would propagate one stage too early.
pub fn propagating_a_piped_result_test() {
  let assert ast.Propagate(ast.Binary(ast.PipeOperator, _, _, _), _) =
    support.expression("(input |> parse())?")
}

// Line boundaries participate in statement syntax. A parenthesized expression
// on the next line must not become an argument list for its predecessor.
pub fn a_parenthesis_on_the_next_line_is_not_a_call_test() {
  let assert [
    ast.ExpressionStatement(ast.Variable("first", _)),
    ast.ExpressionStatement(ast.Binary(ast.Add, ..)),
  ] = support.parse_body("first\n(a + b)")
}

pub fn a_minus_at_the_start_of_a_line_starts_a_statement_test() {
  let assert [
    ast.ExpressionStatement(ast.Variable("first", _)),
    ast.ExpressionStatement(ast.Unary(ast.Negate, _, _)),
  ] = support.parse_body("first\n-1")
}

pub fn method_chains_continue_across_lines_test() {
  let assert [
    ast.ExpressionStatement(ast.Call(ast.FieldAccess(ast.Call(..), _, _), _, _)),
  ] = support.parse_body("builder\n  .add(1)\n  .build()")
}

pub fn let_test() {
  let assert [
    ast.LetStatement(
      pattern: ast.VariablePattern("age", _),
      annotation: Some(ast.NamedType(name: "Int", ..)),
      value: ast.IntLiteral("42", _),
      ..,
    ),
  ] = support.parse_body("let age: Int = 42")
}

pub fn let_with_a_pattern_test() {
  let assert [ast.LetStatement(pattern: ast.TuplePattern([_, _], _), ..)] =
    support.parse_body("let #(name, age) = user")
}

pub fn let_assert_test() {
  let assert [
    ast.LetAssertStatement(
      pattern: ast.ConstructorPattern(name: "Ok", arguments: [_], ..),
      message: None,
      ..,
    ),
  ] = support.parse_body("let assert Ok(config) = load_config()")
}

pub fn let_assert_with_a_message_on_the_next_line_test() {
  let assert [
    ast.LetAssertStatement(message: Some(ast.StringLiteral(..)), ..),
    ast.ExpressionStatement(ast.Variable("config", _)),
  ] =
    support.parse_body(
      "let assert Ok(config) = load_config()\n  as \"configuration must be valid\"\nconfig",
    )
}

pub fn assert_test() {
  let assert ast.Assert(ast.Binary(ast.GreaterOrEqual, ..), None, _) =
    support.expression("assert user.age >= 0")
  let assert ast.Assert(_, Some(ast.StringLiteral(..)), _) =
    support.expression("assert user.age >= 0 as \"age must not be negative\"")
}

pub fn blocks_test() {
  let assert [
    ast.LetStatement(..),
    ast.ExpressionStatement(ast.BlockExpression(ast.Block([_, _, _], _))),
  ] = support.parse_body("let x = 1\n{\n  let x = 10\n  let y = 20\n  x + y\n}")
}

pub fn panic_and_todo_test() {
  let assert ast.Panic(Some(ast.StringLiteral("invalid internal state", _)), _) =
    support.expression("panic as \"invalid internal state\"")
  let assert ast.Panic(None, _) = support.expression("panic")
  let assert ast.Todo(Some(_), _) =
    support.expression("todo as \"implement calculation\"")
  let assert ast.Todo(None, _) = support.expression("todo")
}

pub fn compound_assignment_test() {
  let operator = fn(source) {
    let assert ast.Assignment(
      target: ast.AssignVariable(ast.Name("count", _)),
      operator:,
      ..,
    ) = support.expression(source)
    operator
  }
  assert operator("count = 0") == ast.Assign
  assert operator("count += 1") == ast.AddAssign
  assert operator("count -= 1") == ast.SubtractAssign
  assert operator("count *= 2") == ast.MultiplyAssign
}

pub fn field_initialisation_test() {
  let assert ast.Assignment(
    target: ast.AssignField(ast.SelfExpression(_), ast.Name("name", _), _),
    operator: ast.Assign,
    value: ast.Variable("name", _),
    ..,
  ) = support.expression("self.name = name")
}

pub fn anonymous_function_test() {
  let assert ast.AnonymousFunction(
    parameters: [
      ast.Parameter(name: ast.NamedParameter("x"), annotation: None, ..),
    ],
    body: ast.Block([_], _),
    ..,
  ) = support.expression("fn(x) {\n  x * 2\n}")
}

pub fn anonymous_function_as_an_argument_test() {
  let assert ast.Binary(
    ast.PipeOperator,
    _,
    ast.Call(_, [ast.AnonymousFunction(..)], _),
    _,
  ) = support.expression("numbers\n|> list.map(fn(number) {\n  number * 2\n})")
}

pub fn match_test() {
  let assert ast.Match(
    subject: ast.Variable("value", _),
    branches: [
      ast.Branch(
        pattern: ast.ConstructorPattern(name: "Some", ..),
        guard: None,
        body: ast.Variable("text", _),
        ..,
      ),
      ast.Branch(
        pattern: ast.ConstructorPattern(name: "None", arguments: [], ..),
        ..,
      ),
    ],
    ..,
  ) =
    support.expression(
      "match value {\n  Some(text) -> text\n  None -> \"nothing\"\n}",
    )
}

pub fn match_guards_test() {
  let assert ast.Match(
    branches: [
      ast.Branch(guard: Some(ast.Binary(ast.Less, ..)), ..),
      ast.Branch(guard: Some(_), ..),
      ast.Branch(pattern: ast.DiscardPattern(_), guard: None, ..),
    ],
    ..,
  ) =
    support.expression(
      "match age {\n  age if age < 18 -> \"child\"\n  age if age < 65 -> \"adult\"\n  _ -> \"senior\"\n}",
    )
}

pub fn match_branch_blocks_test() {
  let assert ast.Match(
    branches: [
      ast.Branch(body: ast.BlockExpression(ast.Block([_, _], _)), ..),
      ast.Branch(body: ast.BlockExpression(_), ..),
    ],
    ..,
  ) =
    support.expression(
      "match result {\n  Ok(value) -> {\n    let normalized = normalize(value)\n    save(normalized)\n  }\n\n  Error(error) -> {\n    log_error(error)\n    Nil\n  }\n}",
    )
}

pub fn match_branch_with_an_assignment_test() {
  let assert ast.Match(
    branches: [ast.Branch(body: ast.Assignment(..), ..), _],
    ..,
  ) =
    support.expression(
      "match config.port {\n  Some(port) -> self.port = port\n  None -> Nil\n}",
    )
}

pub fn match_as_a_binding_value_test() {
  let assert [ast.LetStatement(value: ast.Match(..), ..)] =
    support.parse_body(
      "let description = match status {\n  Ready -> \"ready\"\n}",
    )
}

pub fn unbounded_loop_test() {
  let assert ast.Loop(iteration: None, body: ast.Block([_, _], _), ..) =
    support.expression(
      "loop {\n  let message = next_message()\n  process(message)\n}",
    )
}

pub fn iteration_loop_test() {
  let assert ast.Loop(
    iteration: Some(ast.Iteration(
      pattern: ast.VariablePattern("item", _),
      iterable: ast.Variable("items", _),
      ..,
    )),
    ..,
  ) = support.expression("loop item in items {\n  process(item)\n}")
}

pub fn break_and_continue_test() {
  let assert ast.Loop(
    body: ast.Block(
      [
        ast.ExpressionStatement(ast.Match(
          branches: [
            ast.Branch(body: ast.Break(Some(ast.Variable("item", _)), _), ..),
            ast.Branch(body: ast.Continue(_), ..),
          ],
          ..,
        )),
      ],
      _,
    ),
    ..,
  ) =
    support.expression(
      "loop item in items {\n  match valid(item) {\n    True -> break item\n    False -> continue\n  }\n}",
    )
}

// A bare break ends at its line boundary. The next statement must not be
// consumed as the value escaping the loop.
pub fn a_break_at_the_end_of_a_line_has_no_value_test() {
  let assert ast.Match(
    branches: [ast.Branch(body: ast.Break(None, _), ..), ast.Branch(..)],
    ..,
  ) =
    support.expression(
      "match message {\n  Stop -> break\n  message -> process(message)\n}",
    )
}

pub fn bit_array_sizes_accept_full_expressions_test() {
  let assert ast.BitArrayExpression(
    [
      ast.BitArraySegment(
        options: [
          ast.SizeOption(ast.Binary(ast.Add, _, _, _), _),
          ast.UnitOption(_, _),
        ],
        ..,
      ),
    ],
    _,
  ) = support.expression("<<1:size(a + b)-unit(8)>>")
}
