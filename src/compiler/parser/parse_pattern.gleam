//// A pattern describes the shape of the parcel, not a new parcel.
////
//// Parse destructuring, constructor and binary patterns while retaining binding
//// spans. Later passes decide whether the shape is well typed and covers every
//// possibility.
////
//// ```pooka
//// match value {
////   Some(x) -> x
////   None -> 0
//// }
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token.{type Lexeme, Lexeme}
import compiler/parser/ast.{type BitArrayOption, type Expression, type Pattern}
import compiler/parser/parse_error
import compiler/parser/state.{type Parsed, type Parser}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import utilities/location

/// Read the structure of one pattern while preserving its binding and constructor
/// spans.
///
/// ```text
/// Some(#(name, count)) -> constructor pattern containing a tuple pattern
/// ```
pub fn parse_pattern(parser: Parser) -> Parsed(Pattern) {
  let start = state.current(parser)
  let span = start.span
  let simple = fn(pattern: Pattern) { Ok(#(pattern, state.skip(parser))) }
  case start.token {
    token.Int(value) -> simple(ast.IntPattern(value:, span:))
    token.Float(value) -> simple(ast.FloatPattern(value:, span:))
    token.String(value) -> simple(ast.StringPattern(value:, span:))
    token.TrueLiteral -> simple(ast.BoolPattern(value: True, span:))
    token.FalseLiteral -> simple(ast.BoolPattern(value: False, span:))
    token.NilLiteral -> simple(ast.NilPattern(span:))
    token.Underscore -> simple(ast.DiscardPattern(span:))
    token.Minus -> negative(state.skip(parser), start)
    token.Name(name) ->
      case state.peek(parser) {
        token.Dot -> qualified_constructor(state.skip(parser), start, name)
        _ -> simple(ast.VariablePattern(name:, span:))
      }
    token.UpperName(name) -> constructor(state.skip(parser), start, None, name)
    token.HashLeftParen -> {
      use #(elements, parser) <- result.try(state.delimited(
        state.skip(parser),
        start,
        token.RightParen,
        parse_error.TupleLiteral,
        parse_pattern,
      ))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.TuplePattern(elements:, span:), parser))
    }
    token.LeftSquare -> list_pattern(state.skip(parser), start, [])
    token.DoubleLess -> {
      use #(segments, parser) <- result.try(state.delimited(
        state.skip(parser),
        start,
        token.DoubleGreater,
        parse_error.BitArrayLiteral,
        segment,
      ))
      let span = state.span_from(parser, span.start)
      Ok(#(ast.BitArrayPattern(segments:, span:), parser))
    }
    _ -> Error(state.name_error(start, parse_error.ExpectPattern))
  }
}

fn negative(parser: Parser, minus: Lexeme) -> Parsed(Pattern) {
  case state.current(parser) {
    Lexeme(token: token.Int(value), ..) -> {
      let parser = state.skip(parser)
      let span = state.span_from(parser, minus.span.start)
      Ok(#(ast.IntPattern(value: "-" <> value, span:), parser))
    }
    Lexeme(token: token.Float(value), ..) -> {
      let parser = state.skip(parser)
      let span = state.span_from(parser, minus.span.start)
      Ok(#(ast.FloatPattern(value: "-" <> value, span:), parser))
    }
    found ->
      Error(parse_error.UnexpectedToken(found, parse_error.ExpectPattern))
  }
}

fn qualified_constructor(
  parser: Parser,
  start: Lexeme,
  module: String,
) -> Parsed(Pattern) {
  use #(#(name, _), parser) <- result.try(state.expect_upper_name(
    state.skip(parser),
    "a class name",
  ))
  constructor(parser, start, Some(module), name)
}

fn constructor(
  parser: Parser,
  start: Lexeme,
  module: Option(String),
  name: String,
) -> Parsed(Pattern) {
  case state.current(parser), state.peek(parser) {
    Lexeme(token: token.Dot, ..), token.UpperName(_) ->
      enum_pattern(state.skip(parser), start, module, name)
    Lexeme(token: token.LeftParen, ..) as open, _ -> {
      use #(arguments, parser) <- result.try(state.delimited(
        state.skip(parser),
        open,
        token.RightParen,
        parse_error.PatternArguments,
        parse_pattern,
      ))
      let span = state.span_from(parser, start.span.start)
      Ok(#(ast.ConstructorPattern(module:, name:, arguments:, span:), parser))
    }
    _, _ -> {
      let span = state.span_from(parser, start.span.start)
      Ok(#(ast.ConstructorPattern(module:, name:, arguments: [], span:), parser))
    }
  }
}

fn enum_pattern(
  parser: Parser,
  start: Lexeme,
  module: Option(String),
  enum_name: String,
) -> Parsed(Pattern) {
  use #(#(name, span), parser) <- result.try(state.expect_upper_name(
    parser,
    "a variant name",
  ))
  let variant = ast.Name(name:, span:)
  let span = state.span_from(parser, start.span.start)
  let pattern = ast.EnumPattern(module:, enum_name:, variant:, span:)
  case state.current(parser) {
    Lexeme(token: token.LeftParen, ..) as open -> {
      use #(_, parser) <- result.try(state.delimited(
        state.skip(parser),
        open,
        token.RightParen,
        parse_error.PatternArguments,
        parse_pattern,
      ))
      let arguments = location.Span(open.span.start, state.previous_end(parser))
      let error = parse_error.EnumPatternArguments(arguments, enum_name, name)
      Ok(#(pattern, state.report(parser, error)))
    }
    _ -> Ok(#(pattern, parser))
  }
}

fn list_pattern(
  parser: Parser,
  open: Lexeme,
  elements: List(Pattern),
) -> Parsed(Pattern) {
  let finish = fn(parser, tail) {
    let span = state.span_from(parser, open.span.start)
    let pattern =
      ast.ListPattern(elements: list.reverse(elements), tail:, span:)
    Ok(#(pattern, parser))
  }
  case state.current(parser) {
    Lexeme(token: token.RightSquare, ..) -> finish(state.skip(parser), None)
    Lexeme(token: token.DotDot, span:) -> {
      let parser = state.skip(parser)
      let #(tail, parser) = case state.current(parser) {
        Lexeme(token: token.Name(name), span: name_span) -> #(
          ast.BoundTail(
            name:,
            span: location.between(span.start, name_span.end),
          ),
          state.skip(parser),
        )
        _ -> #(ast.IgnoredTail(span:), parser)
      }

      let #(_, parser) = state.accept(parser, token.Comma)
      case state.current(parser) {
        Lexeme(token: token.RightSquare, ..) ->
          finish(state.skip(parser), Some(tail))
        found ->
          Error(state.unclosed(
            parser,
            open,
            token.RightSquare,
            parse_error.ListLiteral,
            found,
          ))
      }
    }
    _ -> {
      use #(element, parser) <- result.try(parse_pattern(parser))
      let elements = [element, ..elements]
      case state.current(parser) {
        Lexeme(token: token.Comma, ..) ->
          list_pattern(state.skip(parser), open, elements)
        Lexeme(token: token.RightSquare, ..) ->
          list_pattern(parser, open, elements)
        found ->
          Error(parse_error.UnexpectedToken(
            found,
            parse_error.ExpectOneOf([token.Comma, token.RightSquare]),
          ))
      }
    }
  }
}

fn segment(parser: Parser) -> Parsed(ast.BitArraySegment(Pattern)) {
  let start = state.current(parser)
  use #(value, parser) <- result.try(parse_pattern(parser))
  use #(options, parser) <- result.try(parse_segment_options(
    parser,
    pattern_size,
  ))
  let span = state.span_from(parser, start.span.start)
  Ok(#(ast.BitArraySegment(value:, options:, span:), parser))
}

fn pattern_size(parser: Parser) -> Parsed(Expression) {
  case state.current(parser) {
    Lexeme(token: token.Int(value), span:) ->
      Ok(#(ast.IntLiteral(value:, span:), state.skip(parser)))
    Lexeme(token: token.Name(name), span:) ->
      Ok(#(ast.Variable(name:, span:), state.skip(parser)))
    found ->
      Error(parse_error.UnexpectedToken(found, parse_error.ExpectExpression))
  }
}

pub fn parse_segment_options(
  parser: Parser,
  size: fn(Parser) -> Parsed(Expression),
) -> Parsed(List(BitArrayOption)) {
  case state.is(parser, token.Colon) {
    False -> Ok(#([], parser))
    True -> options_loop(state.skip(parser), size, [])
  }
}

fn options_loop(
  parser: Parser,
  size: fn(Parser) -> Parsed(Expression),
  options: List(BitArrayOption),
) -> Parsed(List(BitArrayOption)) {
  use #(option, parser) <- result.try(segment_option(parser, size))
  let options = [option, ..options]
  case state.is(parser, token.Minus) {
    True -> options_loop(state.skip(parser), size, options)
    False -> Ok(#(list.reverse(options), parser))
  }
}

fn segment_option(
  parser: Parser,
  size: fn(Parser) -> Parsed(Expression),
) -> Parsed(BitArrayOption) {
  let start = state.current(parser)
  case start.token {
    token.Int(value) -> {
      let size = ast.IntLiteral(value:, span: start.span)
      Ok(#(ast.SizeOption(size:, span: start.span), state.skip(parser)))
    }
    token.Name(name) -> {
      let parser = state.skip(parser)
      case name, state.current(parser) {
        "size", Lexeme(token: token.LeftParen, ..) -> {
          use #(argument, parser) <- result.try(option_argument(parser, size))
          let span = state.span_from(parser, start.span.start)
          Ok(#(ast.SizeOption(size: argument, span:), parser))
        }
        "unit", Lexeme(token: token.LeftParen, ..) -> {
          use #(argument, parser) <- result.try(option_argument(parser, size))
          let span = state.span_from(parser, start.span.start)
          Ok(#(ast.UnitOption(unit: argument, span:), parser))
        }
        _, _ -> Ok(#(ast.NamedOption(name:, span: start.span), parser))
      }
    }
    _ ->
      Error(parse_error.UnexpectedToken(start, parse_error.ExpectBitArrayOption))
  }
}

fn option_argument(
  parser: Parser,
  size: fn(Parser) -> Parsed(Expression),
) -> Parsed(Expression) {
  use #(open, parser) <- result.try(state.expect(parser, token.LeftParen))
  use #(argument, parser) <- result.try(size(parser))
  case state.current(parser) {
    Lexeme(token: token.RightParen, ..) -> Ok(#(argument, state.skip(parser)))
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
