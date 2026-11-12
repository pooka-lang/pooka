//// Expressions are small sentences with a careful pecking order.
////
//// Parse blocks and operators with precedence, including calls, pipes and postfix
//// propagation. Statement parsing distinguishes bindings and assignments from
//// values.
////
//// ```text
//// input |> parse() -> Binary(PipeOperator, input, Call(parse, []))
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token.{type Lexeme, type Token, Lexeme}
import compiler/literal
import compiler/parser/ast.{type Block, type Expression, type Statement}
import compiler/parser/parse_error
import compiler/parser/parse_parameter
import compiler/parser/parse_pattern
import compiler/parser/state.{type Parsed, type Parser}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import utilities/location

/// Parse statements inside braces, retaining their order and final-expression
/// shape.
///
/// ```text
/// { let n = 1; n + 2 } is a statement-sequence diagram
/// ```
pub fn parse_block(parser: Parser) -> Parsed(Block) {
  use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
  block_body(parser, open, [])
}

fn block_body(
  parser: Parser,
  open: Lexeme,
  statements: List(Statement),
) -> Parsed(Block) {
  case state.current(parser) {
    Lexeme(token: token.RightBrace, ..) -> {
      let parser = state.skip(parser)
      let span = state.span_from(parser, open.span.start)
      Ok(#(ast.Block(statements: list.reverse(statements), span:), parser))
    }
    Lexeme(token: token.EndOfFile, ..) as found ->
      Error(state.unclosed(
        parser,
        open,
        token.RightBrace,
        parse_error.BlockBody,
        found,
      ))
    _ -> {
      use #(statement, parser) <- result.try(parse_statement(parser))
      use parser <- result.try(expect_statement_end(parser))
      block_body(parser, open, [statement, ..statements])
    }
  }
}

fn expect_statement_end(
  parser: Parser,
) -> Result(Parser, parse_error.ParseError) {
  case state.current(parser) {
    Lexeme(token: token.RightBrace, ..) | Lexeme(token: token.EndOfFile, ..) ->
      Ok(parser)
    found ->
      case state.on_new_line(parser) {
        True -> Ok(parser)
        False ->
          Error(parse_error.UnexpectedToken(
            found,
            parse_error.ExpectStatementEnd,
          ))
      }
  }
}

pub fn parse_statement(parser: Parser) -> Parsed(Statement) {
  let start = state.current(parser)
  case start.token {
    token.Let -> parse_let(state.skip(parser), start)
    token.Import -> Error(parse_error.ImportInsideBlock(start.span))
    token.Name(word) ->
      case unsupported_keyword(parser, word) {
        Ok(keyword) ->
          Error(parse_error.UnsupportedKeyword(start.span, keyword))
        Error(Nil) -> expression_statement(parser)
      }
    _ -> expression_statement(parser)
  }
}

fn expression_statement(parser: Parser) -> Parsed(Statement) {
  use #(expression, parser) <- result.try(parse_expression_or_assignment(parser))
  Ok(#(ast.ExpressionStatement(expression), parser))
}

fn unsupported_keyword(
  parser: Parser,
  word: String,
) -> Result(parse_error.MissingKeyword, Nil) {
  use keyword <- result.try(parse_error.missing_keyword(word))
  let next = state.peek_lexeme(parser)
  let same_line = next.span.start.line == state.current(parser).span.end.line
  case same_line && starts_operand(next.token) {
    True -> Ok(keyword)
    False -> Error(Nil)
  }
}

fn starts_operand(found: Token) -> Bool {
  case found {
    token.Name(_)
    | token.UpperName(_)
    | token.Int(_)
    | token.Float(_)
    | token.String(_)
    | token.TrueLiteral
    | token.FalseLiteral
    | token.NilLiteral
    | token.SelfKeyword
    | token.LeftBrace
    | token.LeftSquare
    | token.HashLeftParen
    | token.Bang -> True
    _ -> False
  }
}

fn parse_let(parser: Parser, keyword: Lexeme) -> Parsed(Statement) {
  let #(asserting, parser) = state.accept(parser, token.Assert)
  use #(pattern, parser) <- result.try(parse_pattern.parse_pattern(parser))
  use #(annotation, parser) <- result.try(parse_parameter.parse_annotation(
    parser,
  ))
  use #(_, parser) <- result.try(state.expect(parser, token.Equal))
  use #(value, parser) <- result.try(parse_expression(parser))
  case asserting {
    False -> {
      let span = state.span_from(parser, keyword.span.start)
      Ok(#(ast.LetStatement(pattern:, annotation:, value:, span:), parser))
    }
    True -> {
      use #(message, parser) <- result.try(parse_message(parser))
      let span = state.span_from(parser, keyword.span.start)
      Ok(#(
        ast.LetAssertStatement(pattern:, annotation:, value:, message:, span:),
        parser,
      ))
    }
  }
}

fn parse_message(parser: Parser) -> Parsed(Option(Expression)) {
  case state.is(parser, token.As) {
    False -> Ok(#(None, parser))
    True -> {
      use #(message, parser) <- result.try(parse_expression(state.skip(parser)))
      Ok(#(Some(message), parser))
    }
  }
}

pub fn parse_expression_or_assignment(parser: Parser) -> Parsed(Expression) {
  use #(target, parser) <- result.try(parse_expression(parser))
  let operator = case state.current_token(parser) {
    token.Equal -> Ok(ast.Assign)
    token.PlusEqual -> Ok(ast.AddAssign)
    token.MinusEqual -> Ok(ast.SubtractAssign)
    token.StarEqual -> Ok(ast.MultiplyAssign)
    _ -> Error(Nil)
  }
  case operator {
    Error(Nil) -> Ok(#(target, parser))
    Ok(operator) -> {
      use target <- result.try(assignment_target(target))
      use #(value, parser) <- result.try(parse_expression(state.skip(parser)))
      let target_start = case target {
        ast.AssignVariable(name:) -> name.span.start
        ast.AssignField(span:, ..) -> span.start
      }
      let span = state.span_from(parser, target_start)
      Ok(#(ast.Assignment(target:, operator:, value:, span:), parser))
    }
  }
}

fn assignment_target(
  expression: Expression,
) -> Result(ast.AssignmentTarget, parse_error.ParseError) {
  case expression {
    ast.Variable(name:, span:) -> Ok(ast.AssignVariable(ast.Name(name:, span:)))
    ast.FieldAccess(subject:, name:, span:) ->
      Ok(ast.AssignField(subject:, name:, span:))
    _ ->
      Error(
        parse_error.InvalidAssignmentTarget(ast.expression_span(expression)),
      )
  }
}

/// Parse an expression with the language's operator precedence and postfix
/// chaining rules.
///
/// ```text
/// calls and ? bind before binary operators; 
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#> inserts its left value later|.
pub fn parse_expression(parser: Parser) -> Parsed(Expression) {
  binary(parser, 0)
}

const highest_binary_level = 8

fn binary(parser: Parser, level: Int) -> Parsed(Expression) {
  case level > highest_binary_level {
    True -> unary(parser)
    False -> {
      use #(left, parser) <- result.try(binary(parser, level + 1))
      binary_loop(parser, level, left)
    }
  }
}

fn binary_loop(
  parser: Parser,
  level: Int,
  left: Expression,
) -> Parsed(Expression) {
  case
    binary_operator(
      level,
      state.current_token(parser),
      state.on_new_line(parser),
    )
  {
    Error(Nil) -> Ok(#(left, parser))
    Ok(operator) -> {
      use #(right, parser) <- result.try(binary(state.skip(parser), level + 1))
      let span =
        location.between(
          ast.expression_span(left).start,
          ast.expression_span(right).end,
        )
      binary_loop(parser, level, ast.Binary(operator:, left:, right:, span:))
    }
  }
}

fn binary_operator(
  level: Int,
  found: Token,
  on_new_line: Bool,
) -> Result(ast.BinaryOperator, Nil) {
  case level, found {
    0, token.Pipe -> Ok(ast.PipeOperator)
    1, token.DoubleBar -> Ok(ast.Or)
    2, token.DoubleAmpersand -> Ok(ast.And)
    3, token.EqualEqual -> Ok(ast.Equal)
    3, token.BangEqual -> Ok(ast.NotEqual)
    4, token.Less -> Ok(ast.Less)
    4, token.LessEqual -> Ok(ast.LessOrEqual)
    4, token.Greater -> Ok(ast.Greater)
    4, token.GreaterEqual -> Ok(ast.GreaterOrEqual)
    5, token.Bar -> Ok(ast.BitOr)
    6, token.Ampersand -> Ok(ast.BitAnd)
    7, token.Plus -> Ok(ast.Add)

    7, token.Minus ->
      case on_new_line {
        True -> Error(Nil)
        False -> Ok(ast.Subtract)
      }
    8, token.Star -> Ok(ast.Multiply)
    8, token.Slash -> Ok(ast.Divide)
    8, token.Percent -> Ok(ast.Remainder)
    _, _ -> Error(Nil)
  }
}

fn unary(parser: Parser) -> Parsed(Expression) {
  let start = state.current(parser)
  let operator = case start.token {
    token.Minus -> Ok(ast.Negate)
    token.Bang -> Ok(ast.Not)
    _ -> Error(Nil)
  }
  case operator {
    Error(Nil) -> {
      use #(primary, parser) <- result.try(primary(parser))
      postfix(parser, primary)
    }
    Ok(operator) -> {
      use #(operand, parser) <- result.try(unary(state.skip(parser)))
      let span = state.span_from(parser, start.span.start)
      Ok(#(ast.Unary(operator:, operand:, span:), parser))
    }
  }
}

fn postfix(parser: Parser, expression: Expression) -> Parsed(Expression) {
  let start = ast.expression_span(expression).start
  case state.current(parser) {
    Lexeme(token: token.LeftParen, ..) as open ->
      case state.on_new_line(parser) {
        True -> Ok(#(expression, parser))
        False -> {
          use #(arguments, parser) <- result.try(state.delimited(
            state.skip(parser),
            open,
            token.RightParen,
            parse_error.ArgumentList,
            parse_expression,
          ))
          let span = state.span_from(parser, start)
          postfix(parser, ast.Call(callee: expression, arguments:, span:))
        }
      }
    Lexeme(token: token.Dot, ..) -> {
      let parser = state.skip(parser)
      case state.current(parser) {
        Lexeme(token: token.Int(value), span: index_span) -> {
          use index <- result.try(
            literal.parse_int(value)
            |> result.map_error(fn(_) {
              state.name_error(
                state.current(parser),
                parse_error.ExpectName("a non-negative tuple index"),
              )
            }),
          )
          let parser = state.skip(parser)
          let span = state.span_from(parser, start)
          postfix(
            parser,
            ast.TupleAccess(subject: expression, index:, index_span:, span:),
          )
        }
        _ -> {
          use #(name, parser) <- result.try(member_name(parser))
          let span = state.span_from(parser, start)
          postfix(parser, ast.FieldAccess(subject: expression, name:, span:))
        }
      }
    }
    Lexeme(token: token.Question, ..) -> {
      let parser = state.skip(parser)
      let span = state.span_from(parser, start)
      postfix(parser, ast.Propagate(operand: expression, span:))
    }
    _ -> Ok(#(expression, parser))
  }
}

fn member_name(parser: Parser) -> Parsed(ast.Name) {
  case state.current(parser) {
    Lexeme(token: token.Name(name), span:)
    | Lexeme(token: token.UpperName(name), span:) ->
      Ok(#(ast.Name(name:, span:), state.skip(parser)))
    Lexeme(token: token.New, span:) ->
      Ok(#(ast.Name(name: "new", span:), state.skip(parser)))
    found ->
      Error(state.name_error(
        found,
        parse_error.ExpectName("a field, method or non-negative tuple index"),
      ))
  }
}

fn primary(parser: Parser) -> Parsed(Expression) {
  let start = state.current(parser)
  let span = start.span
  let simple = fn(expression: Expression) {
    Ok(#(expression, state.skip(parser)))
  }
  case start.token {
    token.Int(value) -> simple(ast.IntLiteral(value:, span:))
    token.Float(value) -> simple(ast.FloatLiteral(value:, span:))
    token.String(value) -> simple(ast.StringLiteral(value:, span:))
    token.TrueLiteral -> simple(ast.BoolLiteral(value: True, span:))
    token.FalseLiteral -> simple(ast.BoolLiteral(value: False, span:))
    token.NilLiteral -> simple(ast.NilLiteral(span:))
    token.Name("echo") -> {
      let following = state.skip(parser)
      case
        !state.on_new_line(following)
        && starts_expression(state.current_token(following))
      {
        True -> {
          use #(value, parser) <- result.try(parse_expression(following))
          Ok(#(
            ast.Call(
              ast.Variable("echo", span),
              [value],
              state.span_from(parser, span.start),
            ),
            parser,
          ))
        }
        False -> simple(ast.Variable("echo", span))
      }
    }
    token.Name(name) -> simple(ast.Variable(name:, span:))
    token.UpperName(name) -> simple(ast.TypeName(name:, span:))
    token.SelfKeyword -> simple(ast.SelfExpression(span:))
    token.Super -> simple(ast.SuperExpression(span:))
    token.Continue -> simple(ast.Continue(span:))
    token.LeftParen -> grouping(state.skip(parser), start)
    token.LeftSquare -> {
      use #(elements, parser) <- result.try(state.delimited(
        state.skip(parser),
        start,
        token.RightSquare,
        parse_error.ListLiteral,
        parse_expression,
      ))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.ListExpression(elements:, span:), parser))
    }
    token.HashLeftParen -> {
      use #(elements, parser) <- result.try(state.delimited(
        state.skip(parser),
        start,
        token.RightParen,
        parse_error.TupleLiteral,
        parse_expression,
      ))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.TupleExpression(elements:, span:), parser))
    }
    token.DoubleLess -> {
      use #(segments, parser) <- result.try(state.delimited(
        state.skip(parser),
        start,
        token.DoubleGreater,
        parse_error.BitArrayLiteral,
        bit_array_segment,
      ))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.BitArrayExpression(segments:, span:), parser))
    }
    token.LeftBrace -> {
      use #(block, parser) <- result.try(parse_block(parser))
      Ok(#(ast.BlockExpression(block), parser))
    }
    token.Fn -> anonymous_function(state.skip(parser), start)
    token.Match -> parse_match(state.skip(parser), start)
    token.Loop -> parse_loop(state.skip(parser), start)
    token.Break -> parse_break(state.skip(parser), start)
    token.Panic -> {
      use #(message, parser) <- result.try(parse_message(state.skip(parser)))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.Panic(message:, span:), parser))
    }
    token.Todo -> {
      use #(message, parser) <- result.try(parse_message(state.skip(parser)))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.Todo(message:, span:), parser))
    }
    token.Assert -> {
      use #(condition, parser) <- result.try(
        parse_expression(state.skip(parser)),
      )
      use #(message, parser) <- result.try(parse_message(parser))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.Assert(condition:, message:, span:), parser))
    }
    token.If -> Error(parse_error.IfOutsideGuard(span))
    _ -> Error(parse_error.UnexpectedToken(start, parse_error.ExpectExpression))
  }
}

fn grouping(parser: Parser, open: Lexeme) -> Parsed(Expression) {
  use #(inner, parser) <- result.try(parse_expression(parser))
  case state.current(parser) {
    Lexeme(token: token.RightParen, ..) -> Ok(#(inner, state.skip(parser)))
    found ->
      Error(state.unclosed(
        parser,
        open,
        token.RightParen,
        parse_error.Grouping,
        found,
      ))
  }
}

fn bit_array_segment(
  parser: Parser,
) -> Parsed(ast.BitArraySegment(Expression)) {
  let start = state.current(parser)
  use #(value, parser) <- result.try(binary(parser, 5))
  use #(options, parser) <- result.try(parse_pattern.parse_segment_options(
    parser,
    parse_expression,
  ))
  let span = state.span_from(parser, start.span.start)
  Ok(#(ast.BitArraySegment(value:, options:, span:), parser))
}

fn anonymous_function(parser: Parser, keyword: Lexeme) -> Parsed(Expression) {
  use #(parameters, parser) <- result.try(parse_parameter.parse_parameters(
    parser,
  ))
  use #(return_type, parser) <- result.try(
    parse_parameter.parse_return_annotation(parser),
  )
  use #(body, parser) <- result.try(parse_block(parser))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(ast.AnonymousFunction(parameters:, return_type:, body:, span:), parser))
}

fn parse_break(parser: Parser, keyword: Lexeme) -> Parsed(Expression) {
  case
    state.on_new_line(parser),
    starts_expression(state.current_token(parser))
  {
    False, True -> {
      use #(value, parser) <- result.try(parse_expression(parser))
      let span = state.span_from(parser, keyword.span.start)
      Ok(#(ast.Break(value: Some(value), span:), parser))
    }
    _, _ -> Ok(#(ast.Break(value: None, span: keyword.span), parser))
  }
}

fn starts_expression(found: Token) -> Bool {
  case found {
    token.Minus
    | token.LeftParen
    | token.DoubleLess
    | token.Fn
    | token.Match
    | token.Loop
    | token.Break
    | token.Continue
    | token.Panic
    | token.Todo
    | token.Assert
    | token.Super -> True
    _ -> starts_operand(found)
  }
}

fn parse_match(parser: Parser, keyword: Lexeme) -> Parsed(Expression) {
  use #(subject, parser) <- result.try(parse_expression(parser))
  use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
  branches(parser, keyword, subject, open, [])
}

fn branches(
  parser: Parser,
  keyword: Lexeme,
  subject: Expression,
  open: Lexeme,
  branches_so_far: List(ast.Branch),
) -> Parsed(Expression) {
  case state.current(parser) {
    Lexeme(token: token.RightBrace, ..) -> {
      let parser = state.skip(parser)
      let span = state.span_from(parser, keyword.span.start)
      let branches = list.reverse(branches_so_far)
      Ok(#(ast.Match(subject:, branches:, span:), parser))
    }
    Lexeme(token: token.EndOfFile, ..) as found ->
      Error(state.unclosed(
        parser,
        open,
        token.RightBrace,
        parse_error.MatchBody,
        found,
      ))
    start -> {
      use #(pattern, parser) <- result.try(parse_pattern.parse_pattern(parser))
      use parser <- result.try(alternatives(parser))
      use #(guard, parser) <- result.try(case state.is(parser, token.If) {
        False -> Ok(#(None, parser))
        True -> {
          use #(guard, parser) <- result.try(
            parse_expression(state.skip(parser)),
          )
          Ok(#(Some(guard), parser))
        }
      })
      use #(_, parser) <- result.try(state.expect(parser, token.RightArrow))
      use #(body, parser) <- result.try(parse_expression_or_assignment(parser))
      let span = state.span_from(parser, start.span.start)
      let branch = ast.Branch(pattern:, guard:, body:, span:)
      branches(parser, keyword, subject, open, [branch, ..branches_so_far])
    }
  }
}

fn parse_loop(parser: Parser, keyword: Lexeme) -> Parsed(Expression) {
  use #(iteration, parser) <- result.try(
    case state.is(parser, token.LeftBrace) {
      True -> Ok(#(None, parser))
      False -> {
        let start = state.current(parser)
        use #(pattern, parser) <- result.try(parse_pattern.parse_pattern(parser))
        use parser <- result.try(case state.current(parser) {
          Lexeme(token: token.Name("in"), ..) -> Ok(state.skip(parser))
          found ->
            Error(parse_error.UnexpectedToken(
              found,
              parse_error.ExpectName("`in`"),
            ))
        })
        use #(iterable, parser) <- result.try(parse_expression(parser))
        let span = state.span_from(parser, start.span.start)
        Ok(#(Some(ast.Iteration(pattern:, iterable:, span:)), parser))
      }
    },
  )
  use #(body, parser) <- result.try(parse_block(parser))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(ast.Loop(iteration:, body:, span:), parser))
}

fn alternatives(parser: Parser) -> Result(Parser, parse_error.ParseError) {
  case state.current(parser) {
    Lexeme(token: token.Bar, span: start) -> {
      use parser <- result.try(skip_alternatives(parser))
      let span = location.between(start.start, state.previous_end(parser))
      Ok(state.report(parser, parse_error.PatternAlternatives(span)))
    }
    _ -> Ok(parser)
  }
}

fn skip_alternatives(parser: Parser) -> Result(Parser, parse_error.ParseError) {
  case state.is(parser, token.Bar) {
    False -> Ok(parser)
    True -> {
      use #(_, parser) <- result.try(
        parse_pattern.parse_pattern(state.skip(parser)),
      )
      skip_alternatives(parser)
    }
  }
}
