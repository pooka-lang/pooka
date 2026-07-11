//// A bookmark is kinder than starting the book again.
////
//// Carry the token cursor, lookahead and accumulated parser errors. Parser
//// routines return updated state rather than sharing an invisible mutable
//// position.
////
//// ```text
//// peek does not consume; advance moves to the next token
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token.{type Lexeme, type Token, Lexeme}
import compiler/parser/parse_error.{type Delimited, type ParseError}
import gleam/list
import utilities/location.{type Position, type Span, Span}

pub opaque type Parser {
  Parser(tokens: List(Lexeme), previous_end: Position, errors: List(ParseError))
}

pub type Parsed(a) =
  Result(#(a, Parser), ParseError)

pub fn new(tokens: List(Lexeme)) -> Parser {
  let tokens =
    list.filter(tokens, fn(lexeme) {
      case lexeme.token {
        token.Comment(_) | token.Unexpected(_) -> False
        _ -> True
      }
    })
  let tokens = case list.last(tokens) {
    Ok(Lexeme(token: token.EndOfFile, ..)) -> tokens
    _ -> list.append(tokens, [end_of_file(location.start())])
  }
  Parser(tokens:, previous_end: location.start(), errors: [])
}

fn end_of_file(at: Position) -> Lexeme {
  Lexeme(token: token.EndOfFile, span: Span(start: at, end: at))
}

pub fn current(parser: Parser) -> Lexeme {
  case skip_documentation(parser.tokens) {
    [lexeme, ..] -> lexeme
    [] -> end_of_file(parser.previous_end)
  }
}

pub fn current_token(parser: Parser) -> Token {
  current(parser).token
}

pub fn peek(parser: Parser) -> Token {
  peek_lexeme(parser).token
}

pub fn peek_lexeme(parser: Parser) -> Lexeme {
  case skip_documentation(parser.tokens) {
    [_, ..rest] ->
      case skip_documentation(rest) {
        [lexeme, ..] -> lexeme
        [] -> end_of_file(parser.previous_end)
      }
    [] -> end_of_file(parser.previous_end)
  }
}

pub fn peek_second(parser: Parser) -> Token {
  case skip_documentation(parser.tokens) {
    [_, ..rest] ->
      case skip_documentation(rest) {
        [_, ..rest] ->
          case skip_documentation(rest) {
            [lexeme, ..] -> lexeme.token
            [] -> token.EndOfFile
          }
        [] -> token.EndOfFile
      }
    [] -> token.EndOfFile
  }
}

pub fn is(parser: Parser, expected: Token) -> Bool {
  current_token(parser) == expected
}

pub fn on_new_line(parser: Parser) -> Bool {
  current(parser).span.start.line > parser.previous_end.line
}

pub fn previous_end(parser: Parser) -> Position {
  parser.previous_end
}

pub fn span_from(parser: Parser, start: Position) -> Span {
  Span(start:, end: parser.previous_end)
}

fn skip_documentation(tokens: List(Lexeme)) -> List(Lexeme) {
  case tokens {
    [Lexeme(token: token.DocComment(_), ..), ..rest]
    | [Lexeme(token: token.ModuleComment(_), ..), ..rest] ->
      skip_documentation(rest)
    _ -> tokens
  }
}

pub fn advance(parser: Parser) -> #(Lexeme, Parser) {
  case skip_documentation(parser.tokens) {
    [Lexeme(token: token.EndOfFile, ..) as lexeme, ..] -> #(lexeme, parser)
    [lexeme, ..rest] -> #(
      lexeme,
      Parser(..parser, tokens: rest, previous_end: lexeme.span.end),
    )
    [] -> #(end_of_file(parser.previous_end), parser)
  }
}

pub fn skip(parser: Parser) -> Parser {
  advance(parser).1
}

pub fn expect(parser: Parser, expected: Token) -> Parsed(Lexeme) {
  case current(parser) {
    Lexeme(token:, ..) if token == expected -> Ok(advance(parser))
    found ->
      Error(parse_error.UnexpectedToken(
        found,
        parse_error.ExpectToken(expected),
      ))
  }
}

pub fn accept(parser: Parser, expected: Token) -> #(Bool, Parser) {
  case is(parser, expected) {
    True -> #(True, skip(parser))
    False -> #(False, parser)
  }
}

pub fn expect_name(parser: Parser, what: String) -> Parsed(#(String, Span)) {
  case current(parser) {
    Lexeme(token: token.Name(name), span:) -> Ok(#(#(name, span), skip(parser)))
    found -> Error(name_error(found, parse_error.ExpectName(what)))
  }
}

pub fn expect_upper_name(
  parser: Parser,
  what: String,
) -> Parsed(#(String, Span)) {
  case current(parser) {
    Lexeme(token: token.UpperName(name), span:) ->
      Ok(#(#(name, span), skip(parser)))
    found -> Error(name_error(found, parse_error.ExpectUpperName(what)))
  }
}

pub fn name_error(
  found: Lexeme,
  expected: parse_error.Expectation,
) -> ParseError {
  case token.is_keyword(found.token) {
    True -> parse_error.ReservedWord(found, expected)
    False -> parse_error.UnexpectedToken(found, expected)
  }
}

pub fn documentation(parser: Parser) -> #(List(String), Parser) {
  documentation_loop(parser, [])
}

fn documentation_loop(
  parser: Parser,
  lines: List(String),
) -> #(List(String), Parser) {
  case parser.tokens {
    [Lexeme(token: token.DocComment(text), span:), ..rest] ->
      documentation_loop(
        Parser(..parser, tokens: rest, previous_end: span.end),
        [text, ..lines],
      )
    [Lexeme(token: token.ModuleComment(_), span:), ..rest] ->
      documentation_loop(
        Parser(..parser, tokens: rest, previous_end: span.end)
          |> report(parse_error.MisplacedModuleDocumentation(span)),
        lines,
      )
    _ -> #(list.reverse(lines), parser)
  }
}

pub fn module_documentation(parser: Parser) -> #(List(String), Parser) {
  module_documentation_loop(parser, [])
}

fn module_documentation_loop(
  parser: Parser,
  lines: List(String),
) -> #(List(String), Parser) {
  case parser.tokens {
    [Lexeme(token: token.ModuleComment(text), span:), ..rest] ->
      module_documentation_loop(
        Parser(..parser, tokens: rest, previous_end: span.end),
        [text, ..lines],
      )
    _ -> #(list.reverse(lines), parser)
  }
}

pub fn report(parser: Parser, error: ParseError) -> Parser {
  Parser(..parser, errors: [error, ..parser.errors])
}

pub fn errors(parser: Parser) -> List(ParseError) {
  list.reverse(parser.errors)
}

pub fn synchronise(parser: Parser) -> Parser {
  synchronise_loop(skip(parser))
}

fn synchronise_loop(parser: Parser) -> Parser {
  let lexeme = current(parser)
  case lexeme.token, lexeme.span.start.column {
    token.EndOfFile, _ -> parser
    _, 1 ->
      case starts_declaration(lexeme.token, peek(parser)) {
        True -> parser
        False -> synchronise_loop(skip(parser))
      }
    _, _ -> synchronise_loop(skip(parser))
  }
}

fn starts_declaration(first: Token, next: Token) -> Bool {
  case first, next {
    token.Class, _
    | token.Interface, _
    | token.Actor, _
    | token.External, _
    | token.Name("native"), token.UpperName(_)
    | token.Name("enum"), token.UpperName(_)
    | token.Test, _
    | token.Import, _
    | token.Module, _
    | token.Fn, _
    | token.Name(_), token.LeftParen
    | token.Name(_), token.Dot
    | token.Name(_), token.Name(_)
    | token.Name(_), token.Class
    -> True
    _, _ -> False
  }
}

pub fn delimited(
  parser: Parser,
  open: Lexeme,
  close: Token,
  context: Delimited,
  item: fn(Parser) -> Parsed(a),
) -> Parsed(List(a)) {
  delimited_loop(parser, open, close, context, item, [])
}

fn delimited_loop(
  parser: Parser,
  open: Lexeme,
  close: Token,
  context: Delimited,
  item: fn(Parser) -> Parsed(a),
  items: List(a),
) -> Parsed(List(a)) {
  case current_token(parser) == close {
    True -> Ok(#(list.reverse(items), skip(parser)))
    False ->
      case item(parser) {
        Error(error) -> Error(unclosed_or(error, parser, open, close, context))
        Ok(#(parsed, parser)) -> {
          let items = [parsed, ..items]
          case current(parser) {
            Lexeme(token: token.Comma, ..) ->
              delimited_loop(skip(parser), open, close, context, item, items)
            Lexeme(token:, ..) if token == close ->
              Ok(#(list.reverse(items), skip(parser)))
            found ->
              case ends_list(found.token) {
                True -> Error(unclosed(parser, open, close, context, found))
                False ->
                  Error(parse_error.UnexpectedToken(
                    found,
                    parse_error.ExpectOneOf([token.Comma, close]),
                  ))
              }
          }
        }
      }
  }
}

fn unclosed_or(
  error: ParseError,
  parser: Parser,
  open: Lexeme,
  close: Token,
  context: Delimited,
) -> ParseError {
  case error {
    parse_error.UnexpectedToken(found:, ..) ->
      case ends_list(found.token) && found == current(parser) {
        True -> unclosed(parser, open, close, context, found)
        False -> error
      }
    _ -> error
  }
}

pub fn unclosed(
  parser: Parser,
  open: Lexeme,
  close: Token,
  context: Delimited,
  found: Lexeme,
) -> ParseError {
  parse_error.UnclosedDelimiter(
    open: open.span,
    close:,
    found:,
    context:,
    insert_at: parser.previous_end,
  )
}

fn ends_list(found: Token) -> Bool {
  case found {
    token.LeftBrace
    | token.RightBrace
    | token.RightParen
    | token.RightSquare
    | token.DoubleGreater
    | token.RightArrow
    | token.Equal
    | token.EndOfFile
    | token.Class
    | token.Interface
    | token.Actor
    | token.External
    | token.Import
    | token.Test
    | token.Let
    | token.Var -> True
    _ -> False
  }
}
