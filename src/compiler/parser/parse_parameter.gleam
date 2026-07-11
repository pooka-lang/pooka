//// A parameter introduces a guest; its annotation checks the invitation.
////
//// Parse parameter lists, binding annotations and callable returns. Colon belongs
//// to parameter and binding types; the return arrow belongs to the callable.
////
//// ```pooka
//// identity(value: Int) -> Int { value }
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token
import compiler/parser/ast.{type Parameter, type TypeAnnotation}
import compiler/parser/parse_error
import compiler/parser/parse_type
import compiler/parser/state.{type Parsed, type Parser}
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn parse_parameters(parser: Parser) -> Parsed(List(Parameter)) {
  use #(open, parser) <- result.try(state.expect(parser, token.LeftParen))
  state.delimited(
    parser,
    open,
    token.RightParen,
    parse_error.ParameterList,
    parse_parameter,
  )
}

pub fn parse_parameter(parser: Parser) -> Parsed(Parameter) {
  let start = state.current(parser)
  use #(name, parser) <- result.try(case start.token {
    token.Name(name) -> Ok(#(ast.NamedParameter(name), state.skip(parser)))
    token.Underscore -> Ok(#(ast.DiscardedParameter, state.skip(parser)))
    _ -> Error(state.name_error(start, parse_error.ExpectParameter))
  })
  use #(annotation, parser) <- result.try(parse_annotation(parser))
  let span = state.span_from(parser, start.span.start)
  Ok(#(ast.Parameter(name:, annotation:, span:), parser))
}

pub fn parse_annotation(parser: Parser) -> Parsed(Option(TypeAnnotation)) {
  case state.is(parser, token.Colon) {
    False -> Ok(#(None, parser))
    True -> {
      use #(annotation, parser) <- result.try(
        parse_type.parse_type(state.skip(parser)),
      )
      Ok(#(Some(annotation), parser))
    }
  }
}

/// Read the return arrow consistently for functions, methods and anonymous
/// functions. A colon return produces a recoverable migration diagnostic.
///
/// ```pooka
/// identity(value: Int) -> Int { value }
/// ```
pub fn parse_return_annotation(
  parser: Parser,
) -> Parsed(Option(TypeAnnotation)) {
  case state.current(parser) {
    token.Lexeme(token: token.RightArrow, ..) -> {
      use #(annotation, parser) <- result.try(
        parse_type.parse_type(state.skip(parser)),
      )
      Ok(#(Some(annotation), parser))
    }
    token.Lexeme(token: token.Colon, span:) -> {
      let parser =
        state.report(state.skip(parser), parse_error.CallableColonReturn(span))
      use #(annotation, parser) <- result.try(parse_type.parse_type(parser))
      Ok(#(Some(annotation), parser))
    }
    _ -> Ok(#(None, parser))
  }
}
