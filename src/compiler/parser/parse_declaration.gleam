//// Give each top-level declaration its proper room.
////
//// Parse functions, classes, actors, interfaces and foreign namespaces. Keep
//// member syntax and declaration recovery here while expression and type grammars
//// remain separate.
////
//// ```text
//// class Box(value: Int) -> ClassDeclaration
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/foreign_language
import compiler/lexer/token.{type Lexeme, Lexeme}
import compiler/parser/ast.{type Member, type TypeAnnotation}
import compiler/parser/parse_error
import compiler/parser/parse_expression
import compiler/parser/parse_parameter
import compiler/parser/parse_type
import compiler/parser/state.{type Parsed, type Parser}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import project/native_component
import utilities/location.{type Span, Span}

pub type BodyKind {
  ClassBody
  ActorBody
}

pub const visibility_words = ["pub", "public", "private", "protected"]

pub fn parse_function(
  parser: Parser,
  documentation: List(String),
) -> Parsed(ast.Function) {
  let start = state.current(parser)
  use #(#(name, name_span), parser) <- result.try(state.expect_name(
    parser,
    "a function name",
  ))
  use #(parameters, parser) <- result.try(parse_parameter.parse_parameters(
    parser,
  ))
  use #(return_type, parser) <- result.try(
    parse_parameter.parse_return_annotation(parser),
  )
  use #(body, parser) <- result.try(parse_expression.parse_block(parser))
  let span = state.span_from(parser, start.span.start)
  let name = ast.Name(name:, span: name_span)
  Ok(#(
    ast.Function(documentation:, name:, parameters:, return_type:, body:, span:),
    parser,
  ))
}

pub fn parse_class(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(ast.Class) {
  use #(name, parser) <- result.try(upper_name(parser, "a class name"))

  use #(concise, parser) <- result.try(
    case state.current(parser), state.peek(parser), state.peek_second(parser) {
      Lexeme(token: token.LeftParen, ..) as open, token.Name(_), token.Colon -> {
        use #(fields, parser) <- result.try(concise_fields(
          state.skip(parser),
          open,
        ))
        Ok(#(Some(fields), parser))
      }
      _, _, _ -> Ok(#(None, parser))
    },
  )
  use #(type_parameters, parser) <- result.try(case concise {
    Some(fields) -> Ok(#(concise_type_parameters(fields), parser))
    None -> type_parameters(parser)
  })
  use #(superclass, parser) <- result.try(superclass(parser, name))
  use #(interfaces, parser) <- result.try(interfaces(parser))

  use #(superclass, parser) <- result.try(case state.current(parser) {
    Lexeme(token: token.Is, span:) -> {
      let parser =
        state.report(parser, parse_error.SuperclassAfterInterfaces(span))
      use #(late, parser) <- result.try(
        parse_type.parse_type(state.skip(parser)),
      )
      Ok(#(option.or(superclass, Some(late)), parser))
    }
    _ -> Ok(#(superclass, parser))
  })
  use #(members, parser) <- result.try(case concise, state.current(parser) {
    Some(_), Lexeme(token: token.LeftBrace, ..) as open ->
      members(state.skip(parser), open, ClassBody, [])
    Some(_), _ -> Ok(#([], parser))
    None, _ -> {
      use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
      members(parser, open, ClassBody, [])
    }
  })
  let #(members, parser) = case concise {
    Some(fields) -> {
      let parser =
        list.fold(members, parser, fn(parser, member) {
          case member {
            ast.ConstructorMember(constructor) ->
              state.report(
                parser,
                parse_error.ConciseConstructor(constructor.span, name.name),
              )
            _ -> parser
          }
        })
      #(list.append(concise_members(fields), members), parser)
    }
    None -> #(members, parser)
  }
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(
    ast.Class(
      documentation:,
      name:,
      type_parameters:,
      superclass:,
      interfaces:,
      members:,
      span:,
    ),
    parser,
  ))
}

pub fn parse_enum(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(ast.Enum) {
  use #(name, parser) <- result.try(upper_name(parser, "an enum name"))

  use #(_, parser) <- result.try(type_parameters(parser))
  let parser = case state.previous_end(parser) == name.span.end {
    True -> parser
    False ->
      state.report(
        parser,
        parse_error.EnumTypeParameters(
          Span(name.span.end, state.previous_end(parser)),
          name.name,
        ),
      )
  }
  use #(Nil, parser) <- result.try(enum_clauses(parser, name))
  use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
  use #(variants, parser) <- result.try(variants(parser, open, name, []))
  let parser = case variants {
    [] -> state.report(parser, parse_error.EmptyEnum(name.span, name.name))
    _ -> parser
  }
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(ast.Enum(documentation:, name:, variants:, span:), parser))
}

fn enum_clauses(parser: Parser, name: ast.Name) -> Parsed(Nil) {
  case state.current(parser) {
    Lexeme(token: token.Is, span: start)
    | Lexeme(token: token.With, span: start) -> {
      use #(_, parser) <- result.try(type_list(state.skip(parser), []))
      let span = Span(start.start, state.previous_end(parser))
      use #(Nil, parser) <- result.try(enum_clauses(parser, name))
      Ok(#(
        Nil,
        state.report(parser, parse_error.EnumInheritance(span, name.name)),
      ))
    }
    _ -> Ok(#(Nil, parser))
  }
}

fn variants(
  parser: Parser,
  open: Lexeme,
  name: ast.Name,
  found: List(ast.Variant),
) -> Parsed(List(ast.Variant)) {
  let #(documentation, parser) = state.documentation(parser)
  let start = state.current(parser)
  case start.token {
    token.RightBrace -> Ok(#(list.reverse(found), state.skip(parser)))
    token.EndOfFile ->
      Error(state.unclosed(
        parser,
        open,
        token.RightBrace,
        parse_error.EnumBody,
        start,
      ))
    token.Comma -> variants(state.skip(parser), open, name, found)
    token.UpperName(variant) -> {
      let parser = state.skip(parser)
      let variant =
        ast.Variant(documentation:, name: ast.Name(variant, start.span))

      let parser = case state.current_token(parser) {
        token.LeftParen -> {
          let parser = skip_group(parser, 0)
          let span = Span(start.span.start, state.previous_end(parser))
          state.report(
            parser,
            parse_error.EnumVariantData(span, variant.name.name),
          )
        }
        _ -> parser
      }
      variants(parser, open, name, [variant, ..found])
    }

    _ -> {
      let parser = skip_member(state.skip(parser), brackets(start.token, 0))
      let span = Span(start.span.start, state.previous_end(parser))
      variants(
        state.report(parser, parse_error.EnumMember(span, name.name)),
        open,
        name,
        found,
      )
    }
  }
}

fn skip_group(parser: Parser, depth: Int) -> Parser {
  case state.current_token(parser) {
    token.EndOfFile -> parser
    found -> {
      let depth = brackets(found, depth)
      let parser = state.skip(parser)
      case depth {
        0 -> parser
        _ -> skip_group(parser, depth)
      }
    }
  }
}

fn skip_member(parser: Parser, depth: Int) -> Parser {
  case state.current_token(parser), depth {
    token.EndOfFile, _ -> parser
    token.RightBrace, 0 | token.Comma, 0 -> parser
    found, 0 ->
      case state.on_new_line(parser) {
        True -> parser
        False -> skip_member(state.skip(parser), brackets(found, 0))
      }
    found, _ -> skip_member(state.skip(parser), brackets(found, depth))
  }
}

fn brackets(found: token.Token, depth: Int) -> Int {
  case found {
    token.LeftParen
    | token.LeftBrace
    | token.LeftSquare
    | token.HashLeftParen
    | token.DoubleLess -> depth + 1
    token.RightParen
    | token.RightBrace
    | token.RightSquare
    | token.DoubleGreater -> int.max(0, depth - 1)
    _ -> depth
  }
}

type ConciseField {
  ConciseField(name: ast.Name, annotation: TypeAnnotation, span: Span)
}

fn concise_fields(parser: Parser, open: Lexeme) -> Parsed(List(ConciseField)) {
  state.delimited(
    parser,
    open,
    token.RightParen,
    parse_error.ConciseFields,
    fn(parser) {
      let start = state.current(parser).span.start
      use #(#(field, field_span), parser) <- result.try(state.expect_name(
        parser,
        "a field name",
      ))
      let name = ast.Name(name: field, span: field_span)
      case state.current(parser) {
        Lexeme(token: token.Colon, ..) -> {
          use #(annotation, parser) <- result.try(
            parse_type.parse_type(state.skip(parser)),
          )
          let span = state.span_from(parser, start)
          Ok(#(ConciseField(name:, annotation:, span:), parser))
        }
        _ -> {
          let parser =
            state.report(
              parser,
              parse_error.ConciseFieldType(field_span, field),
            )
          let annotation = ast.NamedType(None, "Nil", [], field_span)
          Ok(#(ConciseField(name:, annotation:, span: field_span), parser))
        }
      }
    },
  )
}

fn concise_type_parameters(fields: List(ConciseField)) -> List(ast.Name) {
  fields
  |> list.flat_map(fn(field) { type_variables(field.annotation) })
  |> list.fold([], fn(found, variable) {
    case list.any(found, fn(other: ast.Name) { other.name == variable.name }) {
      True -> found
      False -> [variable, ..found]
    }
  })
  |> list.reverse
}

fn type_variables(annotation: TypeAnnotation) -> List(ast.Name) {
  case annotation {
    ast.TypeVariable(name:, span:) -> [ast.Name(name:, span:)]
    ast.NamedType(arguments:, ..) | ast.TupleType(elements: arguments, ..) ->
      list.flat_map(arguments, type_variables)
    ast.FunctionType(parameters, result, _) ->
      list.flat_map(list.append(parameters, [result]), type_variables)
  }
}

fn concise_members(fields: List(ConciseField)) -> List(Member) {
  let declared =
    list.map(fields, fn(field) {
      ast.FieldMember(ast.Field(
        documentation: [],
        mutability: ast.Immutable,
        name: field.name,
        annotation: Some(field.annotation),
        value: None,
        span: field.span,
      ))
    })
  let parameters =
    list.map(fields, fn(field) {
      ast.Parameter(
        name: ast.NamedParameter(field.name.name),
        annotation: None,
        span: field.name.span,
      )
    })
  let assignments =
    list.map(fields, fn(field) {
      let span = field.span
      ast.ExpressionStatement(ast.Assignment(
        target: ast.AssignField(
          subject: ast.SelfExpression(field.name.span),
          name: field.name,
          span:,
        ),
        operator: ast.Assign,
        value: ast.Variable(field.name.name, field.name.span),
        span:,
      ))
    })
  let span = case fields, list.last(fields) {
    [first, ..], Ok(last) -> Span(first.span.start, last.span.end)
    _, _ -> location.point(location.start())
  }
  list.append(declared, [
    ast.ConstructorMember(ast.Constructor(
      documentation: [],
      parameters:,
      body: ast.Block(assignments, span),
      span:,
    )),
  ])
}

fn superclass(
  parser: Parser,
  class_name: ast.Name,
) -> Parsed(Option(TypeAnnotation)) {
  case state.is(parser, token.Is) {
    False -> Ok(#(None, parser))
    True -> {
      use #(first, parser) <- result.try(
        parse_type.parse_type(state.skip(parser)),
      )
      case state.is(parser, token.Comma) {
        False -> Ok(#(Some(first), parser))
        True -> {
          let extra_start = state.current(parser).span.start
          use #(_, parser) <- result.try(type_list(state.skip(parser), []))
          let extra = state.span_from(parser, extra_start)
          let error =
            parse_error.MultipleInheritance(
              class_name: class_name.name,
              first: type_name(first),
              extra:,
            )
          Ok(#(Some(first), state.report(parser, error)))
        }
      }
    }
  }
}

fn type_name(annotation: TypeAnnotation) -> String {
  case annotation {
    ast.NamedType(name:, ..) | ast.TypeVariable(name:, ..) -> name
    ast.TupleType(..) -> "a tuple"
    ast.FunctionType(..) -> "a function"
  }
}

fn interfaces(parser: Parser) -> Parsed(List(TypeAnnotation)) {
  case state.is(parser, token.With) {
    False -> Ok(#([], parser))
    True -> type_list(state.skip(parser), [])
  }
}

fn type_list(
  parser: Parser,
  types: List(TypeAnnotation),
) -> Parsed(List(TypeAnnotation)) {
  use #(annotation, parser) <- result.try(parse_type.parse_type(parser))
  let types = [annotation, ..types]
  case state.is(parser, token.Comma) {
    True -> type_list(state.skip(parser), types)
    False -> Ok(#(list.reverse(types), parser))
  }
}

fn type_parameters(parser: Parser) -> Parsed(List(ast.Name)) {
  case state.current(parser) {
    Lexeme(token: token.LeftParen, ..) as open ->
      state.delimited(
        state.skip(parser),
        open,
        token.RightParen,
        parse_error.TypeParameters,
        fn(parser) {
          use #(#(name, span), parser) <- result.try(state.expect_name(
            parser,
            "a type parameter",
          ))
          Ok(#(ast.Name(name:, span:), parser))
        },
      )
    _ -> Ok(#([], parser))
  }
}

fn upper_name(parser: Parser, what: String) -> Parsed(ast.Name) {
  use #(#(name, span), parser) <- result.try(state.expect_upper_name(
    parser,
    what,
  ))
  Ok(#(ast.Name(name:, span:), parser))
}

fn members(
  parser: Parser,
  open: Lexeme,
  kind: BodyKind,
  found: List(Member),
) -> Parsed(List(Member)) {
  let #(documentation, parser) = state.documentation(parser)
  let start = state.current(parser)
  let continue = fn(result: Parsed(Member)) {
    use #(member, parser) <- result.try(result)
    members(parser, open, kind, [member, ..found])
  }
  case start.token {
    token.RightBrace -> Ok(#(list.reverse(found), state.skip(parser)))
    token.EndOfFile ->
      Error(state.unclosed(
        parser,
        open,
        token.RightBrace,
        body_context(kind),
        start,
      ))
    token.Let ->
      continue(field(state.skip(parser), start, ast.Immutable, documentation))
    token.Var -> {
      let parser = case kind {
        ClassBody ->
          state.report(parser, parse_error.MutableClassField(start.span))
        ActorBody -> parser
      }
      continue(field(state.skip(parser), start, ast.Mutable, documentation))
    }
    token.New -> continue(constructor(state.skip(parser), start, documentation))
    token.Be -> {
      let parser = case kind {
        ClassBody ->
          state.report(parser, parse_error.BehaviourOutsideActor(start.span))
        ActorBody -> parser
      }
      continue(method(
        state.skip(parser),
        start,
        documentation,
        ast.BehaviourMember,
      ))
    }
    token.Fn -> {
      let parser =
        state.report(
          parser,
          parse_error.NamedFunctionWithFn(start.span, modifier_span(parser)),
        )
      continue(method(
        state.skip(parser),
        start,
        documentation,
        ast.MethodMember,
      ))
    }
    token.Name(word) ->
      case
        list.contains(visibility_words, word)
        && starts_member(state.peek(parser))
      {
        True -> {
          let parser =
            state.report(
              parser,
              parse_error.VisibilityModifier(
                state.current(parser).span,
                modifier_span(parser),
                word,
              ),
            )
          members(state.skip(parser), open, kind, found)
        }
        False ->
          continue(method(parser, start, documentation, ast.MethodMember))
      }
    _ ->
      case state.peek(parser) {
        token.LeftParen ->
          Error(state.name_error(start, parse_error.ExpectMember))
        _ -> Error(parse_error.UnexpectedToken(start, parse_error.ExpectMember))
      }
  }
}

fn body_context(kind: BodyKind) -> parse_error.Delimited {
  case kind {
    ClassBody -> parse_error.ClassBody
    ActorBody -> parse_error.ActorBody
  }
}

fn starts_member(next: token.Token) -> Bool {
  case next {
    token.Name(_) | token.Let | token.Var | token.New | token.Be -> True
    _ -> False
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

fn field(
  parser: Parser,
  keyword: Lexeme,
  mutability: ast.Mutability,
  documentation: List(String),
) -> Parsed(Member) {
  use #(#(name, name_span), parser) <- result.try(state.expect_name(
    parser,
    "a field name",
  ))
  use #(annotation, parser) <- result.try(parse_parameter.parse_annotation(
    parser,
  ))
  use #(value, parser) <- result.try(case state.is(parser, token.Equal) {
    False -> Ok(#(None, parser))
    True -> {
      use #(value, parser) <- result.try(
        parse_expression.parse_expression(state.skip(parser)),
      )
      Ok(#(Some(value), parser))
    }
  })
  let span = state.span_from(parser, keyword.span.start)
  let name = ast.Name(name:, span: name_span)
  Ok(#(
    ast.FieldMember(ast.Field(
      documentation:,
      mutability:,
      name:,
      annotation:,
      value:,
      span:,
    )),
    parser,
  ))
}

fn constructor(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(Member) {
  use #(parameters, parser) <- result.try(parse_parameter.parse_parameters(
    parser,
  ))
  use #(body, parser) <- result.try(parse_expression.parse_block(parser))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(
    ast.ConstructorMember(ast.Constructor(
      documentation:,
      parameters:,
      body:,
      span:,
    )),
    parser,
  ))
}

fn method(
  parser: Parser,
  start: Lexeme,
  documentation: List(String),
  make: fn(ast.Function) -> Member,
) -> Parsed(Member) {
  use #(function, parser) <- result.try(parse_function(parser, documentation))
  let span = state.span_from(parser, start.span.start)
  Ok(#(make(ast.Function(..function, span:)), parser))
}

pub fn parse_interface(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(ast.Interface) {
  use #(name, parser) <- result.try(upper_name(parser, "an interface name"))
  use #(type_parameters, parser) <- result.try(type_parameters(parser))

  use parser <- result.try(case state.current(parser) {
    Lexeme(token: token.Is, span:) -> {
      let parser = state.report(parser, parse_error.InterfaceInheritance(span))
      use #(_, parser) <- result.try(type_list(state.skip(parser), []))
      Ok(parser)
    }
    _ -> Ok(parser)
  })
  use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
  use #(requirements, parser) <- result.try(requirements(parser, open, []))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(
    ast.Interface(documentation:, name:, type_parameters:, requirements:, span:),
    parser,
  ))
}

fn requirements(
  parser: Parser,
  open: Lexeme,
  found: List(ast.Requirement),
) -> Parsed(List(ast.Requirement)) {
  let #(documentation, parser) = state.documentation(parser)
  let start = state.current(parser)
  case start.token {
    token.RightBrace -> Ok(#(list.reverse(found), state.skip(parser)))
    token.EndOfFile ->
      Error(state.unclosed(
        parser,
        open,
        token.RightBrace,
        parse_error.InterfaceBody,
        start,
      ))
    token.Let | token.Var -> {
      use #(member, parser) <- result.try(field(
        state.skip(parser),
        start,
        ast.Immutable,
        documentation,
      ))
      let span = case member {
        ast.FieldMember(field) -> field.span
        _ -> start.span
      }
      requirements(
        state.report(parser, parse_error.InterfaceField(span)),
        open,
        found,
      )
    }
    token.New -> {
      let parser =
        state.report(parser, parse_error.InterfaceConstructor(start.span))
      use #(_, parser) <- result.try(constructor(
        state.skip(parser),
        start,
        documentation,
      ))
      requirements(parser, open, found)
    }
    token.Be -> {
      let parser =
        state.report(parser, parse_error.InterfaceBehaviour(start.span))
      use #(requirement, parser) <- result.try(requirement(
        state.skip(parser),
        documentation,
      ))
      requirements(parser, open, [requirement, ..found])
    }
    token.Name(_) -> {
      use #(requirement, parser) <- result.try(requirement(
        parser,
        documentation,
      ))
      requirements(parser, open, [requirement, ..found])
    }
    _ -> Error(state.name_error(start, parse_error.ExpectRequirement))
  }
}

fn requirement(
  parser: Parser,
  documentation: List(String),
) -> Parsed(ast.Requirement) {
  let start = state.current(parser)
  use #(#(name, name_span), parser) <- result.try(state.expect_name(
    parser,
    "a method name",
  ))
  use #(parameters, parser) <- result.try(parse_parameter.parse_parameters(
    parser,
  ))
  use #(return_type, parser) <- result.try(
    parse_parameter.parse_return_annotation(parser),
  )
  let span = state.span_from(parser, start.span.start)

  let parser =
    list.fold(parameters, parser, fn(parser, parameter) {
      case parameter.annotation, parameter.name {
        Some(_), _ -> parser
        None, ast.NamedParameter(name) ->
          state.report(
            parser,
            parse_error.RequirementParameterType(parameter.span, name),
          )
        None, ast.DiscardedParameter ->
          state.report(
            parser,
            parse_error.RequirementParameterType(parameter.span, "_"),
          )
      }
    })
  let parser = case return_type {
    Some(_) -> parser
    None ->
      state.report(parser, parse_error.RequirementMissingReturnType(span, name))
  }
  use parser <- result.try(case state.is(parser, token.LeftBrace) {
    False -> Ok(parser)
    True -> {
      use #(body, parser) <- result.try(parse_expression.parse_block(parser))
      Ok(state.report(parser, parse_error.InterfaceMethodBody(body.span)))
    }
  })
  let name = ast.Name(name:, span: name_span)
  Ok(#(
    ast.Requirement(documentation:, name:, parameters:, return_type:, span:),
    parser,
  ))
}

pub fn parse_actor(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(ast.Actor) {
  use #(name, parser) <- result.try(upper_name(parser, "an actor name"))
  use #(type_parameters, parser) <- result.try(type_parameters(parser))

  use parser <- result.try(case state.current(parser) {
    Lexeme(token: token.Is, span:) -> {
      let parser = state.report(parser, parse_error.ActorInheritance(span))
      use #(_, parser) <- result.try(type_list(state.skip(parser), []))
      Ok(parser)
    }
    _ -> Ok(parser)
  })
  use #(interfaces, parser) <- result.try(interfaces(parser))
  use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
  use #(members, parser) <- result.try(members(parser, open, ActorBody, []))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(
    ast.Actor(
      documentation:,
      name:,
      type_parameters:,
      interfaces:,
      members:,
      span:,
    ),
    parser,
  ))
}

pub fn parse_external(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(ast.External) {
  use name <- result.try(case state.current(parser) {
    Lexeme(token: token.UpperName(name), span:) -> Ok(ast.Name(name:, span:))

    Lexeme(token: token.Name(_), span:) ->
      Error(parse_error.ExternalWithoutNamespace(span))
    found ->
      Error(state.name_error(
        found,
        parse_error.ExpectUpperName("a namespace name"),
      ))
  })
  let parser = state.skip(parser)
  use parser <- result.try(case state.current(parser) {
    Lexeme(token: token.Name("from"), ..) -> Ok(state.skip(parser))
    found ->
      Error(parse_error.UnexpectedToken(found, parse_error.ExpectName("`from`")))
  })
  use #(#(language, language_span), parser) <- result.try(foreign_language(
    parser,
  ))
  use #(#(module, module_span), parser) <- result.try(
    case state.current(parser) {
      Lexeme(token: token.String(""), span:) ->
        Ok(#(
          #("", span),
          state.report(state.skip(parser), parse_error.EmptyForeignModule(span)),
        ))
      Lexeme(token: token.String(module), span:) ->
        Ok(#(#(module, span), state.skip(parser)))
      found ->
        Error(parse_error.UnexpectedToken(
          found,
          parse_error.ExpectForeignModule,
        ))
    },
  )
  use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
  use #(functions, parser) <- result.try(external_functions(parser, open, []))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(
    ast.External(
      documentation:,
      name:,
      language:,
      language_span:,
      module:,
      module_span:,
      functions:,
      span:,
    ),
    parser,
  ))
}

pub fn parse_native(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(ast.External) {
  use name <- result.try(case state.current(parser) {
    Lexeme(token: token.UpperName(name), span:) -> Ok(ast.Name(name:, span:))
    found ->
      Error(state.name_error(
        found,
        parse_error.ExpectUpperName("a namespace name"),
      ))
  })
  let parser = state.skip(parser)
  use parser <- result.try(case state.current(parser) {
    Lexeme(token: token.Name("from"), ..) -> Ok(state.skip(parser))
    found ->
      Error(parse_error.UnexpectedToken(found, parse_error.ExpectName("`from`")))
  })
  use #(#(component, component_span), parser) <- result.try(
    case state.current(parser) {
      Lexeme(token: token.String(component), span:) -> {
        let parser = state.skip(parser)
        Ok(
          #(#(component, span), case native_component.valid_name(component) {
            True -> parser
            False ->
              state.report(
                parser,
                parse_error.InvalidNativeComponent(span, component),
              )
          }),
        )
      }
      found ->
        Error(parse_error.UnexpectedToken(
          found,
          parse_error.ExpectNativeComponent,
        ))
    },
  )
  use #(open, parser) <- result.try(state.expect(parser, token.LeftBrace))
  use #(functions, parser) <- result.try(external_functions(parser, open, []))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(
    ast.External(
      documentation:,
      name:,
      language: ast.Native,
      language_span: keyword.span,
      module: component,
      module_span: component_span,
      functions:,
      span:,
    ),
    parser,
  ))
}

fn foreign_language(
  parser: Parser,
) -> Parsed(#(ast.ForeignLanguage, location.Span)) {
  case state.current(parser) {
    Lexeme(token: token.Name(word), span:)
    | Lexeme(token: token.UpperName(word), span:) ->
      case foreign_language.from_name(word) {
        Ok(language) -> Ok(#(#(language, span), state.skip(parser)))
        Error(Nil) ->
          Ok(#(
            #(ast.Erlang, span),
            state.report(
              state.skip(parser),
              parse_error.UnsupportedForeignLanguage(span, word),
            ),
          ))
      }
    found ->
      Error(state.name_error(
        found,
        parse_error.ExpectName("a foreign language"),
      ))
  }
}

fn external_functions(
  parser: Parser,
  open: Lexeme,
  found: List(ast.ExternalFunction),
) -> Parsed(List(ast.ExternalFunction)) {
  let #(documentation, parser) = state.documentation(parser)
  let start = state.current(parser)
  case start.token {
    token.RightBrace -> Ok(#(list.reverse(found), state.skip(parser)))
    token.EndOfFile ->
      Error(state.unclosed(
        parser,
        open,
        token.RightBrace,
        parse_error.ExternalBody,
        start,
      ))
    token.Name(_) -> {
      use #(function, parser) <- result.try(external_function(
        parser,
        documentation,
      ))
      external_functions(parser, open, [function, ..found])
    }
    _ -> Error(state.name_error(start, parse_error.ExpectExternalFunction))
  }
}

fn external_function(
  parser: Parser,
  documentation: List(String),
) -> Parsed(ast.ExternalFunction) {
  let start = state.current(parser)
  use #(#(name, name_span), parser) <- result.try(state.expect_name(
    parser,
    "a function name",
  ))
  use #(parameters, parser) <- result.try(parse_parameter.parse_parameters(
    parser,
  ))

  let parser =
    list.fold(parameters, parser, fn(parser, parameter) {
      case parameter.annotation, parameter.name {
        Some(_), _ -> parser
        None, ast.NamedParameter(name) ->
          state.report(
            parser,
            parse_error.ExternalParameterType(parameter.span, name),
          )
        None, ast.DiscardedParameter ->
          state.report(
            parser,
            parse_error.ExternalParameterType(parameter.span, "_"),
          )
      }
    })
  use #(return_type, parser) <- result.try(case state.current(parser) {
    Lexeme(token: token.RightArrow, ..) ->
      parse_type.parse_type(state.skip(parser))

    Lexeme(token: token.Colon, span:) ->
      parse_type.parse_type(state.report(
        state.skip(parser),
        parse_error.ExternalColonReturn(span),
      ))
    _ ->
      Error(
        parse_error.ExternalMissingReturnType(state.span_from(
          parser,
          start.span.start,
        )),
      )
  })
  let span = state.span_from(parser, start.span.start)

  use parser <- result.try(
    case state.is(parser, token.LeftBrace) && !state.on_new_line(parser) {
      False -> Ok(parser)
      True -> {
        use #(body, parser) <- result.try(parse_expression.parse_block(parser))
        Ok(state.report(parser, parse_error.ExternalWithBody(body.span)))
      }
    },
  )
  Ok(#(
    ast.ExternalFunction(
      documentation:,
      name: ast.Name(name:, span: name_span),
      parameters:,
      return_type:,
      span:,
    ),
    parser,
  ))
}

pub fn parse_test(
  parser: Parser,
  keyword: Lexeme,
  documentation: List(String),
) -> Parsed(ast.Test) {
  let #(skipped, parser) = case state.current(parser) {
    Lexeme(token: token.Name("skip"), ..) -> #(True, state.skip(parser))
    _ -> #(False, parser)
  }
  use #(name, parser) <- result.try(case state.current(parser) {
    Lexeme(token: token.String(name), ..) -> Ok(#(name, state.skip(parser)))
    found ->
      Error(parse_error.UnexpectedToken(found, parse_error.ExpectTestName))
  })
  use #(body, parser) <- result.try(parse_expression.parse_block(parser))
  let span = state.span_from(parser, keyword.span.start)
  Ok(#(ast.Test(documentation:, name:, skipped:, body:, span:), parser))
}
