//// The family name travels with every variant.
////
//// Check enum identity, signatures, matching and execution across local and
//// imported modules. Variants are values rather than callable constructors.
//// Closed families support exhaustive matches, and changing their members must
//// invalidate dependent checking.
////
//// ```pooka
//// enum Light { Red, Green }
//// main() { match Light.Red { Light.Red -> 1 Light.Green -> 2 } }
//// ```

import birdie
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import support

const severity = "enum Severity {\n  Error\n  Warning\n  Notice\n}\n"

const light = "enum Light { Red, Amber, Green }\n"

fn check(body: String) -> module_infer.Module {
  let assert Ok(report) =
    module_infer.infer(
      support.parse("module main\n" <> body),
      dict.new(),
      unify.new(),
      support.path,
    )
  report
}

fn ids(body: String) -> List(String) {
  check(body).diagnostics |> list.map(fn(value) { value.id })
}

fn type_of(body: String, name: String) -> String {
  let report = check(body)
  let assert Ok(function) =
    list.find(report.functions, fn(function) { function.name.name == name })
  monotype.to_string(unify.apply(function.type_, report.state))
}

fn run(name: String, files: List(#(String, String))) -> String {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  list.each(files, fn(file) {
    support.write(directory <> "/src/" <> file.0, file.1)
  })
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
  outcome.stdout
}

fn output(name: String, body: String) -> String {
  run(name, [#("main.pooka", "module main\n" <> body)])
}

fn check_project(name: String, files: List(#(String, String))) -> String {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  list.each(files, fn(file) {
    support.write(directory <> "/src/" <> file.0, file.1)
  })
  let outcome = support.cli_main(["check"], command.plain(directory))
  support.diagnostics(outcome.stderr)
}

pub fn a_variant_has_the_enum_type_test() {
  assert type_of(severity <> "pick() { Severity.Warning }\n", "pick")
    == "fn() -> main.Severity"
}

pub fn every_variant_has_the_same_type_test() {
  assert ids(
      severity
      <> "all() { [Severity.Error, Severity.Warning, Severity.Notice] }\n",
    )
    == []
  assert type_of(
      severity
        <> "all() { [Severity.Error, Severity.Warning, Severity.Notice] }\n",
      "all",
    )
    == "fn() -> List(main.Severity)"
}

pub fn enums_are_parameter_and_return_types_test() {
  assert type_of(
      severity <> "same(value: Severity) -> Severity { value }\n",
      "same",
    )
    == "fn(main.Severity) -> main.Severity"
}

pub fn enum_parameters_are_inferred_from_patterns_test() {
  assert type_of(
      severity
        <> "describe(value) {\n  match value {\n    Severity.Error -> 1\n    Severity.Warning -> 2\n    Severity.Notice -> 3\n  }\n}\n",
      "describe",
    )
    == "fn(main.Severity) -> Int"
}

pub fn enum_parameters_are_inferred_from_equality_test() {
  assert type_of(
      severity <> "is_error(v) { v == Severity.Error }\n",
      "is_error",
    )
    == "fn(main.Severity) -> Bool"
}

pub fn enums_nest_in_generic_types_test() {
  assert type_of(
      severity <> "maybe() -> Option(Severity) { Some(Severity.Notice) }\n",
      "maybe",
    )
    == "fn() -> Option(main.Severity)"
  assert type_of(severity <> "pair() { #(Severity.Error, 1) }\n", "pair")
    == "fn() -> #(main.Severity, Int)"
}

pub fn equality_between_variants_test() {
  assert ids(
      severity
      <> "main() { #(Severity.Error == Severity.Error, Severity.Error != Severity.Notice) }\n",
    )
    == []
}

pub fn variants_of_different_enums_are_not_comparable_test() {
  assert ids(severity <> light <> "main() { Severity.Error == Light.Red }\n")
    == ["type.unification"]
}

pub fn an_enum_is_not_an_int_test() {
  assert ids(severity <> "main() -> Int { Severity.Error }\n")
    == ["type.unification"]
}

pub fn an_enum_is_not_a_string_test() {
  assert ids(severity <> "main() { Severity.Error == \"Error\" }\n")
    == ["type.unification"]
}

pub fn enums_are_distinct_from_same_named_classes_elsewhere_test() {
  assert ids(severity <> "class Error {}\nmain() -> Severity { Error() }\n")
    == ["type.unification"]
}

pub fn enum_fields_in_classes_test() {
  assert ids(
      severity
      <> "class Report {\n  let severity: Severity\n  new(severity) { self.severity = severity }\n}\nmain() { Report(Severity.Error).severity == Severity.Error }\n",
    )
    == []
}

pub fn enum_fields_reject_other_types_test() {
  assert ids(
      severity
      <> "class Report {\n  let severity: Severity\n  new(severity) { self.severity = severity }\n}\nmain() { Report(1) }\n",
    )
    == ["type.unification"]
}

pub fn enums_in_interface_signatures_test() {
  assert ids(
      severity
      <> "interface Rated { rating() -> Severity }\nclass Bug with Rated { rating() { Severity.Error } }\nmain() -> Rated { Bug() }\n",
    )
    == []
}

pub fn enums_in_function_types_test() {
  assert ids(
      severity
      <> "apply(f: fn(Severity) -> Int) -> Int { f(Severity.Notice) }\nmain() { apply(fn(s) { 1 }) }\n",
    )
    == []
}

pub fn an_unknown_variant_is_reported_test() {
  assert ids(severity <> "main() { Severity.Fatal }\n")
    == ["type.unknown_enum_variant"]
}

pub fn an_unknown_variant_suggests_the_closest_test() {
  let report = check(severity <> "main() { Severity.Eror }\n")
  let assert [found] = report.diagnostics
  assert found.suggestions == ["Did you mean `Severity.Error`?"]
}

pub fn calling_a_variant_is_reported_test() {
  assert ids(severity <> "main() { Severity.Error() }\n")
    == ["type.enum_variant_call"]
}

pub fn calling_a_variant_with_arguments_is_reported_test() {
  assert ids(severity <> "main() { Severity.Error(1, 2) }\n")
    == ["type.enum_variant_call"]
}

pub fn a_called_variant_still_has_the_enum_type_test() {
  assert ids(severity <> "main() -> Severity { Severity.Error() }\n")
    == ["type.enum_variant_call"]
}

pub fn calling_an_unknown_variant_reports_both_test() {
  assert ids(severity <> "main() { Severity.Fatal() }\n")
    == ["type.unknown_enum_variant", "type.enum_variant_call"]
}

pub fn the_enum_name_is_not_a_value_test() {
  assert ids(severity <> "main() { Severity }\n") == ["type.enum_as_value"]
}

pub fn the_enum_name_is_not_a_constructor_test() {
  let found = ids(severity <> "main() { Severity() }\n")
  assert list.contains(found, "type.enum_as_value")
}

pub fn an_enum_value_has_no_fields_test() {
  assert ids(severity <> "main() { Severity.Error.name }\n") != []
}

pub fn an_enum_value_has_no_methods_test() {
  assert ids(severity <> "main() { Severity.Error.describe() }\n") != []
}

pub fn exhaustive_enum_matches_test() {
  assert ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Error -> 1\n    Severity.Warning -> 2\n    Severity.Notice -> 3\n  }\n}\n",
    )
    == []
}

pub fn branch_order_does_not_matter_test() {
  assert ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Notice -> 3\n    Severity.Error -> 1\n    Severity.Warning -> 2\n  }\n}\n",
    )
    == []
}

pub fn a_missing_variant_is_reported_test() {
  assert ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Error -> 1\n    Severity.Warning -> 2\n  }\n}\n",
    )
    == ["type.non_exhaustive_match"]
}

pub fn the_missing_variant_is_named_test() {
  let report =
    check(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Error -> 1\n    Severity.Notice -> 2\n  }\n}\n",
    )
  let assert [found] = report.diagnostics
  assert found.suggestions
    == ["Handle `Severity.Warning` or add a fallback branch."]
}

pub fn a_fallback_completes_a_match_test() {
  assert ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Error -> 1\n    _ -> 2\n  }\n}\n",
    )
    == []
  assert ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Error -> 1\n    other -> 2\n  }\n}\n",
    )
    == []
}

pub fn a_repeated_variant_is_unreachable_test() {
  let found =
    ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Error -> 1\n    Severity.Error -> 2\n    _ -> 3\n  }\n}\n",
    )
  assert found != []
  assert !list.contains(found, "type.non_exhaustive_match")
}

pub fn a_fallback_after_every_variant_is_unreachable_test() {
  assert ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Error -> 1\n    Severity.Warning -> 2\n    Severity.Notice -> 3\n    _ -> 4\n  }\n}\n",
    )
    != []
}

// A guard can reject a value even when its variant pattern matches. It cannot
// establish unconditional coverage of that enum member.
pub fn guarded_branches_do_not_cover_test() {
  assert ids(
      severity
      <> "describe(value: Severity, loud: Bool) {\n  match value {\n    Severity.Error if loud -> 1\n    Severity.Warning -> 2\n    Severity.Notice -> 3\n  }\n}\n",
    )
    == ["type.non_exhaustive_match"]
}

pub fn a_variant_of_another_enum_is_reported_test() {
  assert ids(
      severity
      <> light
      <> "describe(value: Severity) {\n  match value {\n    Light.Red -> 1\n    _ -> 2\n  }\n}\n",
    )
    == ["type.unification"]
}

pub fn an_unknown_variant_pattern_is_reported_test() {
  assert ids(
      severity
      <> "describe(value: Severity) {\n  match value {\n    Severity.Fatal -> 1\n    _ -> 2\n  }\n}\n",
    )
    == ["type.unknown_enum_variant"]
}

pub fn a_class_used_as_an_enum_pattern_is_reported_test() {
  assert ids(
      "class Shape {}\nf(value) {\n  match value {\n    Shape.Circle -> 1\n    _ -> 2\n  }\n}\n",
    )
    == ["type.not_an_enum"]
}

pub fn enum_patterns_nested_in_results_test() {
  assert ids(
      severity
      <> "summary(result: Result(Int, Severity)) {\n  match result {\n    Ok(_) -> 0\n    Error(Severity.Error) -> 1\n    Error(Severity.Warning) -> 2\n    Error(Severity.Notice) -> 3\n  }\n}\n",
    )
    == []
  assert ids(
      severity
      <> "summary(result: Result(Int, Severity)) {\n  match result {\n    Ok(_) -> 0\n    Error(Severity.Error) -> 1\n  }\n}\n",
    )
    == ["type.non_exhaustive_match"]
}

pub fn enum_patterns_nested_in_tuples_test() {
  assert ids(
      light
      <> "both(a: Light, b: Bool) {\n  match #(a, b) {\n    #(Light.Red, _) -> 0\n    #(Light.Amber, True) -> 1\n    #(Light.Amber, False) -> 2\n    #(Light.Green, _) -> 3\n  }\n}\n",
    )
    == []
  let report =
    check(
      light
      <> "both(a: Light, b: Bool) {\n  match #(a, b) {\n    #(Light.Red, _) -> 0\n    #(Light.Amber, True) -> 1\n    #(Light.Green, _) -> 3\n  }\n}\n",
    )
  let assert [found] = report.diagnostics
  assert found.suggestions
    == ["Handle `#(Light.Amber, False)` or add a fallback branch."]
}

pub fn enum_patterns_nested_in_lists_test() {
  assert ids(
      light
      <> "first(lights: List(Light)) {\n  match lights {\n    [] -> 0\n    [Light.Red, ..] -> 1\n    [_, ..] -> 2\n  }\n}\n",
    )
    == []
}

pub fn enum_patterns_in_class_fields_test() {
  assert ids(
      light
      <> "class Lamp {\n  let light: Light\n  new(light) { self.light = light }\n}\nlit(lamp: Lamp) {\n  match lamp {\n    Lamp(Light.Red) -> 1\n    Lamp(Light.Amber) -> 2\n    Lamp(Light.Green) -> 3\n  }\n}\n",
    )
    == []
}

pub fn let_assert_with_an_enum_pattern_test() {
  assert ids(
      light <> "main(light: Light) {\n  let assert Light.Red = light\n  1\n}\n",
    )
    == []
}

pub fn a_single_variant_enum_is_matched_by_its_variant_test() {
  assert ids(
      "enum Unit { Only }\nf(value: Unit) {\n  match value {\n    Unit.Only -> 1\n  }\n}\n",
    )
    == []
}

pub fn many_variant_enums_test() {
  let names =
    int.range(from: 1, to: 41, with: [], run: fn(acc, n) { [n, ..acc] })
    |> list.reverse
    |> list.map(fn(n) { "V" <> int.to_string(n) })
  let declaration = "enum Big { " <> string.join(names, ", ") <> " }\n"
  let branches =
    list.map(names, fn(name) { "    Big." <> name <> " -> 1\n" })
    |> string.concat
  assert ids(
      declaration
      <> "f(value: Big) {\n  match value {\n"
      <> branches
      <> "  }\n}\n",
    )
    == []
  let missing =
    list.drop(names, 1)
    |> list.map(fn(name) { "    Big." <> name <> " -> 1\n" })
    |> string.concat
  let report =
    check(
      declaration
      <> "f(value: Big) {\n  match value {\n"
      <> missing
      <> "  }\n}\n",
    )
  let assert [found] = report.diagnostics
  assert found.suggestions == ["Handle `Big.V1` or add a fallback branch."]
}

pub fn variants_print_as_written_test() {
  assert output("enum_echo", severity <> "main() { echo Severity.Warning }\n")
    == "Severity.Warning\n"
}

pub fn variants_print_inside_collections_test() {
  assert output(
      "enum_echo_collections",
      light
        <> "main() { echo #([Light.Red, Light.Green], Some(Light.Amber), Ok(Light.Red)) }\n",
    )
    == "#([Light.Red, Light.Green], Some(Light.Amber), Ok(Light.Red))\n"
}

pub fn match_selects_the_variant_test() {
  assert output(
      "enum_match",
      severity
        <> "describe(value: Severity) -> String {\n  match value {\n    Severity.Error -> \"error\"\n    Severity.Warning -> \"warning\"\n    Severity.Notice -> \"notice\"\n  }\n}\nmain() {\n  echo describe(Severity.Error)\n  echo describe(Severity.Warning)\n  echo describe(Severity.Notice)\n}\n",
    )
    == "\"error\"\n\"warning\"\n\"notice\"\n"
}

pub fn equality_at_runtime_test() {
  assert output(
      "enum_equality",
      light
        <> "main() {\n  echo Light.Red == Light.Red\n  echo Light.Red == Light.Green\n  echo Light.Red != Light.Amber\n}\n",
    )
    == "True\nFalse\nTrue\n"
}

pub fn variants_are_stored_passed_and_returned_test() {
  assert output(
      "enum_values",
      light
        <> "next(light: Light) -> Light {\n  match light {\n    Light.Red -> Light.Green\n    Light.Green -> Light.Amber\n    Light.Amber -> Light.Red\n  }\n}\nclass Lamp {\n  let light: Light\n  new(light) { self.light = light }\n}\nmain() {\n  let lamp = Lamp(next(Light.Red))\n  echo lamp.light\n  echo next(next(lamp.light))\n}\n",
    )
    == "Light.Green\nLight.Red\n"
}

pub fn nested_enum_patterns_at_runtime_test() {
  assert output(
      "enum_nested",
      severity
        <> "summary(result: Result(Int, Severity)) -> String {\n  match result {\n    Ok(_) -> \"ok\"\n    Error(Severity.Error) -> \"failed\"\n    Error(_) -> \"warned\"\n  }\n}\nmain() {\n  echo summary(Ok(1))\n  echo summary(Error(Severity.Error))\n  echo summary(Error(Severity.Notice))\n}\n",
    )
    == "\"ok\"\n\"failed\"\n\"warned\"\n"
}

// The printed member name is not its full identity. Values from different
// enum families must remain distinct after compilation.
pub fn same_variant_names_in_different_enums_stay_distinct_test() {
  assert output(
      "enum_distinct",
      "enum Light { Red, Green }\nenum Flag { Red, White }\nlight(value: Light) {\n  match value {\n    Light.Red -> \"light\"\n    Light.Green -> \"go\"\n  }\n}\nflag(value: Flag) {\n  match value {\n    Flag.Red -> \"flag\"\n    Flag.White -> \"peace\"\n  }\n}\nmain() {\n  echo light(Light.Red)\n  echo flag(Flag.Red)\n  echo #(Light.Red, Flag.Red)\n}\n",
    )
    == "\"light\"\n\"flag\"\n#(Light.Red, Flag.Red)\n"
}

pub fn variants_named_like_types_run_test() {
  assert output(
      "enum_type_names",
      "enum Kind { Int, String }\nis_number(kind: Kind) {\n  match kind {\n    Kind.Int -> True\n    Kind.String -> False\n  }\n}\nmain() { echo #(is_number(Kind.Int), Kind.String) }\n",
    )
    == "#(True, Kind.String)\n"
}

pub fn the_token_kind_example_runs_test() {
  assert output(
      "enum_token_kind",
      "enum TokenKind { Name, Int, Float, String, EndOfFile }\nclass Token {\n  let kind: TokenKind\n  let text: String\n  new(kind, text) {\n    self.kind = kind\n    self.text = text\n  }\n}\nis_literal(token: Token) -> Bool {\n  match token.kind {\n    TokenKind.Int -> True\n    TokenKind.Float -> True\n    TokenKind.String -> True\n    _ -> False\n  }\n}\nmain() {\n  echo is_literal(Token(TokenKind.Int, \"1_000\"))\n  echo is_literal(Token(TokenKind.Name, \"x\"))\n}\n",
    )
    == "True\nFalse\n"
}

pub fn private_enums_run_test() {
  assert output(
      "enum_private",
      "enum _State { On, Off }\ntoggle(state: _State) -> _State {\n  match state {\n    _State.On -> _State.Off\n    _State.Off -> _State.On\n  }\n}\nmain() { echo toggle(_State.On) }\n",
    )
    == "_State.Off\n"
}

const colours =
  "module colours\n\n/// A primary colour.\nenum Colour {\n  Red\n  Green\n  Blue\n}\n\nname(colour: Colour) -> String {\n  match colour {\n    Colour.Red -> \"red\"\n    Colour.Green -> \"green\"\n    Colour.Blue -> \"blue\"\n  }\n}\n"

pub fn an_imported_enum_is_used_by_name_test() {
  assert run("enum_import_item", [
      #("colours.pooka", colours),
      #(
        "main.pooka",
        "module main\nimport colours.{Colour}\nmain() {\n  let colour = Colour.Green\n  echo colours.name(colour)\n  echo colour\n}\n",
      ),
    ])
    == "\"green\"\nColour.Green\n"
}

pub fn an_enum_is_used_through_its_module_test() {
  assert run("enum_import_module", [
      #("colours.pooka", colours),
      #(
        "main.pooka",
        "module main\nimport colours\nmain() {\n  let colour = colours.Colour.Blue\n  echo colours.name(colour)\n  match colour {\n    colours.Colour.Blue -> echo \"blue!\"\n    _ -> echo \"other\"\n  }\n}\n",
      ),
    ])
    == "\"blue\"\n\"blue!\"\n"
}

pub fn an_aliased_enum_test() {
  assert run("enum_import_alias", [
      #("colours.pooka", colours),
      #(
        "main.pooka",
        "module main\nimport colours.{Colour as Hue}\nshow(hue: Hue) -> String {\n  match hue {\n    Hue.Red -> \"r\"\n    Hue.Green -> \"g\"\n    Hue.Blue -> \"b\"\n  }\n}\nmain() { echo show(Hue.Red) }\n",
      ),
    ])
    == "\"r\"\n"
}

pub fn imported_enums_are_annotations_and_fields_test() {
  assert run("enum_import_annotation", [
      #("colours.pooka", colours),
      #(
        "main.pooka",
        "module main\nimport colours.{Colour}\nclass Pixel {\n  let colour: Colour\n  new(colour) { self.colour = colour }\n}\nmain() {\n  let pixel = Pixel(colours.Colour.Red)\n  echo pixel.colour == Colour.Red\n}\n",
      ),
    ])
    == "True\n"
}

pub fn imported_enum_matches_are_checked_for_exhaustiveness_test() {
  let rendered =
    check_project("enum_import_exhaustive", [
      #("colours.pooka", colours),
      #(
        "main.pooka",
        "module main\nimport colours.{Colour}\nf(colour: Colour) {\n  match colour {\n    Colour.Red -> 1\n    Colour.Green -> 2\n  }\n}\nmain() { f(Colour.Red) }\n",
      ),
    ])
  assert string.contains(rendered, "non-exhaustive match")
  assert string.contains(rendered, "Handle `Colour.Blue`")
}

pub fn unknown_imported_variants_are_reported_test() {
  let rendered =
    check_project("enum_import_unknown", [
      #("colours.pooka", colours),
      #(
        "main.pooka",
        "module main\nimport colours\nmain() { colours.Colour.Purple }\n",
      ),
    ])
  assert string.contains(rendered, "unknown enum variant")
}

pub fn an_imported_enum_through_its_module_is_not_a_value_test() {
  let rendered =
    check_project("enum_import_as_value", [
      #("colours.pooka", colours),
      #(
        "main.pooka",
        "module main\nimport colours\nmain() { colours.Colour }\n",
      ),
    ])
  assert string.contains(rendered, "enum used as a value")
}

// An enum's members are part of the exported interface. Reusing a dependent
// match after that set changes could preserve a false exhaustiveness result.
pub fn changing_variants_rechecks_dependents_test() {
  use directory <- support.with_directory("enum_cache")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/colours.pooka", colours)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nimport colours.{Colour}\nmain() { echo Colour.Blue }\n",
  )
  let first = support.cli_main(["run"], command.plain(directory))
  assert first.status == 0
  support.write(
    directory <> "/src/colours.pooka",
    "module colours\nenum Colour {\n  Red\n  Green\n}\n",
  )
  let second = support.cli_main(["check"], command.plain(directory))
  assert second.status != 0
  assert string.contains(
    support.diagnostics(second.stderr),
    "unknown enum variant",
  )
}

pub fn enum_type_errors_snapshot_test() {
  let source =
    "module main\n"
    <> severity
    <> "describe(severity: Severity) -> String {\n  match severity {\n    Severity.Error -> \"error\"\n    Severity.Warning -> \"warning\"\n  }\n}\nmain() {\n  let a = Severity.Eror\n  let b = Severity.Error()\n  let c = Severity\n  describe(Severity.Notice)\n}\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  let text =
    "Source:\n"
    <> source
    <> "\n---\n"
    <> support.render_all(report.diagnostics, source)
  birdie.snap(text, title: "enums: type errors")
}

pub fn enum_analysis_errors_snapshot_test() {
  support.rendered(
    "module main\n\nenum Light {\n  Red\n  Green\n  Red\n}\n\nclass Loud is Light {}\n",
  )
  |> birdie.snap(title: "enums: duplicate variants and enum superclasses")
}
