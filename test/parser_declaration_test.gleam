//// Put the title on the book before filling its chapters.
////
//// Inspect module headers, imports and top-level declarations as syntax trees.
//// Documentation belongs to the next declaration, private names retain their
//// spelling, and class, actor, interface and foreign signatures keep distinct
//// AST forms.
////
//// ```pooka
//// module main
//// /// The answer.
//// answer() -> Int { 42 }
//// ```

import compiler/compiler
import compiler/parser/ast
import gleam/list
import gleam/option.{None, Some}
import support

pub fn module_header_test() {
  let module = support.parse("module pool\n")
  let assert Some(ast.ModuleHeader(name: ast.Name("pool", _), ..)) =
    module.header
}

pub fn module_header_with_directories_test() {
  let source = "module database/pool\n"
  let module = support.parse_module_with_errors(source)
  let assert Some(ast.ModuleHeader(name: ast.Name("pool", span), ..)) =
    module.header
  assert support.text_at(source, span) == "pool"
  let checked = compiler.check_source("src/database/pool.pooka", source)
  assert list.map(checked.diagnostics, fn(d) { d.id })
    == ["parse.module_header_path"]
}

pub fn module_documentation_test() {
  let module =
    support.parse(
      "//// HTTP client functionality.\n////\n//// Provides types.\n\nmodule client\n",
    )
  assert module.documentation
    == [" HTTP client functionality.", "", " Provides types."]
}

pub fn plain_import_test() {
  let module = support.parse("module main\n\nimport http/client\n")
  let assert [
    ast.Import(
      module: ast.ModulePath(segments:, ..),
      items: [],
      alias: None,
      ..,
    ),
  ] = module.imports
  assert segments == ["http", "client"]
}

pub fn aliased_import_test() {
  let module = support.parse("module main\n\nimport user as users\n")
  let assert [ast.Import(alias: Some(ast.Name("users", _)), ..)] =
    module.imports
}

pub fn selective_import_test() {
  let module =
    support.parse(
      "module main\n\nimport user.{User, Admin as A, load, save as store,}\n",
    )
  let assert [ast.Import(items:, ..)] = module.imports
  let names =
    list.map(items, fn(item) {
      #(item.name.name, option.map(item.alias, fn(alias) { alias.name }))
    })
  assert names
    == [
      #("User", None),
      #("Admin", Some("A")),
      #("load", None),
      #("save", Some("store")),
    ]
}

pub fn declarations_keep_their_order_test() {
  let module =
    support.parse(
      "module main\n\nclass A {}\ninterface B {}\nactor C {}\nexternal D from erlang \"d\" {}\ntest \"e\" {}\nf() {}\n",
    )
  let kinds =
    list.map(module.declarations, fn(declaration) {
      case declaration {
        ast.ClassDeclaration(_) -> "class"
        ast.InterfaceDeclaration(_) -> "interface"
        ast.ActorDeclaration(_) -> "actor"
        ast.EnumDeclaration(_) -> "enum"
        ast.ExternalDeclaration(_) -> "external"
        ast.TestDeclaration(_) -> "test"
        ast.FunctionDeclaration(_) -> "function"
      }
    })
  assert kinds
    == ["class", "interface", "actor", "external", "test", "function"]
}

pub fn function_test() {
  let module =
    support.parse("module main\n\nadd(a: Int, b: Int) -> Int {\n  a + b\n}\n")
  let assert [
    ast.FunctionDeclaration(ast.Function(
      name: ast.Name("add", _),
      parameters: [
        ast.Parameter(
          name: ast.NamedParameter("a"),
          annotation: Some(ast.NamedType(name: "Int", ..)),
          ..,
        ),
        ast.Parameter(name: ast.NamedParameter("b"), ..),
      ],
      return_type: Some(ast.NamedType(name: "Int", ..)),
      body: ast.Block(statements: [_], ..),
      ..,
    )),
  ] = module.declarations
}

pub fn inferred_types_test() {
  let module =
    support.parse("module main\n\nfirst_or(items, fallback) {\n  fallback\n}\n")
  let assert [
    ast.FunctionDeclaration(ast.Function(
      parameters: [
        ast.Parameter(annotation: None, ..),
        ast.Parameter(annotation: None, ..),
      ],
      return_type: None,
      ..,
    )),
  ] = module.declarations
}

pub fn private_function_test() {
  let module = support.parse("module parser\n\n_helper() {}\n")
  let assert [
    ast.FunctionDeclaration(ast.Function(name: ast.Name("_helper", _), ..)),
  ] = module.declarations
}

pub fn trailing_comma_in_parameters_test() {
  let module = support.parse("module main\n\nf(\n  a,\n  b,\n) {}\n")
  let assert [ast.FunctionDeclaration(ast.Function(parameters: [_, _], ..))] =
    module.declarations
}

pub fn discarded_parameter_test() {
  let module = support.parse("module main\n\nf(_, _unused) {}\n")
  let assert [
    ast.FunctionDeclaration(ast.Function(
      parameters: [
        ast.Parameter(name: ast.DiscardedParameter, ..),
        ast.Parameter(name: ast.NamedParameter("_unused"), ..),
      ],
      ..,
    )),
  ] = module.declarations
}

// Keep a comment with the declaration it introduces. Whitespace and the
// previous declaration must not claim documentation intended for the next
// one.
pub fn documentation_attaches_to_the_next_declaration_test() {
  let module =
    support.parse(
      "module main\n\n/// Returns the sum.\n///\n/// Of two integers.\nadd(a, b) { a + b }\n",
    )
  let assert [ast.FunctionDeclaration(ast.Function(documentation:, ..))] =
    module.declarations
  assert documentation == [" Returns the sum.", "", " Of two integers."]
}

pub fn class_with_fields_constructor_and_method_test() {
  let module =
    support.parse(
      "module user\n\nclass User {\n  let name: String\n  let age: Int\n\n  new(name, age) {\n    self.name = name\n    self.age = age\n  }\n\n  greet() {\n    \"Hello, \" + name\n  }\n}\n",
    )
  let assert [
    ast.ClassDeclaration(ast.Class(
      name: ast.Name("User", _),
      type_parameters: [],
      superclass: None,
      interfaces: [],
      members: [
        ast.FieldMember(ast.Field(
          mutability: ast.Immutable,
          name: ast.Name("name", _),
          annotation: Some(ast.NamedType(name: "String", ..)),
          value: None,
          ..,
        )),
        ast.FieldMember(ast.Field(name: ast.Name("age", _), ..)),
        ast.ConstructorMember(ast.Constructor(
          parameters: [_, _],
          body: ast.Block(statements: [_, _], ..),
          ..,
        )),
        ast.MethodMember(ast.Function(name: ast.Name("greet", _), ..)),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn generic_class_test() {
  let module =
    support.parse("module box\n\nclass Box(a) {\n  let value: a\n}\n")
  let assert [
    ast.ClassDeclaration(ast.Class(
      type_parameters: [ast.Name("a", _)],
      members: [
        ast.FieldMember(ast.Field(
          annotation: Some(ast.TypeVariable("a", _)),
          ..,
        )),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn inheritance_and_interfaces_test() {
  let module =
    support.parse(
      "module animal\n\nclass Dog is Animal with Printable, Serializable {}\n",
    )
  let assert [
    ast.ClassDeclaration(ast.Class(
      superclass: Some(ast.NamedType(name: "Animal", ..)),
      interfaces: [
        ast.NamedType(name: "Printable", ..),
        ast.NamedType(name: "Serializable", ..),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn generic_superclass_test() {
  let module =
    support.parse(
      "module result\n\nclass Ok(a, e) is Result(a, e) {\n  let value: a\n}\n",
    )
  let assert [
    ast.ClassDeclaration(ast.Class(
      type_parameters: [ast.Name("a", _), ast.Name("e", _)],
      superclass: Some(ast.NamedType(
        name: "Result",
        arguments: [ast.TypeVariable("a", _), ast.TypeVariable("e", _)],
        ..,
      )),
      ..,
    )),
  ] = module.declarations
}

pub fn empty_class_test() {
  let module = support.parse("module shape\n\nclass Shape {}\n")
  let assert [ast.ClassDeclaration(ast.Class(members: [], ..))] =
    module.declarations
}

pub fn documented_members_test() {
  let module =
    support.parse(
      "module user\n\nclass User {\n  /// The display name.\n  let name: String\n\n  /// Greets.\n  greet() { name }\n}\n",
    )
  let assert [
    ast.ClassDeclaration(ast.Class(
      members: [
        ast.FieldMember(ast.Field(documentation: [" The display name."], ..)),
        ast.MethodMember(ast.Function(documentation: [" Greets."], ..)),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn interface_test() {
  let module =
    support.parse(
      "module iterator\n\ninterface Iterator(a) {\n  next() -> Option(a)\n  reset() -> Nil\n}\n",
    )
  let assert [
    ast.InterfaceDeclaration(ast.Interface(
      name: ast.Name("Iterator", _),
      type_parameters: [ast.Name("a", _)],
      requirements: [
        ast.Requirement(
          name: ast.Name("next", _),
          parameters: [],
          return_type: Some(ast.NamedType(
            name: "Option",
            arguments: [ast.TypeVariable("a", _)],
            ..,
          )),
          ..,
        ),
        ast.Requirement(
          name: ast.Name("reset", _),
          return_type: Some(ast.NamedType(name: "Nil", ..)),
          ..,
        ),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn one_line_interface_test() {
  let module =
    support.parse("module api\n\ninterface Printable { print() -> String }\n")
  let assert [ast.InterfaceDeclaration(ast.Interface(requirements: [_], ..))] =
    module.declarations
}

pub fn actor_test() {
  let module =
    support.parse(
      "module counter\n\nactor Counter with Resettable {\n  var count = 0\n\n  be increment() {\n    count += 1\n  }\n\n  value() -> Int { count }\n}\n",
    )
  let assert [
    ast.ActorDeclaration(ast.Actor(
      name: ast.Name("Counter", _),
      interfaces: [ast.NamedType(name: "Resettable", ..)],
      members: [
        ast.FieldMember(ast.Field(
          mutability: ast.Mutable,
          value: Some(ast.IntLiteral("0", _)),
          ..,
        )),
        ast.BehaviourMember(ast.Function(name: ast.Name("increment", _), ..)),
        ast.MethodMember(ast.Function(
          name: ast.Name("value", _),
          return_type: Some(ast.NamedType(name: "Int", ..)),
          ..,
        )),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn actor_with_constructor_test() {
  let module =
    support.parse(
      "module worker\n\nactor Worker {\n  let name: String\n  var jobs_completed: Int\n\n  new(name) {\n    self.name = name\n    self.jobs_completed = 0\n  }\n}\n",
    )
  let assert [
    ast.ActorDeclaration(ast.Actor(
      members: [
        ast.FieldMember(ast.Field(mutability: ast.Immutable, ..)),
        ast.FieldMember(ast.Field(mutability: ast.Mutable, value: None, ..)),
        ast.ConstructorMember(_),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn external_test() {
  let module =
    support.parse(
      "module native\n\nexternal Crypto from erlang \"crypto\" {\n  strong_rand_bytes(size: Int) -> BitArray\n}\n",
    )
  let assert [
    ast.ExternalDeclaration(ast.External(
      name: ast.Name("Crypto", _),
      language: ast.Erlang,
      module: "crypto",
      functions: [
        ast.ExternalFunction(
          name: ast.Name("strong_rand_bytes", _),
          parameters: [
            ast.Parameter(
              name: ast.NamedParameter("size"),
              annotation: Some(ast.NamedType(name: "Int", ..)),
              ..,
            ),
          ],
          return_type: ast.NamedType(name: "BitArray", ..),
          ..,
        ),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn elixir_external_with_several_functions_test() {
  let module =
    support.parse(
      "module native\n\n/// Formatting helpers.\nexternal Formatter from elixir \"Formatter\" {\n  /// Doubles a number.\n  double(n: Int) -> Int\n  square(n: Int) -> Int\n}\n",
    )
  let assert [
    ast.ExternalDeclaration(ast.External(
      documentation: [" Formatting helpers."],
      language: ast.Elixir,
      module: "Formatter",
      functions: [
        ast.ExternalFunction(
          documentation: [" Doubles a number."],
          name: ast.Name("double", _),
          ..,
        ),
        ast.ExternalFunction(name: ast.Name("square", _), ..),
      ],
      ..,
    )),
  ] = module.declarations
}

pub fn external_generic_and_function_types_test() {
  let module =
    support.parse(
      "module native\n\nexternal Lists from erlang \"lists\" {\n  reverse(items: List(a)) -> List(a)\n  map(f: fn(a) -> b, items: List(a)) -> List(b)\n  empty() -> Nil\n}\n",
    )
  let assert [
    ast.ExternalDeclaration(ast.External(functions: [_, _, empty], ..)),
  ] = module.declarations
  let assert ast.ExternalFunction(
    parameters: [],
    return_type: ast.NamedType(name: "Nil", ..),
    ..,
  ) = empty
}

pub fn from_and_language_names_are_not_reserved_test() {
  let assert [ast.FunctionDeclaration(_)] =
    support.parse("module main\n\nf(from, erlang, elixir) { from }\n").declarations
}

pub fn namespace_calls_are_field_access_calls_test() {
  let assert ast.Call(
    ast.FieldAccess(
      ast.TypeName("Crypto", _),
      ast.Name("strong_rand_bytes", _),
      _,
    ),
    [ast.IntLiteral("32", _)],
    _,
  ) = support.expression("Crypto.strong_rand_bytes(32)")
}

pub fn test_declaration_test() {
  let module =
    support.parse(
      "module user\n\ntest \"user creation\" {\n  assert 1 == 1\n}\n",
    )
  let assert [
    ast.TestDeclaration(ast.Test(
      name: "user creation",
      body: ast.Block(statements: [_], ..),
      ..,
    )),
  ] = module.declarations
}
