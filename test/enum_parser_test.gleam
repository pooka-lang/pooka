//// A handful of names makes a closed little family.
////
//// Inspect enum declarations and qualified variant patterns before semantic
//// checking. Separators, documentation and spans must survive parsing, while
//// malformed variants receive local errors and useful recovery. An enum name
//// and a variant name occupy different positions in the syntax.
////
//// ```pooka
//// enum Light { Red, Amber, Green }
//// ```

import birdie
import compiler/compiler
import compiler/parser/ast
import compiler/parser/parse_error
import diagnostics/diagnostic
import diagnostics/fix
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support

/// Require the fixture to contain the enum declaration shape this suite is
/// inspecting. Parser recovery tests below use their own explicit error
/// assertions.
fn enum(source: String) -> ast.Enum {
  let module = support.parse("module main\n" <> source)
  let assert [ast.EnumDeclaration(value)] = module.declarations
  value
}

fn variants(source: String) -> List(String) {
  enum(source).variants |> list.map(fn(variant) { variant.name.name })
}

fn ids(body: String) -> List(String) {
  support.diagnostic_ids("module main\n" <> body)
}

fn pattern(source: String) -> ast.Pattern {
  let assert [ast.ExpressionStatement(ast.Match(branches: [branch, ..], ..))] =
    support.parse_body("match value {\n" <> source <> " -> 1\n_ -> 2\n}")
  branch.pattern
}

// A newline can separate variants without a comma. Keep this declaration
// structure distinct from expression statements that happen to contain upper-
// case names.
pub fn variants_on_separate_lines_test() {
  assert variants("enum Severity {\n  Error\n  Warning\n  Notice\n}\n")
    == ["Error", "Warning", "Notice"]
}

pub fn variants_separated_by_commas_test() {
  assert variants("enum Direction { North, South, East, West }\n")
    == ["North", "South", "East", "West"]
}

pub fn trailing_comma_is_allowed_test() {
  assert variants("enum Light { Red, Amber, Green, }\n")
    == ["Red", "Amber", "Green"]
}

pub fn several_variants_per_line_without_commas_test() {
  assert variants("enum Light { Red Amber Green }\n")
    == ["Red", "Amber", "Green"]
}

pub fn a_single_variant_is_enough_test() {
  assert variants("enum Unit { Only }\n") == ["Only"]
}

pub fn variant_names_may_match_type_names_test() {
  assert variants("enum Kind { Int, Float, String, Nil_ }\n")
    == ["Int", "Float", "String", "Nil_"]
}

pub fn the_enum_name_and_span_test() {
  let source = "module main\nenum Colour { Red }\n"
  let module = support.parse(source)
  let assert [ast.EnumDeclaration(value)] = module.declarations
  assert value.name.name == "Colour"
  assert support.text_at(source, value.name.span) == "Colour"
  assert support.text_at(source, value.span) == "enum Colour { Red }"
}

pub fn variant_spans_cover_their_names_test() {
  let source = "module main\nenum Colour {\n  Red\n  Blue\n}\n"
  let module = support.parse(source)
  let assert [ast.EnumDeclaration(value)] = module.declarations
  let assert [red, blue] = value.variants
  assert support.text_at(source, red.name.span) == "Red"
  assert support.text_at(source, blue.name.span) == "Blue"
  assert blue.name.span.start.line == 4
}

pub fn documentation_of_the_enum_and_its_variants_test() {
  let value =
    enum(
      "/// How serious it is.\nenum Severity {\n  /// Cannot compile.\n  Error\n  Warning\n  /// Just so you know.\n  Notice\n}\n",
    )
  assert value.documentation == [" How serious it is."]
  assert list.map(value.variants, fn(variant) { variant.documentation })
    == [[" Cannot compile."], [], [" Just so you know."]]
}

pub fn private_enums_parse_test() {
  assert enum("enum _Internal { A }\n").name.name == "_Internal"
}

pub fn comments_between_variants_are_ignored_test() {
  assert variants("enum Light {\n  Red // stop\n  // between\n  Green\n}\n")
    == ["Red", "Green"]
}

pub fn enums_sit_among_other_declarations_test() {
  let module =
    support.parse(
      "module main\nclass A {}\nenum B { X }\nmain() { 1 }\nenum C { Y }\n",
    )
  let kinds =
    list.map(module.declarations, fn(declaration) {
      case declaration {
        ast.EnumDeclaration(value) -> "enum " <> value.name.name
        ast.ClassDeclaration(value) -> "class " <> value.name.name
        ast.FunctionDeclaration(value) -> "function " <> value.name.name
        _ -> "other"
      }
    })
  assert kinds == ["class A", "enum B", "function main", "enum C"]
}

pub fn declaration_name_is_the_enum_name_test() {
  let module = support.parse("module main\nenum Colour { Red }\n")
  let assert [declaration] = module.declarations
  let assert Ok(ast.Name("Colour", _)) = ast.declaration_name(declaration)
}

pub fn enum_is_an_ordinary_parameter_name_test() {
  assert ids("count(enum: Int) -> Int { enum + 1 }\n") == []
}

pub fn enum_is_an_ordinary_local_name_test() {
  assert ids("main() {\n  let enum = 3\n  enum\n}\n") == []
}

pub fn enum_is_an_ordinary_function_name_test() {
  let module = support.parse("module main\nenum() { 1 }\n")
  let assert [ast.FunctionDeclaration(function)] = module.declarations
  assert function.name.name == "enum"
}

pub fn enum_is_an_ordinary_module_name_test() {
  let module = support.parse("module main\nimport enum\n")
  let assert [ast.Import(module: ast.ModulePath(segments: ["enum"], ..), ..)] =
    module.imports
}

pub fn enum_inside_a_function_is_not_a_declaration_test() {
  assert ids("main() {\n  enum Colour { Red }\n}\n") != []
}

pub fn variant_data_is_reported_test() {
  assert ids("enum Outcome {\n  Done(Int)\n  Pending\n}\n")
    == ["parse.enum_variant_data"]
}

pub fn variant_data_is_skipped_but_the_variant_kept_test() {
  let module =
    support.parse_module_with_errors(
      "module main\nenum Outcome {\n  Done(Int, List(String))\n  Pending\n}\n",
    )
  let assert [ast.EnumDeclaration(value)] = module.declarations
  assert list.map(value.variants, fn(variant) { variant.name.name })
    == ["Done", "Pending"]
}

pub fn variant_data_span_covers_the_parentheses_test() {
  let source = "module main\nenum Outcome {\n  Done(Int, (String))\n}\n"
  let assert [parse_error.EnumVariantData(variant: span, name: "Done")] =
    support.parse_errors(source)
  assert support.text_at(source, span) == "Done(Int, (String))"
}

pub fn type_parameters_are_reported_test() {
  assert ids("enum Wrapper(a) {\n  Empty\n}\n")
    == ["parse.enum_type_parameters"]
}

pub fn type_parameters_span_test() {
  let source = "module main\nenum Pair(a, b) { One }\n"
  let assert [parse_error.EnumTypeParameters(parameters: span, name: "Pair")] =
    support.parse_errors(source)
  assert support.text_at(source, span) == "(a, b)"
}

pub fn superclass_is_reported_test() {
  assert ids("enum Level is Severity {\n  High\n}\n")
    == ["parse.enum_inheritance"]
}

pub fn interfaces_are_reported_test() {
  assert ids("enum Level with Show {\n  High\n}\n")
    == ["parse.enum_inheritance"]
}

pub fn superclass_and_interfaces_are_reported_separately_test() {
  let source = "module main\nenum Level is Base with Show, Eq { High }\n"
  let spans =
    support.parse_errors(source)
    |> list.map(fn(error) {
      let assert parse_error.EnumInheritance(clause:, name: "Level") = error
      support.text_at(source, clause)
    })
  assert list.sort(spans, string.compare) == ["is Base", "with Show, Eq"]
}

pub fn a_method_is_reported_test() {
  assert ids("enum Level {\n  High\n  describe() { \"level\" }\n}\n")
    == ["parse.enum_member"]
}

pub fn a_field_is_reported_test() {
  assert ids("enum Level {\n  High\n  let x = 1\n}\n") == ["parse.enum_member"]
}

pub fn a_constructor_is_reported_test() {
  assert ids("enum Level {\n  new() { 1 }\n  High\n}\n")
    == ["parse.enum_member"]
}

pub fn a_lower_case_variant_is_reported_test() {
  assert ids("enum Level {\n  high\n  Low\n}\n") == ["parse.enum_member"]
}

pub fn a_comma_ends_an_invalid_member_test() {
  let module =
    support.parse_module_with_errors("module main\nenum Level { low, High }\n")
  let assert [ast.EnumDeclaration(value)] = module.declarations
  assert list.map(value.variants, fn(variant) { variant.name.name }) == ["High"]
}

pub fn each_invalid_line_is_reported_once_test() {
  assert ids("enum Level {\n  let x = 1\n  let y = 2\n  High\n}\n")
    == ["parse.enum_member", "parse.enum_member"]
}

pub fn members_are_skipped_up_to_the_next_variant_line_test() {
  let module =
    support.parse_module_with_errors(
      "module main\nenum Level {\n  High\n  describe() {\n    Nested(1)\n  }\n  Low\n}\nmain() { 1 }\n",
    )
  let assert [ast.EnumDeclaration(value), ast.FunctionDeclaration(_)] =
    module.declarations
  assert list.map(value.variants, fn(variant) { variant.name.name })
    == ["High", "Low"]
}

pub fn member_span_covers_the_whole_member_test() {
  let source = "module main\nenum Level {\n  let x = Some(1)\n  High\n}\n"
  let assert [parse_error.EnumMember(member: span, name: "Level")] =
    support.parse_errors(source)
  assert support.text_at(source, span) == "let x = Some(1)"
}

pub fn an_empty_enum_is_reported_test() {
  assert ids("enum Nothing {}\n") == ["parse.empty_enum"]
}

pub fn an_enum_with_only_invalid_members_is_also_empty_test() {
  assert list.sort(ids("enum Nothing {\n  let x = 1\n}\n"), string.compare)
    == ["parse.empty_enum", "parse.enum_member"]
}

pub fn a_missing_name_is_reported_test() {
  assert ids("enum { Red }\n") != []
}

pub fn an_unclosed_body_is_reported_test() {
  assert list.contains(
    ids("enum Colour {\n  Red\n"),
    "parse.unclosed_delimiter",
  )
}

pub fn every_problem_is_reported_at_once_test() {
  let found = ids("enum Box(a) is Thing {\n  Full(Int)\n  let x = 1\n}\n")
  assert list.sort(found, string.compare)
    == [
      "parse.enum_inheritance",
      "parse.enum_member",
      "parse.enum_type_parameters",
      "parse.enum_variant_data",
    ]
}

pub fn declarations_after_an_invalid_enum_still_parse_test() {
  let module =
    support.parse_module_with_errors(
      "module main\nenum Box(a) { Full(Int) }\nclass After {}\n",
    )
  let assert [ast.EnumDeclaration(_), ast.ClassDeclaration(after)] =
    module.declarations
  assert after.name.name == "After"
}

pub fn a_qualified_variant_is_an_enum_pattern_test() {
  let assert ast.EnumPattern(
    module: None,
    enum_name: "Colour",
    variant: ast.Name("Red", _),
    ..,
  ) = pattern("Colour.Red")
}

pub fn a_module_qualified_variant_is_an_enum_pattern_test() {
  let assert ast.EnumPattern(
    module: Some("colours"),
    enum_name: "Colour",
    variant: ast.Name("Red", _),
    ..,
  ) = pattern("colours.Colour.Red")
}

pub fn a_bare_upper_name_stays_a_class_pattern_test() {
  let assert ast.ConstructorPattern(None, "Red", [], _) = pattern("Red")
}

pub fn a_module_qualified_class_stays_a_class_pattern_test() {
  let assert ast.ConstructorPattern(Some("shapes"), "Circle", [_], _) =
    pattern("shapes.Circle(r)")
}

pub fn enum_patterns_nest_test() {
  let assert ast.ConstructorPattern(
    None,
    "Error",
    [ast.EnumPattern(enum_name: "Severity", variant: ast.Name("Fatal", _), ..)],
    _,
  ) = pattern("Error(Severity.Fatal)")
  let assert ast.TuplePattern(
    [ast.EnumPattern(enum_name: "A", ..), ast.EnumPattern(enum_name: "B", ..)],
    _,
  ) = pattern("#(A.X, B.Y)")
  let assert ast.ListPattern([ast.EnumPattern(enum_name: "A", ..)], Some(_), _) =
    pattern("[A.X, ..rest]")
}

pub fn the_enum_pattern_span_test() {
  let source = "module main\nf(v) { match v {\n  lib.Colour.Red -> 1\n} }\n"
  let module = support.parse(source)
  let assert [ast.FunctionDeclaration(function)] = module.declarations
  let assert [ast.ExpressionStatement(ast.Match(branches: [branch], ..))] =
    function.body.statements
  let assert ast.EnumPattern(variant:, span:, ..) = branch.pattern
  assert support.text_at(source, span) == "lib.Colour.Red"
  assert support.text_at(source, variant.span) == "Red"
}

pub fn enum_patterns_bind_nothing_test() {
  assert ast.pattern_bindings(pattern("Colour.Red")) == []
  assert ast.pattern_expressions(pattern("Colour.Red")) == []
}

pub fn enum_pattern_arguments_are_reported_test() {
  assert ids("f(v) {\n  match v {\n    Colour.Red() -> 1\n    _ -> 2\n  }\n}\n")
    == ["parse.enum_pattern_arguments"]
  assert ids(
      "f(v) {\n  match v {\n    Colour.Red(x) -> x\n    _ -> 2\n  }\n}\n",
    )
    != []
}

pub fn enum_pattern_arguments_keep_the_bare_pattern_test() {
  let module =
    support.parse_module_with_errors(
      "module main\nf(v) { match v {\n  Colour.Red(1, 2) -> 1\n} }\n",
    )
  let assert [ast.FunctionDeclaration(function)] = module.declarations
  let assert [ast.ExpressionStatement(ast.Match(branches: [branch], ..))] =
    function.body.statements
  let assert ast.EnumPattern(enum_name: "Colour", ..) = branch.pattern
}

pub fn enum_pattern_arguments_fix_removes_the_parentheses_test() {
  let source =
    "module main\nf(v) {\n  match v {\n    Colour.Red() -> 1\n  }\n}\n"
  let checked = compiler.check_source(support.path, source)
  let assert [found] = checked.diagnostics
  assert found.id == "parse.enum_pattern_arguments"
  let assert [edit] = found.fixes
  assert edit.applicability == diagnostic.Automatic
  assert fix.apply(source, [edit])
    == Ok("module main\nf(v) {\n  match v {\n    Colour.Red -> 1\n  }\n}\n")
}

pub fn a_variant_without_a_name_is_a_syntax_error_test() {
  assert ids("f(v) { match v { Colour. -> 1 } }\n") != []
}

pub fn duplicate_variants_are_reported_test() {
  assert ids("enum Light {\n  Red\n  Green\n  Red\n}\n")
    == ["analysis.duplicate_enum_variant"]
}

pub fn every_repeated_variant_is_reported_test() {
  assert ids("enum Light { Red, Red, Red, Green, Green }\n")
    == [
      "analysis.duplicate_enum_variant",
      "analysis.duplicate_enum_variant",
      "analysis.duplicate_enum_variant",
    ]
}

pub fn the_same_variant_in_two_enums_is_fine_test() {
  assert ids("enum Light { Red, Green }\nenum Flag { Red, White }\n") == []
}

pub fn an_enum_and_a_class_may_not_share_a_name_test() {
  assert ids("enum Colour { Red }\nclass Colour {}\n")
    == ["analysis.duplicate_declaration"]
}

pub fn an_enum_and_a_function_may_not_share_a_name_test() {
  assert ids("enum Colour { Red }\nColour() { 1 }\n") != []
}

pub fn classes_cannot_inherit_from_enums_test() {
  assert ids("enum Severity { Error }\nclass Fatal is Severity {}\n")
    == ["analysis.invalid_superclass"]
}

pub fn an_enum_annotation_resolves_test() {
  assert ids(
      "enum Colour { Red }\nname(colour: Colour) -> Colour { colour }\nclass Pixel { let colour: Colour\nnew(colour) { self.colour = colour } }\n",
    )
    == []
}

pub fn an_enum_value_resolves_test() {
  assert ids("enum Colour { Red }\nmain() { Colour.Red }\n") == []
}

pub fn an_enum_pattern_resolves_test() {
  assert ids(
      "enum Colour { Red }\nf(v: Colour) { match v {\n  Colour.Red -> 1\n} }\n",
    )
    == []
}

pub fn an_unknown_enum_in_a_pattern_is_reported_test() {
  assert ids("f(v) { match v {\n  Colur.Red -> 1\n  _ -> 2\n} }\n")
    == ["analysis.unknown_name"]
}

pub fn an_unknown_module_in_an_enum_pattern_is_reported_test() {
  assert ids("f(v) { match v {\n  lib.Colour.Red -> 1\n  _ -> 2\n} }\n") != []
}

pub fn an_enum_used_only_in_a_pattern_counts_as_used_test() {
  assert ids(
      "enum _Colour { Red }\nf(v) { match v {\n  _Colour.Red -> 1\n  _ -> 2\n} }\nmain() { f(1) }\n",
    )
    |> list.filter(fn(id) { id == "analysis.unused_declaration" })
    == []
}

pub fn invalid_enums_snapshot_test() {
  support.rendered(
    "module main\n\nenum Box(a) is Thing {\n  Full(Int)\n  Empty\n  let x = 1\n  describe() { \"box\" }\n}\n\nenum Nothing {}\n\nenum Light { Red, Red }\n\nclass Loud is Light {}\n\nmain() {\n  match Light.Red {\n    Light.Red() -> 1\n    _ -> 2\n  }\n}\n",
  )
  |> birdie.snap(title: "enums: invalid declarations and patterns")
}
