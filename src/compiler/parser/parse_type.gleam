//// Read the promises written beside the code.
////
//// Parse named types, variables, tuples and function types into annotations.
//// Resolving a name to a class or interface is the type checker's later
//// responsibility.
////
//// ```text
//// fn(Int) -> List(String) -> a function-type annotation
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token.{Lexeme}
import compiler/parser/ast.{type TypeAnnotation}
import compiler/parser/parse_error
import compiler/parser/state.{type Parsed, type Parser}
import gleam/option.{None, Some}
import gleam/result

/// Read a written type promise; name resolution belongs to inference, not this
/// grammar routine.
///
/// ```text
/// fn(Int) -> List(String) -> FunctionType annotation
/// ```
pub fn parse_type(parser: Parser) -> Parsed(TypeAnnotation) {
  let start = state.current(parser)
  case start.token {
    token.UpperName(name) -> named(state.skip(parser), start, None, name)

    token.NilLiteral -> named(state.skip(parser), start, None, "Nil")
    token.Name(name) ->
      case state.peek(parser) {
        token.Dot -> qualified(state.skip(parser), start, name)
        _ ->
          Ok(#(ast.TypeVariable(name:, span: start.span), state.skip(parser)))
      }
    token.HashLeftParen -> {
      let parser = state.skip(parser)
      use #(elements, parser) <- result.try(state.delimited(
        parser,
        start,
        token.RightParen,
        parse_error.TupleLiteral,
        parse_type,
      ))
      Ok(#(
        ast.TupleType(
          elements:,
          span: state.span_from(parser, start.span.start),
        ),
        parser,
      ))
    }
    token.Fn -> function_type(state.skip(parser), start)
    _ -> Error(state.name_error(start, parse_error.ExpectType))
  }
}

fn qualified(
  parser: Parser,
  start: token.Lexeme,
  module: String,
) -> Parsed(TypeAnnotation) {
  let parser = state.skip(parser)
  use #(#(name, _), parser) <- result.try(state.expect_upper_name(
    parser,
    "a type name",
  ))
  named(parser, start, Some(module), name)
}

fn named(
  parser: Parser,
  start: token.Lexeme,
  module: option.Option(String),
  name: String,
) -> Parsed(TypeAnnotation) {
  case state.current(parser) {
    Lexeme(token: token.LeftParen, ..) as open -> {
      case state.on_new_line(parser) {
        True ->
          Ok(#(
            ast.NamedType(module:, name:, arguments: [], span: start.span),
            parser,
          ))
        False -> {
          use #(arguments, parser) <- result.try(state.delimited(
            state.skip(parser),
            open,
            token.RightParen,
            parse_error.TypeArguments,
            parse_type,
          ))
          let span = state.span_from(parser, start.span.start)
          Ok(#(ast.NamedType(module:, name:, arguments:, span:), parser))
        }
      }
    }
    _ -> {
      let span = state.span_from(parser, start.span.start)
      Ok(#(ast.NamedType(module:, name:, arguments: [], span:), parser))
    }
  }
}

fn function_type(
  parser: Parser,
  start: token.Lexeme,
) -> Parsed(TypeAnnotation) {
  use #(open, parser) <- result.try(state.expect(parser, token.LeftParen))
  use #(parameters, parser) <- result.try(state.delimited(
    parser,
    open,
    token.RightParen,
    parse_error.ParameterList,
    parse_type,
  ))
  use #(_, parser) <- result.try(state.expect(parser, token.RightArrow))
  use #(return_type, parser) <- result.try(parse_type(parser))
  let span = state.span_from(parser, start.span.start)
  Ok(#(ast.FunctionType(parameters:, return_type:, span:), parser))
}
