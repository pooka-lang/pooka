//// Name the pieces before asking them to form a sentence.
////
//// Define the token vocabulary and its source/display spellings. Keywords, trivia
//// and punctuation share a representation used by parsing, formatting and
//// diagnostics.
////
//// ```text
//// |> -> Pipe; // note -> comment trivia
//// ```

// SPDX-License-Identifier: Apache-2.0

import utilities/location.{type Span}

pub type Token {

  Actor
  As
  Assert
  Be
  Break
  Class
  Continue
  External
  Fn
  If
  Import
  Interface
  Is
  Let
  Loop
  Match
  Module
  New
  Panic

  SelfKeyword
  Super
  Test
  Todo
  Var
  With

  TrueLiteral
  FalseLiteral
  NilLiteral

  EqualEqual

  BangEqual

  LessEqual

  GreaterEqual

  RightArrow

  Pipe

  DoubleAmpersand

  DoubleBar

  Ampersand

  Bar

  PlusEqual

  MinusEqual

  StarEqual

  DoubleLess

  DoubleGreater

  Plus

  Minus

  Star

  Slash

  Percent

  Equal

  Less

  Greater

  Bang

  Question

  LeftParen

  RightParen

  LeftBrace

  RightBrace

  LeftSquare

  RightSquare

  Comma

  Colon

  DotDot

  Dot

  HashLeftParen

  Name(String)

  UpperName(String)

  Underscore

  Int(String)

  Float(String)

  String(String)

  Comment(String)

  DocComment(String)

  ModuleComment(String)

  Unexpected(String)

  EndOfFile
}

pub type Lexeme {
  Lexeme(token: Token, span: Span)
}

pub const keywords = [
  "actor", "as", "assert", "be", "break", "class", "continue", "external", "fn",
  "if", "import", "interface", "is", "let", "loop", "match", "module", "new",
  "panic", "self", "super", "test", "todo", "var", "with", "True", "False",
  "Nil",
]

pub const missing_keywords = [
  "else", "while", "for", "return", "throw", "try", "catch",
]

pub fn keyword(word: String) -> Result(Token, Nil) {
  case word {
    "actor" -> Ok(Actor)
    "as" -> Ok(As)
    "assert" -> Ok(Assert)
    "be" -> Ok(Be)
    "break" -> Ok(Break)
    "class" -> Ok(Class)
    "continue" -> Ok(Continue)
    "external" -> Ok(External)
    "fn" -> Ok(Fn)
    "if" -> Ok(If)
    "import" -> Ok(Import)
    "interface" -> Ok(Interface)
    "is" -> Ok(Is)
    "let" -> Ok(Let)
    "loop" -> Ok(Loop)
    "match" -> Ok(Match)
    "module" -> Ok(Module)
    "new" -> Ok(New)
    "panic" -> Ok(Panic)
    "self" -> Ok(SelfKeyword)
    "super" -> Ok(Super)
    "test" -> Ok(Test)
    "todo" -> Ok(Todo)
    "var" -> Ok(Var)
    "with" -> Ok(With)
    "True" -> Ok(TrueLiteral)
    "False" -> Ok(FalseLiteral)
    "Nil" -> Ok(NilLiteral)
    _ -> Error(Nil)
  }
}

pub fn to_source(token: Token) -> String {
  case token {
    Actor -> "actor"
    As -> "as"
    Assert -> "assert"
    Be -> "be"
    Break -> "break"
    Class -> "class"
    Continue -> "continue"
    External -> "external"
    Fn -> "fn"
    If -> "if"
    Import -> "import"
    Interface -> "interface"
    Is -> "is"
    Let -> "let"
    Loop -> "loop"
    Match -> "match"
    Module -> "module"
    New -> "new"
    Panic -> "panic"
    SelfKeyword -> "self"
    Super -> "super"
    Test -> "test"
    Todo -> "todo"
    Var -> "var"
    With -> "with"
    TrueLiteral -> "True"
    FalseLiteral -> "False"
    NilLiteral -> "Nil"
    EqualEqual -> "=="
    BangEqual -> "!="
    LessEqual -> "<="
    GreaterEqual -> ">="
    RightArrow -> "->"
    Pipe -> "|>"
    DoubleAmpersand -> "&&"
    DoubleBar -> "||"
    Ampersand -> "&"
    Bar -> "|"
    PlusEqual -> "+="
    MinusEqual -> "-="
    StarEqual -> "*="
    DoubleLess -> "<<"
    DoubleGreater -> ">>"
    Plus -> "+"
    Minus -> "-"
    Star -> "*"
    Slash -> "/"
    Percent -> "%"
    Equal -> "="
    Less -> "<"
    Greater -> ">"
    Bang -> "!"
    Question -> "?"
    LeftParen -> "("
    RightParen -> ")"
    LeftBrace -> "{"
    RightBrace -> "}"
    LeftSquare -> "["
    RightSquare -> "]"
    Comma -> ","
    Colon -> ":"
    DotDot -> ".."
    Dot -> "."
    HashLeftParen -> "#("
    Name(name) -> name
    UpperName(name) -> name
    Underscore -> "_"
    Int(text) -> text
    Float(text) -> text
    String(text) -> "\"" <> text <> "\""
    Comment(text) -> "//" <> text
    DocComment(text) -> "///" <> text
    ModuleComment(text) -> "////" <> text
    Unexpected(text) -> text
    EndOfFile -> ""
  }
}

pub fn describe(token: Token) -> String {
  case token {
    Name(name) -> "the name `" <> name <> "`"
    UpperName(name) -> "the name `" <> name <> "`"
    Int(text) -> "the number `" <> text <> "`"
    Float(text) -> "the number `" <> text <> "`"
    String(_) -> "a string"
    Comment(_) -> "a comment"
    DocComment(_) -> "a documentation comment"
    ModuleComment(_) -> "a module documentation comment"
    EndOfFile -> "the end of the file"
    Unexpected(text) -> "`" <> text <> "`"
    _ -> "`" <> to_source(token) <> "`"
  }
}

pub fn is_keyword(token: Token) -> Bool {
  case token {
    Actor
    | As
    | Assert
    | Be
    | Break
    | Class
    | Continue
    | External
    | Fn
    | If
    | Import
    | Interface
    | Is
    | Let
    | Loop
    | Match
    | Module
    | New
    | Panic
    | SelfKeyword
    | Super
    | Test
    | Todo
    | Var
    | With
    | TrueLiteral
    | FalseLiteral
    | NilLiteral -> True
    _ -> False
  }
}

pub fn is_trivia(token: Token) -> Bool {
  case token {
    Comment(_) -> True
    _ -> False
  }
}
