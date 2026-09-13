//// A pattern describes a shape before it binds a name.
////
//// Inspect nested patterns and type annotations independently of inference.
//// Constructor arguments, list tails and binary segments must retain their
//// syntax, and a qualified type name must not become an ordinary field-access
//// expression.
////
//// ```pooka
//// main(value) { let assert Some(#(first, _)) = value
//// first }
//// ```

import compiler/parser/ast
import gleam/option.{None, Some}
import support

/// Place the pattern in its parser context, then extract the node under test.
/// The wrapper supplies real surrounding syntax instead of constructing an AST
/// by hand.
fn pattern(source: String) -> ast.Pattern {
  let assert ast.Match(branches: [ast.Branch(pattern:, ..)], ..) =
    support.expression("match value {\n  " <> source <> " -> Nil\n}")
  pattern
}

fn annotation(source: String) -> ast.TypeAnnotation {
  let assert [ast.LetStatement(annotation: Some(annotation), ..)] =
    support.parse_body("let x: " <> source <> " = Nil")
  annotation
}

pub fn literal_patterns_test() {
  let assert ast.IntPattern("200", _) = pattern("200")
  let assert ast.FloatPattern("1.5", _) = pattern("1.5")
  let assert ast.StringPattern("start", _) = pattern("\"start\"")
  let assert ast.BoolPattern(True, _) = pattern("True")
  let assert ast.BoolPattern(False, _) = pattern("False")
  let assert ast.NilPattern(_) = pattern("Nil")
}

pub fn negative_literal_patterns_test() {
  let assert ast.IntPattern("-1", _) = pattern("-1")
  let assert ast.FloatPattern("-0.5", _) = pattern("-0.5")
}

pub fn variable_and_wildcard_patterns_test() {
  let assert ast.VariablePattern("value", _) = pattern("value")
  let assert ast.VariablePattern("_error", _) = pattern("_error")
  let assert ast.DiscardPattern(_) = pattern("_")
}

pub fn tuple_patterns_test() {
  let assert ast.TuplePattern(
    [ast.StringPattern("user", _), ast.TuplePattern([_, _], _)],
    _,
  ) = pattern("#(\"user\", #(name, age))")
}

pub fn list_patterns_test() {
  let assert ast.ListPattern([], None, _) = pattern("[]")
  let assert ast.ListPattern([ast.VariablePattern("first", _)], None, _) =
    pattern("[first]")
  let assert ast.ListPattern([_], Some(ast.BoundTail("rest", _)), _) =
    pattern("[first, ..rest]")
  let assert ast.ListPattern([_, _], Some(ast.BoundTail("rest", _)), _) =
    pattern("[first, second, ..rest]")
  let assert ast.ListPattern([_], Some(ast.IgnoredTail(_)), _) =
    pattern("[first, ..]")
}

pub fn constructor_patterns_test() {
  let assert ast.ConstructorPattern(
    None,
    "Ok",
    [ast.VariablePattern("value", _)],
    _,
  ) = pattern("Ok(value)")

  let assert ast.ConstructorPattern(None, "North", [], _) = pattern("North")
  let assert ast.ConstructorPattern(Some("shape"), "Circle", [_], _) =
    pattern("shape.Circle(radius)")
}

pub fn nested_patterns_test() {
  let assert ast.ConstructorPattern(
    name: "Ok",
    arguments: [
      ast.ListPattern(
        [ast.ConstructorPattern(name: "User", arguments: [_, _], ..)],
        Some(ast.BoundTail("rest", _)),
        _,
      ),
    ],
    ..,
  ) = pattern("Ok([User(name, age), ..rest])")
}

pub fn bit_array_patterns_test() {
  let assert ast.BitArrayPattern(
    [
      ast.BitArraySegment(
        value: ast.VariablePattern("header", _),
        options: [ast.SizeOption(ast.IntLiteral("8", _), _)],
        ..,
      ),
      ast.BitArraySegment(
        value: ast.VariablePattern("rest", _),
        options: [ast.NamedOption("bits", _)],
        ..,
      ),
    ],
    _,
  ) = pattern("<<header:8, rest:bits>>")
}

// Preserve the size expression in the pattern tree. Later analysis needs it
// to resolve bindings and validate segment layout in source order.
pub fn bit_array_size_from_a_binding_test() {
  let assert ast.BitArrayPattern(
    [
      _,
      ast.BitArraySegment(
        options: [ast.SizeOption(ast.Variable("length", _), _)],
        ..,
      ),
    ],
    _,
  ) = pattern("<<length, body:size(length)>>")
}

pub fn named_types_test() {
  let assert ast.NamedType(None, "Int", [], _) = annotation("Int")
  let assert ast.NamedType(None, "Nil", [], _) = annotation("Nil")
  let assert ast.NamedType(None, "List", [ast.NamedType(name: "Int", ..)], _) =
    annotation("List(Int)")
  let assert ast.NamedType(
    None,
    "Result",
    [ast.NamedType(name: "Config", ..), ast.NamedType(name: "ParseError", ..)],
    _,
  ) = annotation("Result(Config, ParseError)")
}

pub fn qualified_types_test() {
  let assert ast.NamedType(Some("http"), "Request", [], _) =
    annotation("http.Request")
}

pub fn type_variables_test() {
  let assert ast.NamedType(
    name: "Option",
    arguments: [ast.TypeVariable("a", _)],
    ..,
  ) = annotation("Option(a)")
}

pub fn tuple_types_test() {
  let assert ast.TupleType(
    [ast.NamedType(name: "String", ..), ast.NamedType(name: "Int", ..)],
    _,
  ) = annotation("#(String, Int)")
}

pub fn function_types_test() {
  let assert ast.FunctionType(
    [ast.NamedType(name: "Int", ..)],
    ast.NamedType(name: "Int", ..),
    _,
  ) = annotation("fn(Int) -> Int")
  let assert ast.FunctionType([_, _], ast.NamedType(name: "User", ..), _) =
    annotation("fn(String, Int) -> User")
  let assert ast.FunctionType([], ast.NamedType(name: "Nil", ..), _) =
    annotation("fn() -> Nil")
}

pub fn nested_generic_types_test() {
  let assert ast.NamedType(
    name: "Result",
    arguments: [
      ast.NamedType(
        name: "List",
        arguments: [ast.NamedType(name: "User", ..)],
        ..,
      ),
      _,
    ],
    ..,
  ) = annotation("Result(List(User), HttpError)")
}
