//// Invite the tokens to sit in declaration order.
////
//// Parse a complete token stream and retain recoverable syntax errors alongside
//// the module. Recovery lets the compiler report more than the first misplaced
//// token.
////
//// ```text
//// located tokens -> Module + parse errors
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token.{type Lexeme, Lexeme}
import compiler/parser/ast
import compiler/parser/parse_declaration
import compiler/parser/parse_error.{type ParseError}
import compiler/parser/parse_expression
import compiler/parser/state.{type Parsed, type Parser}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import utilities/location

pub type Output {
  Output(module: ast.Module, errors: List(ParseError))
}

/// Parse located tokens into a module plus recoverable errors. Module and
/// declaration comments attach to their respective syntax nodes.
///
/// ```text
/// //// overview then module main -> Module.documentation contains overview
/// ```
pub fn parse(tokens: List(Lexeme)) -> Output {
  let parser = state.new(tokens)
  let #(documentation, parser) = state.module_documentation(parser)

  let parser = case state.current(parser) {
    Lexeme(token: token.Module, ..) -> parser
    first -> state.report(parser, parse_error.MissingModuleHeader(first.span))
  }
  let contents = top_level(parser, Contents(None, [], []))
  let module =
    ast.Module(
      documentation:,
      header: contents.header,
      imports: list.reverse(contents.imports),
      declarations: list.reverse(contents.declarations),
    )
  let errors =
    contents.parser
    |> state.errors
    |> list.sort(fn(first, second) {
      location.compare(parse_error.span(first), parse_error.span(second))
    })
  Output(module:, errors:)
}

type Contents {
  Contents(
    header: Option(ast.ModuleHeader),
    imports: List(ast.Import),
    declarations: List(ast.Declaration),
  )
}

type Finished {
  Finished(
    parser: Parser,
    header: Option(ast.ModuleHeader),
    imports: List(ast.Import),
    declarations: List(ast.Declaration),
  )
}

fn top_level(parser: Parser, contents: Contents) -> Finished {
  let #(documentation, parser) = state.documentation(parser)
  let start = state.current(parser)
  case start.token {
    token.EndOfFile ->
      Finished(
        parser:,
        header: contents.header,
        imports: contents.imports,
        declarations: contents.declarations,
      )

    token.Module ->
      case parse_header(state.skip(parser), start) {
        Ok(#(header, parser)) -> {
          let parser = case contents {
            Contents(header: Some(first), ..) ->
              state.report(
                parser,
                parse_error.DuplicateModuleHeader(header.span, first.span),
              )
            Contents(header: None, imports: [], declarations: []) -> parser
            Contents(header: None, ..) ->
              state.report(
                parser,
                parse_error.ModuleHeaderNotFirst(header.span),
              )
          }
          let header = option.or(contents.header, Some(header))
          top_level(parser, Contents(..contents, header:))
        }
        Error(error) -> recover(parser, error, contents)
      }

    token.Import ->
      case parse_import(state.skip(parser), start) {
        Ok(#(import_, parser)) ->
          top_level(
            parser,
            Contents(..contents, imports: [import_, ..contents.imports]),
          )
        Error(error) -> recover(parser, error, contents)
      }

    _ ->
      case declaration(parser, documentation) {
        Ok(#(declaration, parser)) ->
          top_level(
            parser,
            Contents(..contents, declarations: [
              declaration,
              ..contents.declarations
            ]),
          )
        Error(error) -> recover(parser, error, contents)
      }
  }
}

fn recover(parser: Parser, error: ParseError, contents: Contents) -> Finished {
  parser
  |> state.report(error)
  |> state.synchronise
  |> top_level(contents)
}

fn parse_header(parser: Parser, keyword: Lexeme) -> Parsed(ast.ModuleHeader) {
  use #(path, parser) <- result.try(module_path(parser))
  let parser = case path.segments {
    [_] | [] -> parser
    [_, _, ..] ->
      state.report(
        parser,
        parse_error.ModuleHeaderPath(
          path: path.span,
          name: last_segment(path),
          full_path: string.join(path.segments, "/"),
        ),
      )
  }
  let name = ast.Name(name: last_segment(path), span: last_segment_span(path))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(ast.ModuleHeader(name:, span:), parser))
}

fn last_segment(path: ast.ModulePath) -> String {
  case list.last(path.segments) {
    Ok(segment) -> segment
    Error(Nil) -> ""
  }
}

fn last_segment_span(path: ast.ModulePath) -> location.Span {
  let length = string.length(last_segment(path))
  let end = path.span.end
  let start =
    location.Position(
      line: end.line,
      column: end.column - length,
      byte_offset: end.byte_offset - length,
    )
  location.Span(start:, end:)
}

fn module_path(parser: Parser) -> Parsed(ast.ModulePath) {
  let start = state.current(parser)
  use #(segments, parser) <- result.try(path_segments(parser, []))
  let span = state.span_from(parser, start.span.start)
  Ok(#(ast.ModulePath(segments:, span:), parser))
}

fn path_segments(
  parser: Parser,
  segments: List(String),
) -> Parsed(List(String)) {
  case state.current(parser) {
    Lexeme(token: token.Name(segment), ..) -> {
      let parser = state.skip(parser)
      let segments = [segment, ..segments]
      case state.is(parser, token.Slash) {
        True -> path_segments(state.skip(parser), segments)
        False -> Ok(#(list.reverse(segments), parser))
      }
    }
    found -> Error(state.name_error(found, parse_error.ExpectModulePath))
  }
}

fn parse_import(parser: Parser, keyword: Lexeme) -> Parsed(ast.Import) {
  use #(module, parser) <- result.try(module_path(parser))
  use #(items, parser) <- result.try(case state.is(parser, token.Dot) {
    False -> Ok(#([], parser))
    True -> {
      use #(open, parser) <- result.try(state.expect(
        state.skip(parser),
        token.LeftBrace,
      ))
      state.delimited(
        parser,
        open,
        token.RightBrace,
        parse_error.ImportList,
        imported_name,
      )
    }
  })
  use #(alias, parser) <- result.try(case state.is(parser, token.As) {
    False -> Ok(#(None, parser))
    True -> {
      use #(#(name, span), parser) <- result.try(state.expect_name(
        state.skip(parser),
        "a module alias",
      ))
      Ok(#(Some(ast.Name(name:, span:)), parser))
    }
  })
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(ast.Import(module:, items:, alias:, span:), parser))
}

fn imported_name(parser: Parser) -> Parsed(ast.ImportedName) {
  let start = state.current(parser)
  use #(#(name, alias_what), parser) <- result.try(case start.token {
    token.Name(name) -> Ok(#(#(name, LowerAlias), state.skip(parser)))
    token.UpperName(name) -> Ok(#(#(name, UpperAlias), state.skip(parser)))
    _ -> Error(state.name_error(start, parse_error.ExpectImportedName))
  })
  use #(alias, parser) <- result.try(case state.is(parser, token.As) {
    False -> Ok(#(None, parser))
    True -> {
      let parser = state.skip(parser)
      use #(#(alias, span), parser) <- result.try(case alias_what {
        LowerAlias -> state.expect_name(parser, "a new name")
        UpperAlias -> state.expect_upper_name(parser, "a new name")
      })
      Ok(#(Some(ast.Name(name: alias, span:)), parser))
    }
  })
  let span = state.span_from(parser, start.span.start)
  Ok(#(
    ast.ImportedName(name: ast.Name(name:, span: start.span), alias:, span:),
    parser,
  ))
}

type AliasKind {
  LowerAlias
  UpperAlias
}

fn declaration(
  parser: Parser,
  documentation: List(String),
) -> Parsed(ast.Declaration) {
  let start = state.current(parser)
  let next = state.peek(parser)
  case start.token, next {
    token.Class, _ -> {
      use #(class, parser) <- result.try(parse_declaration.parse_class(
        state.skip(parser),
        start,
        documentation,
      ))
      Ok(#(ast.ClassDeclaration(class), parser))
    }
    token.Interface, _ -> {
      use #(interface, parser) <- result.try(parse_declaration.parse_interface(
        state.skip(parser),
        start,
        documentation,
      ))
      Ok(#(ast.InterfaceDeclaration(interface), parser))
    }
    token.Actor, _ -> {
      use #(actor, parser) <- result.try(parse_declaration.parse_actor(
        state.skip(parser),
        start,
        documentation,
      ))
      Ok(#(ast.ActorDeclaration(actor), parser))
    }
    token.External, _ -> {
      use #(external, parser) <- result.try(parse_declaration.parse_external(
        state.skip(parser),
        start,
        documentation,
      ))
      Ok(#(ast.ExternalDeclaration(external), parser))
    }
    token.Name("enum"), token.UpperName(_) -> {
      use #(enum, parser) <- result.try(parse_declaration.parse_enum(
        state.skip(parser),
        start,
        documentation,
      ))
      Ok(#(ast.EnumDeclaration(enum), parser))
    }
    token.Name("native"), token.UpperName(_) -> {
      use #(native, parser) <- result.try(parse_declaration.parse_native(
        state.skip(parser),
        start,
        documentation,
      ))
      Ok(#(ast.ExternalDeclaration(native), parser))
    }
    token.Test, _ -> {
      use #(test_, parser) <- result.try(parse_declaration.parse_test(
        state.skip(parser),
        start,
        documentation,
      ))
      Ok(#(ast.TestDeclaration(test_), parser))
    }
    token.Name(_), token.LeftParen -> {
      use #(function, parser) <- result.try(parse_declaration.parse_function(
        parser,
        documentation,
      ))
      Ok(#(ast.FunctionDeclaration(function), parser))
    }

    token.Fn, token.Name(_) ->
      declaration(
        state.report(
          state.skip(parser),
          parse_error.NamedFunctionWithFn(
            state.current(parser).span,
            modifier_span(parser),
          ),
        ),
        documentation,
      )
    token.Be, token.Name(_) ->
      declaration(
        state.report(
          state.skip(parser),
          parse_error.BehaviourOutsideActor(start.span),
        ),
        documentation,
      )
    token.Name(word), _ ->
      case
        list.contains(parse_declaration.visibility_words, word)
        && starts_declaration(next)
      {
        True ->
          declaration(
            state.report(
              state.skip(parser),
              parse_error.VisibilityModifier(
                state.current(parser).span,
                modifier_span(parser),
                word,
              ),
            ),
            documentation,
          )
        False -> top_level_expression(parser, start)
      }
    token.Let, _ -> Error(parse_error.TopLevelBinding(start.span))
    token.Var, _ -> Error(parse_error.TopLevelMutableState(start.span))

    _, _ -> top_level_expression(parser, start)
  }
}

fn starts_declaration(next: token.Token) -> Bool {
  case next {
    token.Class
    | token.Interface
    | token.Actor
    | token.External
    | token.Fn
    | token.Name(_) -> True
    _ -> False
  }
}

fn top_level_expression(
  parser: Parser,
  start: Lexeme,
) -> Parsed(ast.Declaration) {
  case parse_expression.parse_expression_or_assignment(parser) {
    Ok(#(expression, _)) ->
      Error(parse_error.TopLevelExpression(ast.expression_span(expression)))
    Error(_) ->
      Error(parse_error.UnexpectedToken(start, parse_error.ExpectDeclaration))
  }
}

fn modifier_span(parser: Parser) -> location.Span {
  let current = state.current(parser)
  let next = state.peek_lexeme(parser)
  case next.span.start.line == current.span.end.line {
    True -> location.between(current.span.start, next.span.start)
    False -> current.span
  }
}
