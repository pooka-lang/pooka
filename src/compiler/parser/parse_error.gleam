//// A misplaced token deserves a patient explanation.
////
//// Represent recoverable syntax failures with stable identifiers, spans and safe
//// migration edits. Turn parser-specific details into diagnostics only after the
//// parser has finished collecting them.
////
//// ```text
//// colon return annotation -> diagnostic + replacement arrow
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/foreign_language
import compiler/lexer/token.{type Lexeme, type Token}
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import utilities/location.{type Location, type Position, type Span}
import utilities/text

pub type Expectation {
  ExpectExpression
  ExpectPattern
  ExpectType

  ExpectDeclaration

  ExpectMember

  ExpectRequirement

  ExpectParameter

  ExpectName(what: String)

  ExpectUpperName(what: String)

  ExpectModulePath

  ExpectImportedName

  ExpectTestName

  ExpectForeignModule

  ExpectNativeComponent

  ExpectExternalFunction

  ExpectEnumVariant

  ExpectBitArrayOption

  ExpectStatementEnd

  ExpectToken(Token)

  ExpectOneOf(List(Token))
}

pub type Delimited {
  ParameterList
  ArgumentList
  ListLiteral
  TupleLiteral
  BitArrayLiteral
  TypeArguments
  TypeParameters
  ImportList
  PatternArguments
  Grouping
  BlockBody
  ClassBody
  InterfaceBody
  ActorBody
  MatchBody
  ExternalBody
  EnumBody
  ConciseFields
}

pub type MissingKeyword {
  Return
  While
  For
  Else
  Throw
  Try
  Catch
}

pub type ParseError {

  UnexpectedToken(found: Lexeme, expected: Expectation)

  ReservedWord(found: Lexeme, expected: Expectation)

  UnclosedDelimiter(
    open: Span,
    close: Token,
    found: Lexeme,
    context: Delimited,
    insert_at: Position,
  )

  MissingModuleHeader(at: Span)

  ModuleHeaderNotFirst(header: Span)

  ModuleHeaderPath(path: Span, name: String, full_path: String)

  DuplicateModuleHeader(header: Span, first: Span)

  MisplacedModuleDocumentation(comment: Span)

  ImportInsideBlock(keyword: Span)

  TopLevelExpression(expression: Span)

  TopLevelBinding(keyword: Span)

  TopLevelMutableState(keyword: Span)

  NamedFunctionWithFn(keyword: Span, removal: Span)

  VisibilityModifier(keyword: Span, removal: Span, word: String)

  MutableClassField(keyword: Span)

  BehaviourOutsideActor(keyword: Span)

  MultipleInheritance(class_name: String, first: String, extra: Span)

  SuperclassAfterInterfaces(keyword: Span)

  InterfaceInheritance(keyword: Span)

  ActorInheritance(keyword: Span)

  InterfaceMethodBody(body: Span)

  InterfaceField(field: Span)

  InterfaceConstructor(keyword: Span)

  InterfaceBehaviour(keyword: Span)

  ExternalWithBody(body: Span)

  ExternalWithoutNamespace(name: Span)

  UnsupportedForeignLanguage(language: Span, word: String)

  EmptyForeignModule(module: Span)

  InvalidNativeComponent(component: Span, name: String)

  EnumVariantData(variant: Span, name: String)

  EnumTypeParameters(parameters: Span, name: String)

  EnumInheritance(clause: Span, name: String)

  EnumMember(member: Span, name: String)

  EmptyEnum(name: Span, enum_name: String)

  EnumPatternArguments(arguments: Span, enum_name: String, variant: String)

  ConciseFieldType(field: Span, name: String)

  PatternAlternatives(alternatives: Span)

  ConciseConstructor(constructor: Span, class_name: String)

  CallableColonReturn(colon: Span)

  ExternalColonReturn(colon: Span)

  ExternalMissingReturnType(signature: Span)

  ExternalParameterType(parameter: Span, name: String)

  RequirementParameterType(parameter: Span, name: String)

  RequirementMissingReturnType(requirement: Span, name: String)

  UnsupportedKeyword(word: Span, keyword: MissingKeyword)

  IfOutsideGuard(keyword: Span)

  InvalidAssignmentTarget(target: Span)
}

pub fn span(error: ParseError) -> Span {
  case error {
    UnexpectedToken(found:, ..) | ReservedWord(found:, ..) -> found.span
    UnclosedDelimiter(found:, ..) -> found.span
    MissingModuleHeader(at:) -> at
    ModuleHeaderNotFirst(header:) | DuplicateModuleHeader(header:, ..) -> header
    ModuleHeaderPath(path:, ..) -> path
    MisplacedModuleDocumentation(comment:) -> comment
    TopLevelExpression(expression:) -> expression
    ImportInsideBlock(keyword:)
    | TopLevelBinding(keyword:)
    | TopLevelMutableState(keyword:)
    | NamedFunctionWithFn(keyword:, ..)
    | VisibilityModifier(keyword:, ..)
    | MutableClassField(keyword:)
    | BehaviourOutsideActor(keyword:)
    | SuperclassAfterInterfaces(keyword:)
    | InterfaceInheritance(keyword:)
    | ActorInheritance(keyword:)
    | InterfaceConstructor(keyword:)
    | InterfaceBehaviour(keyword:)
    | IfOutsideGuard(keyword:) -> keyword
    MultipleInheritance(extra:, ..) -> extra
    InterfaceMethodBody(body:) | ExternalWithBody(body:) -> body
    ExternalWithoutNamespace(name:) -> name
    UnsupportedForeignLanguage(language:, ..) -> language
    EmptyForeignModule(module:) -> module
    InvalidNativeComponent(component:, ..) -> component
    EnumVariantData(variant:, ..) -> variant
    EnumTypeParameters(parameters:, ..) -> parameters
    EnumInheritance(clause:, ..) -> clause
    EnumMember(member:, ..) -> member
    EmptyEnum(name:, ..) -> name
    EnumPatternArguments(arguments:, ..) -> arguments
    ConciseFieldType(field:, ..) -> field
    PatternAlternatives(alternatives:) -> alternatives
    ConciseConstructor(constructor:, ..) -> constructor
    CallableColonReturn(colon:) -> colon
    ExternalColonReturn(colon:) -> colon
    ExternalMissingReturnType(signature:) -> signature
    ExternalParameterType(parameter:, ..) -> parameter
    RequirementParameterType(parameter:, ..) -> parameter
    RequirementMissingReturnType(requirement:, ..) -> requirement
    InterfaceField(field:) -> field
    UnsupportedKeyword(word:, ..) -> word
    InvalidAssignmentTarget(target:) -> target
  }
}

pub fn id(error: ParseError) -> String {
  case error {
    UnexpectedToken(..) -> "parse.unexpected_token"
    ReservedWord(..) -> "parse.reserved_word"
    UnclosedDelimiter(..) -> "parse.unclosed_delimiter"
    MissingModuleHeader(..) -> "parse.missing_module_header"
    ModuleHeaderNotFirst(..) -> "parse.module_header_not_first"
    DuplicateModuleHeader(..) -> "parse.duplicate_module_header"
    ModuleHeaderPath(..) -> "parse.module_header_path"
    MisplacedModuleDocumentation(..) -> "parse.misplaced_module_documentation"
    ImportInsideBlock(..) -> "parse.import_inside_block"
    TopLevelExpression(..) -> "parse.top_level_expression"
    TopLevelBinding(..) -> "parse.top_level_binding"
    TopLevelMutableState(..) -> "parse.top_level_mutable_state"
    NamedFunctionWithFn(..) -> "parse.named_function_with_fn"
    VisibilityModifier(..) -> "parse.visibility_modifier"
    MutableClassField(..) -> "parse.mutable_class_field"
    BehaviourOutsideActor(..) -> "parse.behaviour_outside_actor"
    MultipleInheritance(..) -> "parse.multiple_inheritance"
    SuperclassAfterInterfaces(..) -> "parse.superclass_after_interfaces"
    InterfaceInheritance(..) -> "parse.interface_inheritance"
    ActorInheritance(..) -> "parse.actor_inheritance"
    InterfaceMethodBody(..) -> "parse.interface_method_body"
    InterfaceField(..) -> "parse.interface_field"
    InterfaceConstructor(..) -> "parse.interface_constructor"
    InterfaceBehaviour(..) -> "parse.interface_behaviour"
    ExternalWithBody(..) -> "parse.external_with_body"
    ExternalWithoutNamespace(..) -> "parse.external_without_namespace"
    UnsupportedForeignLanguage(..) -> "parse.unsupported_foreign_language"
    EmptyForeignModule(..) -> "parse.empty_foreign_module"
    InvalidNativeComponent(..) -> "parse.invalid_native_component"
    EnumVariantData(..) -> "parse.enum_variant_data"
    EnumTypeParameters(..) -> "parse.enum_type_parameters"
    EnumInheritance(..) -> "parse.enum_inheritance"
    EnumMember(..) -> "parse.enum_member"
    EmptyEnum(..) -> "parse.empty_enum"
    EnumPatternArguments(..) -> "parse.enum_pattern_arguments"
    ConciseFieldType(..) -> "parse.concise_field_type"
    PatternAlternatives(..) -> "parse.pattern_alternatives"
    ConciseConstructor(..) -> "parse.concise_constructor"
    CallableColonReturn(..) -> "parse.callable_colon_return"
    ExternalColonReturn(..) -> "parse.external_colon_return"
    ExternalMissingReturnType(..) -> "parse.external_missing_return_type"
    ExternalParameterType(..) -> "parse.external_parameter_type"
    RequirementParameterType(..) -> "parse.requirement_parameter_type"
    RequirementMissingReturnType(..) -> "parse.requirement_missing_return_type"
    UnsupportedKeyword(..) -> "parse.unsupported_keyword"
    IfOutsideGuard(..) -> "parse.if_outside_guard"
    InvalidAssignmentTarget(..) -> "parse.invalid_assignment_target"
  }
}

pub fn missing_keyword(word: String) -> Result(MissingKeyword, Nil) {
  case word {
    "return" -> Ok(Return)
    "while" -> Ok(While)
    "for" -> Ok(For)
    "else" -> Ok(Else)
    "throw" -> Ok(Throw)
    "try" -> Ok(Try)
    "catch" -> Ok(Catch)
    _ -> Error(Nil)
  }
}

pub fn to_diagnostic(error: ParseError, path: String) -> Diagnostic {
  let at = fn(span: Span) -> Location { location.new(path, span) }
  let here = at(span(error))
  let base = fn(title: String) { diagnostic.error(id(error), title) }
  case error {
    UnexpectedToken(found:, expected:) ->
      base(unexpected_title(found.token))
      |> diagnostic.primary(here, expectation_label(expected))
      |> diagnostic.conclusion(
        "Expected "
        <> describe_expectation(expected)
        <> ", but found "
        <> token.describe(found.token)
        <> ".",
      )

    ReservedWord(found:, expected:) -> {
      let word = token.to_source(found.token)
      base("reserved word used as a name")
      |> diagnostic.primary(here, "`" <> word <> "` is a reserved word")
      |> diagnostic.conclusion(
        "Expected "
        <> describe_expectation(expected)
        <> ", but `"
        <> word
        <> "` is a keyword.",
      )
      |> diagnostic.help(
        "Choose a different name, such as `" <> word <> "_value`.",
      )
    }

    UnclosedDelimiter(open:, close:, found:, context:, insert_at:) -> {
      let closer = token.to_source(close)
      let open_location = case
        location.is_multiline(location.between(open.start, insert_at))
      {
        True -> at(open)
        False -> at(location.between(open.start, insert_at))
      }
      let before = case found.token {
        token.EndOfFile -> "the end of the file"
        other -> "`" <> token.to_source(other) <> "`"
      }
      base("missing `" <> closer <> "`")
      |> diagnostic.primary(open_location, delimited_label(context))
      |> diagnostic.conclusion(
        "Expected `" <> closer <> "` before " <> before <> ".",
      )
      |> diagnostic.fix(
        at(location.point(insert_at)),
        closer,
        "Insert `" <> closer <> "`",
        case context {
          BlockBody
          | ClassBody
          | InterfaceBody
          | ActorBody
          | MatchBody
          | ExternalBody
          | EnumBody -> diagnostic.Uncertain
          ParameterList
          | ArgumentList
          | ListLiteral
          | TupleLiteral
          | BitArrayLiteral
          | TypeArguments
          | TypeParameters
          | ImportList
          | PatternArguments
          | ConciseFields
          | Grouping -> diagnostic.Automatic
        },
      )
    }

    MissingModuleHeader(..) ->
      base("missing module declaration")
      |> diagnostic.primary(here, "expected a `module` declaration before this")
      |> diagnostic.conclusion(
        "Every Pooka file begins with a `module` declaration, such as `module main`.",
      )
      |> diagnostic.note(
        "A module is named after its file: `src/http/client.pooka` declares `module client`.",
      )

    ModuleHeaderNotFirst(..) ->
      base("module declaration is not first")
      |> diagnostic.primary(
        here,
        "this must come before imports and declarations",
      )
      |> diagnostic.conclusion(
        "The `module` declaration is the first construct of a file after its documentation.",
      )

    ModuleHeaderPath(path:, name:, full_path:) ->
      base("module declarations do not include directories")
      |> diagnostic.primary(
        here,
        "the directories come from the file's location",
      )
      |> diagnostic.conclusion("Write `module " <> name <> "`.")
      |> diagnostic.note(
        "Imports still use the full path: `import " <> full_path <> "`.",
      )
      |> diagnostic.fix(
        at(path),
        name,
        "Keep only `" <> name <> "`",
        diagnostic.Automatic,
      )

    DuplicateModuleHeader(first:, ..) ->
      base("module declared more than once")
      |> diagnostic.secondary(at(first), "the module is declared here")
      |> diagnostic.primary(here, "this declares it again")
      |> diagnostic.conclusion("A source file defines exactly one module.")

    MisplacedModuleDocumentation(..) ->
      base("misplaced module documentation")
      |> diagnostic.primary(
        here,
        "`////` comments must come before the `module` declaration",
      )
      |> diagnostic.conclusion(
        "Module documentation appears at the beginning of the file.",
      )
      |> diagnostic.help(
        "Use `///` to document the next declaration, or `//` for an ordinary comment.",
      )

    ImportInsideBlock(..) ->
      base("imports must be at the top level")
      |> diagnostic.primary(here, "`import` is not allowed inside a block")
      |> diagnostic.conclusion(
        "Imports apply to the whole module and follow the `module` declaration.",
      )
      |> diagnostic.help("Move this import to the top of the file.")

    TopLevelExpression(..) ->
      base("code outside a function")
      |> diagnostic.primary(here, "expressions cannot appear at the top level")
      |> diagnostic.conclusion(
        "Executable code belongs inside functions, methods, constructors or tests.",
      )
      |> diagnostic.note("Importing a module never runs code.")

    TopLevelBinding(..) ->
      base("binding outside a function")
      |> diagnostic.primary(here, "`let` is not allowed at the top level")
      |> diagnostic.conclusion(
        "Bindings belong inside functions, methods, constructors or tests.",
      )
      |> diagnostic.help(
        "Wrap the value in a function, such as `default_name() { ... }`.",
      )

    TopLevelMutableState(..) ->
      base("modules cannot have mutable state")
      |> diagnostic.primary(here, "`var` is not allowed at the top level")
      |> diagnostic.conclusion(
        "Modules cannot declare mutable global variables.",
      )
      |> diagnostic.note("Long-lived mutable state belongs in actors.")

    NamedFunctionWithFn(removal:, ..) ->
      base("named functions do not use `fn`")
      |> diagnostic.primary(
        here,
        "`fn` is only for anonymous functions and function types",
      )
      |> diagnostic.conclusion(
        "Named functions are written `name(parameters) { ... }`.",
      )
      |> diagnostic.fix(at(removal), "", "Remove `fn`", diagnostic.Automatic)

    VisibilityModifier(removal:, word:, ..) ->
      base("visibility modifiers do not exist")
      |> diagnostic.primary(here, "`" <> word <> "` is not a Pooka keyword")
      |> diagnostic.conclusion(
        "Ordinary names are public, and a leading `_` makes a declaration private.",
      )
      |> diagnostic.fix(
        at(removal),
        "",
        "Remove `" <> word <> "`",
        diagnostic.Automatic,
      )

    MutableClassField(keyword:) ->
      base("classes cannot contain mutable fields")
      |> diagnostic.primary(here, "`var` is not valid inside a class")
      |> diagnostic.conclusion(
        "Expected an immutable `let` field, but found `var`.",
      )
      |> diagnostic.note("Mutable state belongs in actors.")
      |> diagnostic.fix(
        at(keyword),
        "let",
        "Replace `var` with `let`",
        diagnostic.Suggested,
      )

    BehaviourOutsideActor(..) ->
      base("behaviours belong to actors")
      |> diagnostic.primary(here, "`be` is only valid inside an actor")
      |> diagnostic.conclusion(
        "A `be` behaviour is an asynchronous actor entry point.",
      )
      |> diagnostic.help("Remove `be` to declare an ordinary method.")

    MultipleInheritance(class_name:, first:, ..) ->
      base("multiple inheritance is not supported")
      |> diagnostic.primary(here, "a class can only extend one class")
      |> diagnostic.conclusion(
        "`" <> class_name <> "` already extends `" <> first <> "`.",
      )
      |> diagnostic.help(
        "Describe additional behaviour with interfaces, using `with`.",
      )

    SuperclassAfterInterfaces(..) ->
      base("superclass after interfaces")
      |> diagnostic.primary(here, "`is` must come before `with`")
      |> diagnostic.conclusion(
        "The order is always `class Name is Superclass with InterfaceA, InterfaceB`.",
      )

    InterfaceInheritance(..) ->
      base("interfaces cannot inherit")
      |> diagnostic.primary(here, "`is` is not allowed on an interface")
      |> diagnostic.conclusion(
        "Interfaces do not inherit from other interfaces.",
      )
      |> diagnostic.help(
        "Let types implement several interfaces instead: `with A, B`.",
      )

    ActorInheritance(..) ->
      base("actors cannot inherit")
      |> diagnostic.primary(here, "`is` is not allowed on an actor")
      |> diagnostic.conclusion(
        "Actors do not participate in class inheritance.",
      )
      |> diagnostic.help("Actors may implement interfaces with `with`.")

    InterfaceMethodBody(..) ->
      base("interface methods cannot have bodies")
      |> diagnostic.primary(here, "this body is not allowed")
      |> diagnostic.conclusion("Interfaces contain method signatures only.")
      |> diagnostic.note(
        "Shared behaviour belongs in ordinary functions or classes.",
      )

    InterfaceField(..) ->
      base("interfaces cannot contain fields")
      |> diagnostic.primary(here, "fields are not allowed in an interface")
      |> diagnostic.conclusion("Interfaces define behaviour without storage.")

    InterfaceConstructor(..) ->
      base("interfaces cannot have constructors")
      |> diagnostic.primary(here, "`new` is not allowed in an interface")
      |> diagnostic.conclusion("Interfaces contain method signatures only.")

    InterfaceBehaviour(..) ->
      base("interface requirements cannot be behaviours")
      |> diagnostic.primary(here, "`be` is not allowed in an interface")
      |> diagnostic.conclusion(
        "Interface methods are synchronous; a `be` behaviour cannot satisfy them.",
      )

    ExternalWithBody(..) ->
      base("external functions have no body")
      |> diagnostic.primary(here, "this body is not allowed")
      |> diagnostic.conclusion(
        "An external signature describes a function implemented in another BEAM language.",
      )

    ExternalWithoutNamespace(..) ->
      base("external declarations name a namespace")
      |> diagnostic.primary(here, "expected a namespace name such as `Crypto`")
      |> diagnostic.conclusion(
        "Foreign functions are grouped under a namespace that names their language and module.",
      )
      |> diagnostic.help(
        "Write `external Crypto from erlang \"crypto\" { strong_rand_bytes(size: Int) -> BitArray }`.",
      )

    UnsupportedForeignLanguage(word:, ..) -> {
      let names = foreign_language.names()
      let quoted = list.map(names, fn(name) { "`" <> name <> "`" })
      let described =
        base("unsupported foreign language")
        |> diagnostic.primary(
          here,
          "`" <> word <> "` is not a supported language",
        )
        |> diagnostic.conclusion(
          "The supported languages are " <> list_words(quoted) <> ".",
        )
      case text.closest(word, names) {
        Some(suggestion) ->
          described
          |> diagnostic.help("Did you mean `" <> suggestion <> "`?")
          |> diagnostic.fix(
            here,
            suggestion,
            "Use `" <> suggestion <> "`",
            diagnostic.Suggested,
          )
        None ->
          described
          |> diagnostic.note(
            "Modules written in any other BEAM language can be called with `erlang` and their module atom.",
          )
          |> diagnostic.note(
            "Native code is declared with `native Name from \"component\" { ... }`.",
          )
      }
    }

    EmptyForeignModule(..) ->
      base("empty foreign module name")
      |> diagnostic.primary(here, "the module name is empty")
      |> diagnostic.conclusion(
        "Name the foreign module, such as `\"crypto\"` or `\"Formatter\"`.",
      )

    EnumVariantData(name:, ..) ->
      base("enum variants carry no data")
      |> diagnostic.primary(here, "`" <> name <> "` cannot hold values")
      |> diagnostic.conclusion(
        "An enum variant is a single named value. When alternatives need different data, use a closed class hierarchy instead.",
      )
      |> diagnostic.help(
        "Write `class "
        <> name
        <> "(...) is Base` for each alternative that carries data.",
      )

    EnumTypeParameters(name:, ..) ->
      base("enums cannot be generic")
      |> diagnostic.primary(here, "type parameters are not allowed here")
      |> diagnostic.conclusion(
        "`"
        <> name
        <> "` is an enum: its variants carry no data, so it has nothing to be generic over.",
      )

    EnumInheritance(name:, ..) ->
      base("enums cannot inherit")
      |> diagnostic.primary(here, "enums have no superclass or interfaces")
      |> diagnostic.conclusion(
        "`"
        <> name
        <> "` is an enum: a closed set of values. It cannot extend a class or implement an interface.",
      )

    EnumMember(name:, ..) ->
      base("enums contain only variants")
      |> diagnostic.primary(here, "expected a variant name")
      |> diagnostic.conclusion(
        "The body of `"
        <> name
        <> "` may only list variant names, such as `Error`. Enums have no fields, constructors or methods.",
      )
      |> diagnostic.help(
        "Write functions that take the enum as a parameter, or use a class.",
      )

    EmptyEnum(enum_name:, ..) ->
      base("empty enum")
      |> diagnostic.primary(here, "this enum has no variants")
      |> diagnostic.conclusion(
        "`"
        <> enum_name
        <> "` has no values, so no value of it could ever exist.",
      )
      |> diagnostic.help("List at least one variant, such as `Error`.")

    EnumPatternArguments(enum_name:, variant:, ..) ->
      base("enum patterns take no arguments")
      |> diagnostic.primary(here, "remove these parentheses")
      |> diagnostic.conclusion(
        "`"
        <> enum_name
        <> "."
        <> variant
        <> "` is a value, not a constructor, so it is matched as written.",
      )
      |> diagnostic.fix(
        here,
        "",
        "Remove the parentheses",
        diagnostic.Automatic,
      )

    PatternAlternatives(..) ->
      base("patterns cannot be combined with `|`")
      |> diagnostic.primary(here, "Pooka has no pattern alternatives")
      |> diagnostic.conclusion(
        "Write a separate match branch for each pattern. In expressions, `|` is bitwise OR.",
      )

    ConciseFieldType(name:, ..) ->
      base("concise class fields need a type")
      |> diagnostic.primary(here, "`" <> name <> "` has no type")
      |> diagnostic.conclusion(
        "Each field of a concise class becomes an immutable field, so it is written `name: Type`.",
      )

    ConciseConstructor(class_name:, ..) ->
      base("concise classes cannot declare `new`")
      |> diagnostic.primary(
        here,
        "the constructor is generated from the fields",
      )
      |> diagnostic.conclusion(
        "`"
        <> class_name
        <> "` declares its fields after its name, so Pooka generates a constructor that assigns them. Custom construction needs the full class form.",
      )
      |> diagnostic.help(
        "Declare the fields with `let` in the body and write `new` yourself.",
      )

    InvalidNativeComponent(name:, ..) ->
      base("invalid native component name")
      |> diagnostic.primary(here, case name {
        "" -> "the component name is empty"
        _ -> "`" <> name <> "` is not lowercase snake_case"
      })
      |> diagnostic.conclusion(
        "A native component is named like its directory under `native/` and its `[native.<name>]` table in the pooka.toml: lowercase letters, digits and `_`, starting with a letter.",
      )

    CallableColonReturn(colon:) ->
      base("return types use `->`")
      |> diagnostic.primary(here, "expected `->` before the return type")
      |> diagnostic.conclusion(
        "Functions, methods and interface requirements use `name(parameter: Type) -> Result`.",
      )
      |> diagnostic.fix(at(colon), " ->", "Use `->`", diagnostic.Automatic)

    ExternalColonReturn(colon:) ->
      base("external signatures use `->`")
      |> diagnostic.primary(here, "expected `->` before the result type")
      |> diagnostic.conclusion(
        "External signatures are written `name(parameter: Type) -> Result`.",
      )
      |> diagnostic.fix(at(colon), " ->", "Use `->`", diagnostic.Automatic)

    ExternalMissingReturnType(..) ->
      base("missing result type")
      |> diagnostic.primary(here, "this signature has no result type")
      |> diagnostic.conclusion(
        "External signatures need a result type because there is no body to infer it from.",
      )
      |> diagnostic.help(
        "Add `-> Type` after the parameters, such as `-> Nil`.",
      )

    RequirementParameterType(name:, ..) ->
      base("missing parameter type")
      |> diagnostic.primary(here, "`" <> name <> "` has no type")
      |> diagnostic.conclusion(
        "Every parameter of an interface requirement needs a type, because implementations may be checked in other modules.",
      )
      |> diagnostic.help("Write `" <> name <> ": Type`.")

    RequirementMissingReturnType(name:, ..) ->
      base("missing result type")
      |> diagnostic.primary(here, "`" <> name <> "` has no result type")
      |> diagnostic.conclusion(
        "An interface requirement states its full signature, because implementations may be checked in other modules.",
      )
      |> diagnostic.help(
        "Add `-> Type` after the parameters, such as `-> Nil`.",
      )

    ExternalParameterType(name:, ..) ->
      base("missing parameter type")
      |> diagnostic.primary(here, "`" <> name <> "` has no type")
      |> diagnostic.conclusion(
        "Every parameter of an external signature needs a type.",
      )
      |> diagnostic.help("Write `" <> name <> ": Type`.")

    UnsupportedKeyword(keyword:, ..) -> unsupported_keyword(base, here, keyword)

    IfOutsideGuard(..) ->
      base("`if` is only used in match guards")
      |> diagnostic.primary(here, "`if` cannot start an expression")
      |> diagnostic.conclusion(
        "Pooka has no `if` expression; conditional branching uses `match`.",
      )
      |> diagnostic.help(
        "Write `match condition { True -> ... False -> ... }`.",
      )

    InvalidAssignmentTarget(..) ->
      base("invalid assignment target")
      |> diagnostic.primary(here, "this cannot be assigned to")
      |> diagnostic.conclusion(
        "Only actor state, such as `count`, and fields, such as `self.name`, can be assigned.",
      )
      |> diagnostic.note("Local bindings in Pooka are immutable.")
  }
}

fn unsupported_keyword(
  base: fn(String) -> Diagnostic,
  here: Location,
  keyword: MissingKeyword,
) -> Diagnostic {
  let #(word, conclusion, help) = case keyword {
    Return -> #(
      "return",
      "Functions evaluate to their final expression.",
      "Remove `return` and make the value the last expression of the block.",
    )
    While -> #(
      "while",
      "Repetition uses `loop`.",
      "Write `loop { ... }` and leave it with `break`.",
    )
    For -> #(
      "for",
      "Repetition uses `loop`.",
      "Write `loop item in items { ... }`.",
    )
    Else -> #(
      "else",
      "Conditional branching uses `match`.",
      "Write `match condition { True -> ... False -> ... }`.",
    )
    Throw -> #(
      "throw",
      "Expected failure is represented with `Result`.",
      "Return an `Error(...)`, or use `panic` for states that should be impossible.",
    )
    Try -> #(
      "try",
      "Pooka has no exceptions.",
      "Handle a `Result` with `match`, or propagate it with `?`.",
    )
    Catch -> #(
      "catch",
      "Pooka has no exceptions.",
      "Handle a `Result` with `match`, or propagate it with `?`.",
    )
  }
  base("Pooka has no `" <> word <> "`")
  |> diagnostic.primary(here, "`" <> word <> "` is not a keyword")
  |> diagnostic.conclusion(conclusion)
  |> diagnostic.help(help)
}

fn unexpected_title(found: Token) -> String {
  case found {
    token.EndOfFile -> "unexpected end of file"
    token.String(_) -> "unexpected string"
    token.Name(name) | token.UpperName(name) ->
      "unexpected name `" <> name <> "`"
    token.Int(_) | token.Float(_) -> "unexpected number"
    _ -> "unexpected `" <> token.to_source(found) <> "`"
  }
}

fn expectation_label(expected: Expectation) -> String {
  case expected {
    ExpectExpression -> "an expression should begin here"
    ExpectPattern -> "a pattern should begin here"
    ExpectType -> "a type should begin here"
    ExpectDeclaration -> "a declaration should begin here"
    ExpectMember -> "a field, constructor or method should begin here"
    ExpectRequirement -> "a method signature should begin here"
    ExpectParameter -> "a parameter name should be here"
    ExpectName(what) | ExpectUpperName(what) -> what <> " should be here"
    ExpectModulePath -> "a module path should be here"
    ExpectImportedName -> "a name to import should be here"
    ExpectTestName -> "the test's description should be here"
    ExpectForeignModule -> "the foreign module name should be here, in quotes"
    ExpectNativeComponent ->
      "the native component name should be here, in quotes"
    ExpectExternalFunction -> "a function signature should begin here"
    ExpectEnumVariant -> "a variant name should be here"
    ExpectBitArrayOption -> "a segment option should be here"
    ExpectStatementEnd -> "this should start on a new line"
    ExpectToken(expected) ->
      "expected `" <> token.to_source(expected) <> "` here"
    ExpectOneOf(tokens) -> "expected " <> one_of(tokens) <> " here"
  }
}

fn describe_expectation(expected: Expectation) -> String {
  case expected {
    ExpectExpression -> "an expression"
    ExpectPattern -> "a pattern"
    ExpectType -> "a type"
    ExpectDeclaration ->
      "a declaration such as a function, class, interface, actor, external or test"
    ExpectMember -> "a field, constructor, method or `}`"
    ExpectRequirement -> "a method signature or `}`"
    ExpectParameter -> "a parameter name"
    ExpectName(what) | ExpectUpperName(what) -> what
    ExpectModulePath -> "a module path such as `http/client`"
    ExpectImportedName -> "a name to import"
    ExpectTestName -> "a string describing the test"
    ExpectForeignModule ->
      "a foreign module name in quotes, such as `\"crypto\"`"
    ExpectNativeComponent ->
      "a native component name in quotes, such as `\"hash\"`"
    ExpectExternalFunction ->
      "a function signature such as `name(value: Int) -> Int`, or `}`"
    ExpectEnumVariant -> "a variant name such as `Error`, or `}`"
    ExpectBitArrayOption -> "a segment option such as `bits` or `size(8)`"
    ExpectStatementEnd -> "the end of the statement"
    ExpectToken(expected) -> "`" <> token.to_source(expected) <> "`"
    ExpectOneOf(tokens) -> one_of(tokens)
  }
}

fn one_of(tokens: List(Token)) -> String {
  let quoted =
    list.map(tokens, fn(item) { "`" <> token.to_source(item) <> "`" })
  case list.reverse(quoted) {
    [] -> "something else"
    [only] -> only
    [last, ..rest] -> string.join(list.reverse(rest), ", ") <> " or " <> last
  }
}

fn delimited_label(context: Delimited) -> String {
  case context {
    ParameterList -> "parameter list is not closed"
    ArgumentList -> "argument list is not closed"
    ListLiteral -> "list is not closed"
    TupleLiteral -> "tuple is not closed"
    BitArrayLiteral -> "bit array is not closed"
    TypeArguments -> "type arguments are not closed"
    TypeParameters -> "type parameters are not closed"
    ImportList -> "import list is not closed"
    PatternArguments -> "pattern arguments are not closed"
    Grouping -> "parenthesis is not closed"
    BlockBody -> "this block is never closed"
    ClassBody -> "this class body is never closed"
    InterfaceBody -> "this interface body is never closed"
    ActorBody -> "this actor body is never closed"
    MatchBody -> "this match is never closed"
    ExternalBody -> "this external body is never closed"
    EnumBody -> "this enum body is never closed"
    ConciseFields -> "this field list is never closed"
  }
}

fn list_words(words: List(String)) -> String {
  case list.reverse(words) {
    [] -> ""
    [only] -> only
    [last, ..rest] -> string.join(list.reverse(rest), ", ") <> " and " <> last
  }
}
