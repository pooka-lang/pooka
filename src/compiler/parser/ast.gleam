//// The syntax tree keeps the shape of the user's thought.
////
//// Represent declarations, expressions, patterns and annotations with their
//// original spans. This tree describes syntax; resolved identities and inferred
//// types live in later reports.
////
//// ```text
//// 1 + 2 -> Binary(Add, IntLiteral(1), IntLiteral(2), span)
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/list
import gleam/option.{type Option}
import utilities/location.{type Span}

pub type Module {
  Module(
    documentation: List(String),
    header: Option(ModuleHeader),
    imports: List(Import),
    declarations: List(Declaration),
  )
}

pub type ModuleHeader {
  ModuleHeader(name: Name, span: Span)
}

pub type ModulePath {
  ModulePath(segments: List(String), span: Span)
}

pub type Import {
  Import(
    module: ModulePath,
    items: List(ImportedName),
    alias: Option(Name),
    span: Span,
  )
}

pub type ImportedName {
  ImportedName(name: Name, alias: Option(Name), span: Span)
}

pub type Name {
  Name(name: String, span: Span)
}

pub type Declaration {
  FunctionDeclaration(Function)
  ClassDeclaration(Class)
  InterfaceDeclaration(Interface)
  ActorDeclaration(Actor)
  ExternalDeclaration(External)
  EnumDeclaration(Enum)
  TestDeclaration(Test)
}

pub type Function {
  Function(
    documentation: List(String),
    name: Name,
    parameters: List(Parameter),
    return_type: Option(TypeAnnotation),
    body: Block,
    span: Span,
  )
}

pub type Class {
  Class(
    documentation: List(String),
    name: Name,
    type_parameters: List(Name),
    superclass: Option(TypeAnnotation),
    interfaces: List(TypeAnnotation),
    members: List(Member),
    span: Span,
  )
}

pub type Enum {
  Enum(
    documentation: List(String),
    name: Name,
    variants: List(Variant),
    span: Span,
  )
}

pub type Variant {
  Variant(documentation: List(String), name: Name)
}

pub type Interface {
  Interface(
    documentation: List(String),
    name: Name,
    type_parameters: List(Name),
    requirements: List(Requirement),
    span: Span,
  )
}

pub type Requirement {
  Requirement(
    documentation: List(String),
    name: Name,
    parameters: List(Parameter),
    return_type: Option(TypeAnnotation),
    span: Span,
  )
}

pub type Actor {
  Actor(
    documentation: List(String),
    name: Name,
    type_parameters: List(Name),
    interfaces: List(TypeAnnotation),
    members: List(Member),
    span: Span,
  )
}

pub type External {
  External(
    documentation: List(String),
    name: Name,
    language: ForeignLanguage,
    language_span: Span,
    module: String,
    module_span: Span,
    functions: List(ExternalFunction),
    span: Span,
  )
}

pub type ForeignLanguage {

  Erlang

  Elixir

  Gleam

  Lfe

  Native
}

pub type ExternalFunction {
  ExternalFunction(
    documentation: List(String),
    name: Name,
    parameters: List(Parameter),
    return_type: TypeAnnotation,
    span: Span,
  )
}

pub type Test {
  Test(
    documentation: List(String),
    name: String,
    skipped: Bool,
    body: Block,
    span: Span,
  )
}

pub type Member {

  FieldMember(Field)

  ConstructorMember(Constructor)

  MethodMember(Function)

  BehaviourMember(Function)
}

pub type Mutability {

  Immutable

  Mutable
}

pub type Field {
  Field(
    documentation: List(String),
    mutability: Mutability,
    name: Name,
    annotation: Option(TypeAnnotation),
    value: Option(Expression),
    span: Span,
  )
}

pub type Constructor {
  Constructor(
    documentation: List(String),
    parameters: List(Parameter),
    body: Block,
    span: Span,
  )
}

pub type Parameter {
  Parameter(name: ParameterName, annotation: Option(TypeAnnotation), span: Span)
}

pub type ParameterName {

  NamedParameter(name: String)

  DiscardedParameter
}

pub type TypeAnnotation {

  NamedType(
    module: Option(String),
    name: String,
    arguments: List(TypeAnnotation),
    span: Span,
  )

  TypeVariable(name: String, span: Span)

  TupleType(elements: List(TypeAnnotation), span: Span)

  FunctionType(
    parameters: List(TypeAnnotation),
    return_type: TypeAnnotation,
    span: Span,
  )
}

pub type Block {
  Block(statements: List(Statement), span: Span)
}

pub type Statement {

  LetStatement(
    pattern: Pattern,
    annotation: Option(TypeAnnotation),
    value: Expression,
    span: Span,
  )

  LetAssertStatement(
    pattern: Pattern,
    annotation: Option(TypeAnnotation),
    value: Expression,
    message: Option(Expression),
    span: Span,
  )

  ExpressionStatement(expression: Expression)
}

pub type Expression {

  IntLiteral(value: String, span: Span)

  FloatLiteral(value: String, span: Span)

  StringLiteral(value: String, span: Span)

  BoolLiteral(value: Bool, span: Span)

  NilLiteral(span: Span)

  Variable(name: String, span: Span)

  TypeName(name: String, span: Span)

  SelfExpression(span: Span)

  SuperExpression(span: Span)

  ListExpression(elements: List(Expression), span: Span)

  ListSpread(elements: List(Expression), tail: Expression, span: Span)

  TupleExpression(elements: List(Expression), span: Span)

  BitArrayExpression(segments: List(BitArraySegment(Expression)), span: Span)

  BlockExpression(block: Block)

  AnonymousFunction(
    parameters: List(Parameter),
    return_type: Option(TypeAnnotation),
    body: Block,
    span: Span,
  )

  Call(callee: Expression, arguments: List(Expression), span: Span)

  FieldAccess(subject: Expression, name: Name, span: Span)

  TupleAccess(subject: Expression, index: Int, index_span: Span, span: Span)

  Propagate(operand: Expression, span: Span)

  Unary(operator: UnaryOperator, operand: Expression, span: Span)

  Binary(
    operator: BinaryOperator,
    left: Expression,
    right: Expression,
    span: Span,
  )

  Match(subject: Expression, branches: List(Branch), span: Span)

  Loop(iteration: Option(Iteration), body: Block, span: Span)

  Break(value: Option(Expression), span: Span)

  Continue(span: Span)

  Panic(message: Option(Expression), span: Span)

  Todo(message: Option(Expression), span: Span)

  Assert(condition: Expression, message: Option(Expression), span: Span)

  Assignment(
    target: AssignmentTarget,
    operator: AssignmentOperator,
    value: Expression,
    span: Span,
  )
}

pub type Iteration {
  Iteration(pattern: Pattern, iterable: Expression, span: Span)
}

pub type Branch {
  Branch(
    pattern: Pattern,
    guard: Option(Expression),
    body: Expression,
    span: Span,
  )
}

pub type AssignmentTarget {

  AssignVariable(name: Name)

  AssignField(subject: Expression, name: Name, span: Span)
}

pub type AssignmentOperator {
  Assign
  AddAssign
  SubtractAssign
  MultiplyAssign
}

pub type UnaryOperator {

  Negate

  Not
}

pub type BinaryOperator {
  Add
  Subtract
  Multiply
  Divide
  Remainder
  Equal
  NotEqual
  Less
  LessOrEqual
  Greater
  GreaterOrEqual
  And
  Or

  BitAnd

  BitOr
  PipeOperator
}

pub type BitArraySegment(value) {
  BitArraySegment(value: value, options: List(BitArrayOption), span: Span)
}

pub type BitArrayOption {
  NamedOption(name: String, span: Span)
  SizeOption(size: Expression, span: Span)
  UnitOption(unit: Expression, span: Span)
}

pub type Pattern {
  AlternativePattern(patterns: List(Pattern), span: Span)

  IntPattern(value: String, span: Span)

  FloatPattern(value: String, span: Span)

  StringPattern(value: String, span: Span)

  BoolPattern(value: Bool, span: Span)

  NilPattern(span: Span)

  VariablePattern(name: String, span: Span)

  DiscardPattern(span: Span)

  TuplePattern(elements: List(Pattern), span: Span)

  ListPattern(elements: List(Pattern), tail: Option(ListTail), span: Span)

  ConstructorPattern(
    module: Option(String),
    name: String,
    arguments: List(Pattern),
    span: Span,
  )

  BitArrayPattern(segments: List(BitArraySegment(Pattern)), span: Span)

  EnumPattern(
    module: Option(String),
    enum_name: String,
    variant: Name,
    span: Span,
  )
}

pub type ListTail {

  BoundTail(name: String, span: Span)

  IgnoredTail(span: Span)
}

pub fn expression_span(expression: Expression) -> Span {
  case expression {
    IntLiteral(span:, ..)
    | FloatLiteral(span:, ..)
    | StringLiteral(span:, ..)
    | BoolLiteral(span:, ..)
    | NilLiteral(span:)
    | Variable(span:, ..)
    | TypeName(span:, ..)
    | SelfExpression(span:)
    | SuperExpression(span:)
    | ListExpression(span:, ..)
    | ListSpread(span:, ..)
    | TupleExpression(span:, ..)
    | BitArrayExpression(span:, ..)
    | AnonymousFunction(span:, ..)
    | Call(span:, ..)
    | FieldAccess(span:, ..)
    | TupleAccess(span:, ..)
    | Propagate(span:, ..)
    | Unary(span:, ..)
    | Binary(span:, ..)
    | Match(span:, ..)
    | Loop(span:, ..)
    | Break(span:, ..)
    | Continue(span:)
    | Panic(span:, ..)
    | Todo(span:, ..)
    | Assert(span:, ..)
    | Assignment(span:, ..) -> span
    BlockExpression(block:) -> block.span
  }
}

pub fn pattern_span(pattern: Pattern) -> Span {
  case pattern {
    AlternativePattern(span:, ..)
    | IntPattern(span:, ..)
    | FloatPattern(span:, ..)
    | StringPattern(span:, ..)
    | BoolPattern(span:, ..)
    | NilPattern(span:)
    | VariablePattern(span:, ..)
    | DiscardPattern(span:)
    | TuplePattern(span:, ..)
    | ListPattern(span:, ..)
    | ConstructorPattern(span:, ..)
    | EnumPattern(span:, ..)
    | BitArrayPattern(span:, ..) -> span
  }
}

pub fn statement_span(statement: Statement) -> Span {
  case statement {
    LetStatement(span:, ..) | LetAssertStatement(span:, ..) -> span
    ExpressionStatement(expression:) -> expression_span(expression)
  }
}

pub fn pattern_expressions(pattern: Pattern) -> List(Expression) {
  case pattern {
    AlternativePattern(patterns, _) ->
      list.flat_map(patterns, pattern_expressions)
    TuplePattern(elements:, ..)
    | ListPattern(elements:, ..)
    | ConstructorPattern(arguments: elements, ..) ->
      list.flat_map(elements, pattern_expressions)
    BitArrayPattern(segments:, ..) ->
      list.flat_map(segments, fn(segment) {
        list.append(
          pattern_expressions(segment.value),
          list.filter_map(segment.options, fn(option) {
            case option {
              NamedOption(..) -> Error(Nil)
              SizeOption(value, _) | UnitOption(value, _) -> Ok(value)
            }
          }),
        )
      })
    VariablePattern(..)
    | IntPattern(..)
    | FloatPattern(..)
    | StringPattern(..)
    | BoolPattern(..)
    | NilPattern(..)
    | DiscardPattern(..)
    | EnumPattern(..) -> []
  }
}

pub fn declaration_name(declaration: Declaration) -> Result(Name, Nil) {
  case declaration {
    FunctionDeclaration(value) -> Ok(value.name)
    ClassDeclaration(value) -> Ok(value.name)
    InterfaceDeclaration(value) -> Ok(value.name)
    ActorDeclaration(value) -> Ok(value.name)
    ExternalDeclaration(value) -> Ok(value.name)
    EnumDeclaration(value) -> Ok(value.name)
    TestDeclaration(_) -> Error(Nil)
  }
}

pub fn pattern_bindings(pattern: Pattern) -> List(Name) {
  case pattern {
    AlternativePattern(patterns, _) ->
      list.flat_map(patterns, pattern_bindings)
      |> list.fold([], fn(names, name) {
        case
          list.any(names, fn(previous: Name) { previous.name == name.name })
        {
          True -> names
          False -> list.append(names, [name])
        }
      })
    VariablePattern(name, span) -> [Name(name, span)]
    TuplePattern(elements:, ..) | ConstructorPattern(arguments: elements, ..) ->
      list.flat_map(elements, pattern_bindings)
    ListPattern(elements:, tail:, ..) ->
      list.append(list.flat_map(elements, pattern_bindings), case tail {
        option.Some(BoundTail(name, span)) -> [Name(name, span)]
        option.Some(IgnoredTail(_)) | option.None -> []
      })
    BitArrayPattern(segments:, ..) ->
      list.flat_map(segments, fn(segment) { pattern_bindings(segment.value) })
    IntPattern(..)
    | FloatPattern(..)
    | StringPattern(..)
    | BoolPattern(..)
    | NilPattern(..)
    | DiscardPattern(..)
    | EnumPattern(..) -> []
  }
}

pub fn type_span(annotation: TypeAnnotation) -> Span {
  case annotation {
    NamedType(span:, ..)
    | TypeVariable(span:, ..)
    | TupleType(span:, ..)
    | FunctionType(span:, ..) -> span
  }
}

/// Return the source alternatives of one arm without copying its guard or body.
/// A solitary pattern is still one alternative.
pub fn pattern_alternatives(pattern: Pattern) -> List(Pattern) {
  case pattern {
    AlternativePattern(patterns, _) -> patterns
    _ -> [pattern]
  }
}
