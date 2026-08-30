//// Tidy the page without changing its meaning.
////
//// Parse, lay out and reparse the source, checking token preservation before
//// accepting the result. Repeated formatting must reach a stable layout rather
//// than slowly moving the furniture.
////
//// ```text
//// format(format(source)) == format(source)
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/lex_error.{type LexError}
import compiler/lexer/lexer
import compiler/lexer/token.{type Lexeme, type Token}
import compiler/parser/parse_error.{type ParseError}
import compiler/parser/parser
import gleam/int
import gleam/list
import gleam/string
import tools/formatter_layout

pub type FormatError {

  LexErrors(errors: List(LexError))

  SyntaxErrors(errors: List(ParseError))

  ChangedMeaning
}

/// Format only when token preservation and reparsing confirm that the candidate
/// means the same thing. The internal layout passes seek a fixed point.
///
/// ```text
/// format(format(source)) == format(source)
/// ```
pub fn format(source: String) -> Result(String, FormatError) {
  let lexed = lexer.lex(source)
  case lexed.errors {
    [_, ..] -> Error(LexErrors(lexed.errors))
    [] -> {
      case parser.parse(lexed.tokens).errors {
        [_, ..] as errors -> Error(SyntaxErrors(errors))
        [] -> {
          let formatted = structural_lines(source, 0)
          case same_tokens(lexed.tokens, lexer.lex(formatted).tokens) {
            True ->
              case parser.parse(lexer.lex(formatted).tokens).errors {
                [] -> Ok(formatted)
                _ -> Error(ChangedMeaning)
              }
            False -> Error(ChangedMeaning)
          }
        }
      }
    }
  }
}

fn structural_lines(source: String, count: Int) -> String {
  let tokens = lexer.lex(source).tokens
  let module = parser.parse(tokens).module
  let formatted =
    formatter_layout.structure(module, tokens, render)
    |> layout
    |> wrap_lines(0)
  case formatted == source || count >= 32 {
    True -> formatted
    False -> structural_lines(formatted, count + 1)
  }
}

fn wrap_lines(source: String, count: Int) -> String {
  let formatted =
    lexer.lex(source).tokens
    |> formatter_layout.wrap(80, render)
    |> layout
  case formatted == source || count >= 32 {
    True -> formatted
    False -> wrap_lines(formatted, count + 1)
  }
}

fn same_tokens(first: List(Lexeme), second: List(Lexeme)) -> Bool {
  list.map(first, fn(lexeme) { lexeme.token })
  == list.map(second, fn(lexeme) { lexeme.token })
}

type Line {
  Line(number: Int, tokens: List(Lexeme))
}

fn lines(tokens: List(Lexeme)) -> List(Line) {
  tokens
  |> list.filter(fn(lexeme) { lexeme.token != token.EndOfFile })
  |> list.chunk(fn(lexeme) { lexeme.span.start.line })
  |> list.filter_map(fn(group) {
    case group {
      [first, ..] -> Ok(Line(first.span.start.line, group))
      [] -> Error(Nil)
    }
  })
}

type Indent =
  List(Int)

fn layout(tokens: List(Lexeme)) -> String {
  let #(output, _, _) =
    list.fold(lines(tokens), #([], [], 0), fn(acc, line) {
      let #(output, indent, previous) = acc
      let #(indent, rest) = leading_closers(indent, line.tokens)
      let level = list.length(indent) + continuation(line.tokens)
      let text =
        string.repeat("  ", level)
        <> render(list.map(line.tokens, fn(l) { l.token }))

      let blank =
        follows_module(output)
        || previous > 0
        && line.number - previous > 1
        && !opens_block(output)
        && !starts_with_closer(line.tokens)
      let output = case blank {
        True -> [text, "", ..output]
        False -> [text, ..output]
      }
      #(output, track(indent, rest), line.number)
    })
  case output {
    [] -> "\n"
    _ -> string.join(list.reverse(output), "\n") <> "\n"
  }
}

fn leading_closers(
  indent: Indent,
  tokens: List(Lexeme),
) -> #(Indent, List(Lexeme)) {
  case tokens {
    [first, ..rest] ->
      case closes(first.token) {
        True -> leading_closers(close(indent), rest)
        False -> #(indent, tokens)
      }
    [] -> #(indent, [])
  }
}

fn track(indent: Indent, tokens: List(Lexeme)) -> Indent {
  let #(indent, pending) =
    list.fold(tokens, #(indent, 0), fn(acc, lexeme) {
      let #(indent, pending) = acc
      case opens(lexeme.token), closes(lexeme.token), pending > 0 {
        True, _, _ -> #(indent, pending + 1)
        False, True, True -> #(indent, pending - 1)
        False, True, False -> #(close(indent), 0)
        False, False, _ -> acc
      }
    })
  case pending > 0 {
    True -> [pending, ..indent]
    False -> indent
  }
}

fn close(indent: Indent) -> Indent {
  case indent {
    [] -> []
    [1, ..rest] -> rest
    [count, ..rest] -> [count - 1, ..rest]
  }
}

fn opens(found: Token) -> Bool {
  case found {
    token.LeftBrace
    | token.LeftParen
    | token.LeftSquare
    | token.HashLeftParen
    | token.DoubleLess -> True
    _ -> False
  }
}

fn closes(found: Token) -> Bool {
  case found {
    token.RightBrace
    | token.RightParen
    | token.RightSquare
    | token.DoubleGreater -> True
    _ -> False
  }
}

fn continuation(tokens: List(Lexeme)) -> Int {
  case tokens {
    [first, ..] ->
      case first.token {
        token.As
        | token.Dot
        | token.Plus
        | token.Star
        | token.Slash
        | token.Percent
        | token.DoubleAmpersand
        | token.DoubleBar
        | token.Ampersand
        | token.Bar
        | token.EqualEqual
        | token.BangEqual
        | token.Less
        | token.LessEqual
        | token.Greater
        | token.GreaterEqual -> 1
        _ -> 0
      }
    [] -> 0
  }
}

fn follows_module(output: List(String)) -> Bool {
  case output {
    [last, ..] -> string.starts_with(last, "module ")
    [] -> False
  }
}

fn opens_block(output: List(String)) -> Bool {
  case output {
    [last, ..] -> string.ends_with(last, "{")
    [] -> False
  }
}

fn starts_with_closer(tokens: List(Lexeme)) -> Bool {
  case tokens {
    [first, ..] -> first.token == token.RightBrace
    [] -> False
  }
}

type Context {
  Context(bits: Int, options: Bool, import_list: Bool, path: Bool)
}

fn render(tokens: List(Token)) -> String {
  let path = case tokens {
    [token.Import, ..] | [token.Module, ..] -> True
    _ -> False
  }
  let #(parts, _, _) =
    list.fold(
      tokens,
      #([], token.EndOfFile, Context(0, False, False, path)),
      fn(acc, next) {
        let #(parts, previous, context) = acc
        let separator = case parts {
          [] -> ""
          [_, ..] ->
            case space(previous, next, context, parts) {
              True -> " "
              False -> ""
            }
        }
        #(
          [token.to_source(next), separator, ..parts],
          next,
          update(context, previous, next),
        )
      },
    )
  parts |> list.reverse |> string.concat
}

fn update(context: Context, previous: Token, next: Token) -> Context {
  case next {
    token.DoubleLess ->
      Context(..context, bits: context.bits + 1, options: False)
    token.DoubleGreater ->
      Context(..context, bits: int.max(0, context.bits - 1), options: False)
    token.Colon if context.bits > 0 -> Context(..context, options: True)
    token.Comma if context.bits > 0 -> Context(..context, options: False)
    token.LeftBrace if previous == token.Dot ->
      Context(..context, import_list: True)
    token.RightBrace -> Context(..context, import_list: False)
    _ -> context
  }
}

fn space(
  previous: Token,
  next: Token,
  context: Context,
  parts: List(String),
) -> Bool {
  case previous, next {
    _, token.Comment(_) | _, token.DocComment(_) -> True

    _, token.Slash | token.Slash, _ if context.path -> False

    _, token.Colon | token.Colon, _ if context.bits > 0 -> False
    _, token.Minus | token.Minus, _ if context.bits > 0 && context.options ->
      False

    token.LeftParen, _
    | token.LeftSquare, _
    | token.HashLeftParen, _
    | token.DoubleLess, _
    | token.Dot, _
    | token.DotDot, _
    | token.Bang, _
    -> False
    _, token.RightParen
    | _, token.RightSquare
    | _, token.DoubleGreater
    | _, token.Comma
    | _, token.Dot
    | _, token.Question
    | _, token.Colon
    -> False

    token.LeftBrace, _ | _, token.RightBrace if context.import_list -> False

    token.LeftBrace, token.RightBrace -> False

    token.Name(_), token.LeftParen
    | token.UpperName(_), token.LeftParen
    | token.RightParen, token.LeftParen
    | token.RightSquare, token.LeftParen
    | token.Question, token.LeftParen
    | token.Fn, token.LeftParen
    | token.New, token.LeftParen
    | token.NilLiteral, token.LeftParen
    -> False

    token.Minus, _ -> !unary(parts)
    _, _ -> True
  }
}

fn unary(parts: List(String)) -> Bool {
  case parts {
    [_minus, _separator, before, ..] ->
      list.contains(
        [
          "(", "[", "#(", "<<", ",", "=", "->", "+", "-", "*", "/", "%", "==",
          "!=", "<", "<=", ">", ">=", "&&", "||", "|>", ":", "return", "{", "!",
          "as", "break", "assert", "in", "if",
        ],
        before,
      )
      || is_keyword_text(before)

    [_minus, _separator] | [_minus] -> True
    _ -> False
  }
}

fn is_keyword_text(text: String) -> Bool {
  case token.keyword(text) {
    Ok(found) ->
      found != token.TrueLiteral
      && found != token.FalseLiteral
      && found != token.NilLiteral
      && found != token.SelfKeyword
    Error(Nil) -> False
  }
}
