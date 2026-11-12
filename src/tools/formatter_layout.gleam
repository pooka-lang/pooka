//// Decide where the syntax may comfortably take a breath.
////
//// Build structural line-break rules and wrap groups while preserving every
//// token. Nested callback blocks must keep their statement boundaries when an
//// outer call is expanded.
////
//// ```text
//// call(inner(fn() { statements }), callback) -> separate outer arguments
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token.{type Lexeme, type Token, Lexeme}
import compiler/parser/ast
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import utilities/location.{type Span}

type Rules {
  Rules(
    tokens: List(Lexeme),
    kinds: Dict(Int, Token),
    before: Dict(Int, Int),
    after: Dict(Int, Int),
    flat: Dict(Int, Nil),
    render: fn(List(Token)) -> String,
  )
}

fn rules(tokens: List(Lexeme), render: fn(List(Token)) -> String) -> Rules {
  Rules(
    tokens,
    dict.from_list(
      list.map(tokens, fn(t) { #(t.span.start.byte_offset, t.token) }),
    ),
    dict.new(),
    dict.new(),
    dict.new(),
    render,
  )
}

fn before(rules: Rules, offset: Int, count: Int) -> Rules {
  Rules(
    ..rules,
    before: dict.insert(
      rules.before,
      offset,
      int.max(count, result.unwrap(dict.get(rules.before, offset), 0)),
    ),
  )
}

fn after(rules: Rules, offset: Int) -> Rules {
  Rules(..rules, after: dict.insert(rules.after, offset, 1))
}

fn comment(token: Token) -> Bool {
  case token {
    token.Comment(_) | token.DocComment(_) | token.ModuleComment(_) -> True
    _ -> False
  }
}

fn attached(tokens: List(Lexeme), offset: Int) -> Int {
  let previous =
    tokens
    |> list.take_while(fn(t) { t.span.start.byte_offset < offset })
    |> list.reverse
  attach(previous, offset)
}

fn attach(previous: List(Lexeme), offset: Int) -> Int {
  case previous {
    [current, earlier, ..] if current.span.start.line == earlier.span.end.line ->
      offset
    [current, ..rest] ->
      case comment(current.token) {
        True -> attach(rest, current.span.start.byte_offset)
        False -> offset
      }
    [] -> offset
  }
}

fn definition(rules: Rules, span: Span, gap: Int) -> Rules {
  before(rules, attached(rules.tokens, span.start.byte_offset), gap)
}

fn enclosure(rules: Rules, span: Span, starts: List(Int)) -> Rules {
  case starts {
    [] -> rules
    [_, ..] -> {
      let rules = before(rules, span.end.byte_offset - 1, 1)
      list.fold(starts, rules, fn(rules, offset) {
        before(rules, attached(rules.tokens, offset), 1)
      })
    }
  }
}

/// Choose declaration, body and pattern line breaks using syntax spans,
/// preserving all original tokens.
///
/// ```text
/// two top-level declarations -> one separating blank line
/// ```
pub fn structure(
  module: ast.Module,
  tokens: List(Lexeme),
  render: fn(List(Token)) -> String,
) -> List(Lexeme) {
  let rules =
    list.fold(module.imports, rules(tokens, render), fn(rules, item) {
      definition(rules, item.span, case module.imports {
        [first, ..] if first.span == item.span -> 2
        _ -> 1
      })
    })
  let rules = list.fold(module.declarations, rules, declaration)
  apply(rules)
}

fn declaration(rules: Rules, declaration: ast.Declaration) -> Rules {
  case declaration {
    ast.FunctionDeclaration(function) ->
      block(definition(rules, function.span, 2), function.body, True)
    ast.TestDeclaration(source) ->
      block(definition(rules, source.span, 2), source.body, True)
    ast.ClassDeclaration(class) ->
      members(definition(rules, class.span, 2), class.span, class.members)
    ast.ActorDeclaration(actor) ->
      members(definition(rules, actor.span, 2), actor.span, actor.members)
    ast.InterfaceDeclaration(interface) -> {
      let rules =
        enclosure(
          definition(rules, interface.span, 2),
          interface.span,
          list.map(interface.requirements, fn(r) { r.span.start.byte_offset }),
        )
      list.fold(interface.requirements, rules, fn(rules, requirement) {
        definition(rules, requirement.span, 2)
      })
    }
    ast.ExternalDeclaration(external) -> {
      let rules =
        enclosure(
          definition(rules, external.span, 2),
          external.span,
          list.map(external.functions, fn(f) { f.span.start.byte_offset }),
        )
      list.fold(external.functions, rules, fn(rules, function) {
        definition(rules, function.span, 2)
      })
    }
    ast.EnumDeclaration(enum) ->
      enclosure(
        definition(rules, enum.span, 2),
        enum.span,
        list.map(enum.variants, fn(v) { v.name.span.start.byte_offset }),
      )
  }
}

fn members(rules: Rules, span: Span, members: List(ast.Member)) -> Rules {
  let members =
    list.filter(members, fn(member) {
      let span = member_span(member)
      case dict.get(rules.kinds, span.start.byte_offset), member {
        Ok(token.Let), ast.FieldMember(_) | Ok(token.Var), ast.FieldMember(_) ->
          True
        Ok(token.New), ast.ConstructorMember(_) -> True
        _, ast.MethodMember(_) | _, ast.BehaviourMember(_) -> True
        _, _ -> False
      }
    })
  let rules =
    enclosure(
      rules,
      span,
      list.map(members, fn(m) { member_span(m).start.byte_offset }),
    )
  list.fold(members, rules, fn(rules, member) {
    case member {
      ast.FieldMember(field) -> {
        let rules = definition(rules, field.span, 1)
        case field.value {
          Some(value) -> expression(rules, value)
          None -> rules
        }
      }
      ast.ConstructorMember(constructor) ->
        block(definition(rules, constructor.span, 2), constructor.body, True)
      ast.MethodMember(method) | ast.BehaviourMember(method) ->
        block(definition(rules, method.span, 2), method.body, True)
    }
  })
}

fn member_span(member: ast.Member) -> Span {
  case member {
    ast.FieldMember(field) -> field.span
    ast.ConstructorMember(constructor) -> constructor.span
    ast.MethodMember(method) | ast.BehaviourMember(method) -> method.span
  }
}

fn block(rules: Rules, body: ast.Block, expand: Bool) -> Rules {
  let rules = case expand {
    True ->
      enclosure(
        rules,
        body.span,
        list.map(body.statements, fn(s) {
          ast.statement_span(s).start.byte_offset
        }),
      )
    False -> rules
  }
  list.fold(body.statements, rules, fn(rules, statement) {
    case statement {
      ast.LetStatement(pattern:, value:, ..) ->
        expression(pattern_rules(rules, pattern), value)
      ast.LetAssertStatement(pattern:, value:, message:, ..) ->
        optional(expression(pattern_rules(rules, pattern), value), message)
      ast.ExpressionStatement(value) -> expression(rules, value)
    }
  })
}

fn tokens_in(rules: Rules, span: Span) -> List(Lexeme) {
  list.filter(rules.tokens, fn(t) {
    t.span.start.byte_offset >= span.start.byte_offset
    && t.span.end.byte_offset <= span.end.byte_offset
  })
}

fn flatten(rules: Rules, tokens: List(Lexeme)) -> Rules {
  Rules(
    ..rules,
    flat: list.fold(tokens, rules.flat, fn(flat, t) {
      dict.insert(flat, t.span.start.byte_offset, Nil)
    }),
  )
}

fn fits(rules: Rules, tokens: List(Lexeme), column: Int) -> Bool {
  !list.any(tokens, fn(t) { comment(t.token) })
  && column
  - 1
  + string.length(rules.render(list.map(tokens, fn(t) { t.token })))
  <= 80
}

fn pattern_rules(rules: Rules, pattern: ast.Pattern) -> Rules {
  let span = ast.pattern_span(pattern)
  let tokens = tokens_in(rules, span)
  let rules = case fits(rules, tokens, span.start.column) {
    True -> flatten(rules, list.drop(tokens, 1))
    False -> rules
  }
  list.fold(ast.pattern_expressions(pattern), rules, expression)
}

fn pending_line_break(rules: Rules, span: Span) -> Bool {
  let #(found, _) =
    list.fold(rules.tokens, #(False, 0), fn(acc, t) {
      let #(found, previous) = acc
      #(
        found
          || t.span.start.line == span.start.line
          && t.span.start.byte_offset <= span.start.byte_offset
          && t.span.start.line == previous
          && result.unwrap(dict.get(rules.before, t.span.start.byte_offset), 0)
          > 0,
        t.span.end.line,
      )
    })
  found
}

fn callback_layout(
  rules: Rules,
  callee: ast.Expression,
  arguments: List(ast.Expression),
  span: Span,
) -> Rules {
  case list.last(arguments) {
    Ok(ast.AnonymousFunction(body:, ..)) -> {
      let header =
        tokens_in(
          rules,
          location.Span(
            ast.expression_span(callee).start,
            location.Position(
              ..body.span.start,
              byte_offset: body.span.start.byte_offset + 1,
            ),
          ),
        )
      let suffix =
        list.filter(rules.tokens, fn(t) {
          t.span.start.byte_offset >= body.span.end.byte_offset
          && t.span.end.byte_offset <= span.end.byte_offset
        })
      let comment_or_comma =
        list.any(suffix, fn(t) { comment(t.token) || t.token == token.Comma })
      let full = tokens_in(rules, span)
      let expand =
        span.start.line != span.end.line
        || !fits(rules, full, span.start.column)
      let defer =
        span.start.line == span.end.line && pending_line_break(rules, span)
      case
        fits(rules, header, span.start.column)
        && list.length(
          list.filter(header, fn(t) { t.token == token.LeftBrace }),
        )
        == 1
        && !comment_or_comma
        && expand
        && !defer
      {
        False -> rules
        True -> {
          let rules = flatten(rules, list.drop(header, 1)) |> flatten(suffix)
          block(rules, body, True)
        }
      }
    }
    _ -> rules
  }
}

fn optional(rules: Rules, value: option.Option(ast.Expression)) -> Rules {
  case value {
    Some(value) -> expression(rules, value)
    None -> rules
  }
}

fn complex(value: ast.Expression) -> Bool {
  case value {
    ast.Match(..) | ast.Loop(..) | ast.BlockExpression(_) -> True
    ast.Call(callee, arguments, _) ->
      complex(callee) || list.any(arguments, complex)
    ast.ListExpression(elements, _) | ast.TupleExpression(elements, _) ->
      list.any(elements, complex)
    ast.Unary(_, subject, _)
    | ast.Propagate(subject, _)
    | ast.FieldAccess(subject, _, _)
    | ast.TupleAccess(subject, _, _, _) -> complex(subject)
    ast.Binary(_, left, right, _) -> complex(left) || complex(right)
    _ -> False
  }
}

fn expression(rules: Rules, value: ast.Expression) -> Rules {
  case value {
    ast.Match(subject, branches, span) -> {
      let rules =
        enclosure(
          rules,
          span,
          list.map(branches, fn(b) { b.span.start.byte_offset }),
        )
      list.fold(branches, expression(rules, subject), fn(rules, branch) {
        let rules =
          pattern_rules(rules, branch.pattern) |> optional(branch.guard)
        expression(rules, branch.body)
      })
    }
    ast.BlockExpression(body) -> block(rules, body, True)
    ast.Loop(iteration, body, _) -> {
      let rules = case iteration {
        Some(iteration) ->
          expression(
            pattern_rules(rules, iteration.pattern),
            iteration.iterable,
          )
        None -> rules
      }
      block(rules, body, True)
    }
    ast.AnonymousFunction(body:, ..) -> {
      let expand =
        body.span.start.line != body.span.end.line
        || list.length(body.statements) > 1
        || list.any(body.statements, fn(s) {
          case s {
            ast.ExpressionStatement(value)
            | ast.LetStatement(value:, ..)
            | ast.LetAssertStatement(value:, ..) -> complex(value)
          }
        })
      block(rules, body, expand)
    }
    ast.ListExpression(elements, _) | ast.TupleExpression(elements, _) ->
      list.fold(elements, rules, expression)
    ast.Call(callee, arguments, span) ->
      list.fold(
        arguments,
        expression(callback_layout(rules, callee, arguments, span), callee),
        expression,
      )
    ast.FieldAccess(subject, _, _)
    | ast.TupleAccess(subject, _, _, _)
    | ast.Propagate(subject, _)
    | ast.Unary(_, subject, _) -> expression(rules, subject)
    ast.Assert(subject, message, _) ->
      optional(expression(rules, subject), message)
    ast.Binary(_, left, right, _) -> expression(expression(rules, left), right)
    ast.Assignment(target, _, value, _) -> {
      let rules = case target {
        ast.AssignVariable(_) -> rules
        ast.AssignField(subject, _, _) -> expression(rules, subject)
      }
      expression(rules, value)
    }
    ast.Break(value, _) | ast.Panic(value, _) | ast.Todo(value, _) ->
      optional(rules, value)
    ast.BitArrayExpression(segments, _) ->
      list.fold(segments, rules, fn(rules, segment) {
        list.fold(
          segment.options,
          expression(rules, segment.value),
          fn(rules, option) {
            case option {
              ast.SizeOption(value, _) | ast.UnitOption(value, _) ->
                expression(rules, value)
              _ -> rules
            }
          },
        )
      })
    _ -> rules
  }
}

fn apply(rules: Rules) -> List(Lexeme) {
  let #(output, _, _, _) =
    list.fold(rules.tokens, #([], 1, 1, 0), fn(acc, item) {
      let #(output, line, previous, pending) = acc
      let requested =
        result.unwrap(dict.get(rules.before, item.span.start.byte_offset), 0)
      let original = int.clamp(item.span.start.line - previous, 0, 2)
      let compact = dict.has_key(rules.flat, item.span.start.byte_offset)
      let gap = case output, compact {
        [], _ | _, True -> 0
        _, False -> int.max(requested, int.max(original, pending))
      }
      let trailing_comment =
        comment(item.token) && original == 0 && requested == 0
      let next_line =
        line
        + case trailing_comment {
          True -> 0
          False -> gap
        }
      let new =
        Lexeme(
          ..item,
          span: location.Span(
            location.Position(..item.span.start, line: next_line),
            location.Position(..item.span.end, line: next_line),
          ),
        )
      let next_pending =
        result.unwrap(dict.get(rules.after, item.span.start.byte_offset), 0)
      #([new, ..output], next_line, item.span.end.line, case trailing_comment {
        True -> int.max(pending, next_pending)
        False -> next_pending
      })
    })
  list.reverse(output)
}

/// Wrap token groups at the preferred width without flattening statement
/// boundaries inside nested callback bodies.
///
/// ```text
/// nested multi-statement callback -> retain its line breaks when wrapping the outer call
/// ```
pub fn wrap(
  tokens: List(Lexeme),
  width: Int,
  render: fn(List(Token)) -> String,
) -> List(Lexeme) {
  apply(groups(tokens, rules(tokens, render), width, render))
}

fn groups(
  tokens: List(Lexeme),
  rules: Rules,
  width: Int,
  render: fn(List(Token)) -> String,
) -> Rules {
  case tokens {
    [] -> rules
    [open, ..rest] -> {
      let eligible =
        open.token == token.LeftParen
        || open.token == token.LeftSquare
        || open.token == token.HashLeftParen
      case eligible {
        False -> groups(rest, rules, width, render)
        True -> {
          let #(inner, remaining) = group(rest, 0, [])
          case remaining, inner {
            [close, ..tail], [_, ..] -> {
              let line_tokens =
                rules.tokens
                |> list.filter(fn(t) {
                  t.span.start.line == open.span.start.line
                  && t.token != token.EndOfFile
                  && t.span.start.byte_offset <= close.span.start.byte_offset
                })
                |> list.map(fn(t) { t.token })
              let indentation = case
                list.find(rules.tokens, fn(t) {
                  t.span.start.line == open.span.start.line
                })
              {
                Ok(first) -> first.span.start.column - 1
                Error(_) -> 0
              }
              case
                indentation + string.length(render(line_tokens)) > width
                || broken_arguments(inner, open.span.start.line),
                already_wrapped(open, inner, close)
              {
                False, _ | True, True -> groups(rest, rules, width, render)
                True, False -> {
                  let rules =
                    after(rules, open.span.start.byte_offset)
                    |> before(close.span.start.byte_offset, 1)
                  let #(rules, _) =
                    list.fold(inner, #(rules, 0), fn(acc, item) {
                      let #(rules, depth) = acc
                      case item.token {
                        token.Comma if depth == 0 -> #(
                          after(rules, item.span.start.byte_offset),
                          depth,
                        )
                        _ -> #(rules, depth + nesting(item.token))
                      }
                    })
                  let tail =
                    list.drop_while(tail, fn(t) {
                      t.span.start.line == close.span.end.line
                    })
                  groups(tail, rules, width, render)
                }
              }
            }
            _, _ -> groups(rest, rules, width, render)
          }
        }
      }
    }
  }
}

fn already_wrapped(open: Lexeme, inner: List(Lexeme), close: Lexeme) -> Bool {
  let visible = list.filter(inner, fn(t) { !comment(t.token) })
  case visible, list.last(visible) {
    [first, ..], Ok(last) ->
      first.span.start.line > open.span.end.line
      && close.span.start.line > last.span.end.line
      && comma_breaks(inner, 0)
    _, _ -> False
  }
}

fn comma_breaks(tokens: List(Lexeme), depth: Int) -> Bool {
  case tokens {
    [] -> True
    [current, ..rest] ->
      case current.token, depth {
        token.Comma, 0 -> {
          let next = list.find(rest, fn(t) { !comment(t.token) })
          case next {
            Ok(next) if next.span.start.line == current.span.end.line -> False
            _ -> comma_breaks(rest, depth)
          }
        }
        _, _ -> comma_breaks(rest, depth + nesting(current.token))
      }
  }
}

fn broken_arguments(tokens: List(Lexeme), line: Int) -> Bool {
  let #(broken, _) =
    list.fold(tokens, #(False, 0), fn(acc, item) {
      let #(broken, depth) = acc
      #(
        broken
          || depth == 0
          && { item.span.start.line > line || comment(item.token) },
        depth + nesting(item.token),
      )
    })
  broken
}

fn group(
  tokens: List(Lexeme),
  depth: Int,
  found: List(Lexeme),
) -> #(List(Lexeme), List(Lexeme)) {
  case tokens {
    [] -> #(list.reverse(found), [])
    [item, ..rest] ->
      case nesting(item.token), depth {
        -1, 0 -> #(list.reverse(found), tokens)
        amount, _ -> group(rest, depth + amount, [item, ..found])
      }
  }
}

fn nesting(token: Token) -> Int {
  case token {
    token.LeftParen
    | token.HashLeftParen
    | token.LeftSquare
    | token.LeftBrace
    | token.DoubleLess -> 1
    token.RightParen
    | token.RightSquare
    | token.RightBrace
    | token.DoubleGreater -> -1
    _ -> 0
  }
}
