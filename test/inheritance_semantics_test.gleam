//// A parent view does not erase the child behind it.
////
//// Check inherited fields, substituted generic arguments, overrides, dispatch
//// and narrowing. Construction and class-pattern coverage must use the
//// complete hierarchy. Compatibility permits a base view while preserving
//// runtime nominal identity and lexical private-access rules.

import birdie
import cli/command
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string
import support

const animals =
  "class Animal {
  let name: String
  new(name) { self.name = name }
  describe() -> String { name + \" says \" + speak() }
  speak() -> String { \"...\" }
}
class Dog is Animal {
  let breed: String
  new(name, breed) {
    super.new(name)
    self.breed = breed
  }
  speak() -> String { \"Woof\" }
  describe() { super.describe() + \" (\" + breed + \")\" }
}
"

const shapes =
  "class Shape {}
class Circle is Shape {
  let radius: Float
  new(radius) { self.radius = radius }
}
class Square is Shape {
  let side: Float
  new(side) { self.side = side }
}
"

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
  check(body).diagnostics |> list.map(fn(diagnostic) { diagnostic.id })
}

fn type_of(body: String, name: String) -> String {
  let report = check(body)
  assert report.diagnostics == []
  let assert Ok(function) =
    list.find(report.functions, fn(function) { function.name.name == name })
  monotype.to_string(function.type_)
}

pub fn a_subclass_is_accepted_where_its_parent_is_expected_test() {
  assert ids(
      animals
      <> "talk(animal: Animal) { animal.speak() }\nmain() { echo { talk(Dog(\"Rex\", \"Beagle\")) } }",
    )
    == []
  assert ids(
      animals <> "main() -> Animal { echo { Dog(\"Rex\", \"Beagle\") } }",
    )
    == []
  assert ids(
      animals
      <> "main() { echo { let animal: Animal = Dog(\"Rex\", \"B\")\nanimal } }",
    )
    == []
}

// A base view omits guarantees supplied by a particular child. The accepted
// widening direction must not quietly become an implicit downcast.
pub fn a_parent_is_not_accepted_where_a_subclass_is_expected_test() {
  assert ids(animals <> "main() -> Dog { echo { Animal(\"Rex\") } }")
    == ["type.unification"]
}

pub fn immutable_builtin_containers_accept_subclasses_test() {
  assert ids(
      animals
      <> "all(animals: List(Animal)) { animals }\nmain() { echo { let dogs: List(Dog) = [Dog(\"a\", \"b\")]\nall(dogs) } }",
    )
    == []
}

pub fn subclasses_inherit_fields_and_methods_test() {
  assert type_of(
      animals
        <> "main() { echo { #(Dog(\"Rex\", \"B\").name, Dog(\"Rex\", \"B\").describe()) } }",
      "main",
    )
    == "fn() -> #(String, String)"
}

pub fn sibling_classes_join_to_their_common_parent_test() {
  assert type_of(
      shapes <> "main() { echo { [Circle(1.0), Square(2.0)] } }",
      "main",
    )
    == "fn() -> List(main.Shape)"
  assert type_of(
      shapes
        <> "pick(flag: Bool) { match flag {\n True -> Circle(1.0)\n False -> Square(2.0)\n} }",
      "pick",
    )
    == "fn(Bool) -> main.Shape"
}

pub fn unrelated_classes_do_not_join_test() {
  assert ids(
      shapes <> animals <> "main() { echo { [Circle(1.0), Animal(\"x\")] } }",
    )
    == ["type.unification"]
}

pub fn generic_hierarchies_carry_their_arguments_test() {
  let source =
    "class Outcome(a, e) {}
class Success(a, e) is Outcome(a, e) {
  let value: a
  new(value) { self.value = value }
}
class Failure(a, e) is Outcome(a, e) {
  let error: e
  new(error) { self.error = error }
}
unwrap(outcome: Outcome(Int, String)) {
  match outcome {
    Success(value) -> value
    Failure(_) -> 0
  }
}
main() { unwrap(Success(1)) }
"
  assert type_of(source, "unwrap") == "fn(main.Outcome(Int, String)) -> Int"
  assert type_of(source, "main") == "fn() -> Int"
}

pub fn an_override_must_keep_the_inherited_type_test() {
  assert ids(
      "class Animal { speak() -> String { \"...\" } }\nclass Dog is Animal { speak() -> Int { 42 } }",
    )
    == ["type.incompatible_override"]
}

pub fn an_unannotated_override_takes_the_inherited_type_test() {
  assert ids(
      "class Animal { speak() -> String { \"...\" } }\nclass Dog is Animal { speak() { \"Woof\" } }\nmain() -> String { echo { Dog().speak() } }",
    )
    == []
}

pub fn private_methods_are_not_override_targets_test() {
  assert ids(
      "class Animal { _hidden() -> String { \"a\" } }\nclass Dog is Animal { _hidden() -> Int { 1 } }",
    )
    == []
}

pub fn super_constructor_arguments_are_checked_test() {
  assert ids(
      "class Animal {\n  let name: String\n  new(name: String) { self.name = name }\n}\nclass Dog is Animal {\n  new() { super.new(1) }\n}",
    )
    == ["type.unification"]
}

pub fn super_methods_are_typed_test() {
  assert ids(animals) == []
  assert ids(
      "class Animal { speak() -> String { \"...\" } }\nclass Dog is Animal { speak() { super.missing() } }",
    )
    |> list.contains("type.unknown_super_member")
}

pub fn a_subclass_cannot_redeclare_an_inherited_field_test() {
  assert ids(
      "class Animal {\n  let name: String = \"a\"\n}\nclass Dog is Animal {\n  let name: String = \"b\"\n}",
    )
    == ["type.inherited_field_redeclared"]
}

pub fn subclasses_cannot_read_private_parent_fields_test() {
  assert ids(
      "class Animal { let _secret: Int = 1 }\nclass Dog is Animal {}\nmain() { echo { Dog()._secret } }",
    )
    == ["type.private_member"]
}

pub fn a_family_class_without_new_cannot_be_constructed_test() {
  assert ids(shapes <> "main() { echo { Shape() } }") == ["type.abstract_class"]
}

pub fn a_class_with_new_and_subclasses_can_be_constructed_test() {
  assert ids(animals <> "main() { echo { Animal(\"Rex\") } }") == []
}

pub fn a_subclass_pattern_narrows_its_subject_test() {
  assert type_of(
      shapes
        <> "radius(shape: Shape) { match shape {\n Circle(r) -> r\n _ -> 0.0\n} }",
      "radius",
    )
    == "fn(main.Shape) -> Float"
}

pub fn subclasses_of_a_family_class_are_exhaustive_test() {
  assert ids(
      shapes
      <> "area(shape: Shape) { match shape {\n Circle(r) -> r\n Square(s) -> s\n} }",
    )
    == []
}

pub fn a_missing_subclass_is_reported_test() {
  let report =
    check(shapes <> "area(shape: Shape) { match shape {\n Circle(r) -> r\n} }")
  let assert [diagnostic] = report.diagnostics
  assert diagnostic.id == "type.non_exhaustive_match"
  assert diagnostic.suggestions
    == ["Handle `Square(_)` or add a fallback branch."]
}

pub fn a_constructible_parent_must_also_be_handled_test() {
  let report =
    check(
      animals
      <> "name(animal: Animal) { match animal {\n Dog(name, _) -> name\n} }",
    )
  let assert [diagnostic] = report.diagnostics
  assert diagnostic.suggestions
    == ["Handle `Animal(_)` or add a fallback branch."]
  assert ids(
      animals
      <> "name(animal: Animal) { match animal {\n Dog(name, _) -> name\n Animal(name) -> name\n} }",
    )
    == []
}

pub fn a_parent_pattern_covers_its_subclasses_test() {
  assert ids(
      animals
      <> "name(animal: Animal) { match animal {\n Animal(name) -> name\n Dog(name, _) -> name\n} }",
    )
    == ["type.unreachable_pattern"]
}

pub fn unannotated_subjects_take_the_root_of_the_hierarchy_test() {
  assert type_of(
      shapes
        <> "area(shape) { match shape {\n Circle(r) -> r\n Square(s) -> s\n} }",
      "area",
    )
    == "fn(main.Shape) -> Float"
}

pub fn private_fields_need_a_wildcard_in_patterns_test() {
  let source =
    "class Token {\n  let _secret: Int = 1\n  let label: String = \"t\"\n}\n"
  assert ids(
      source <> "f(token: Token) { match token { Token(_, label) -> label } }",
    )
    == []
  assert ids(
      source <> "f(token: Token) { match token { Token(s, label) -> label } }",
    )
    == ["type.private_pattern_field"]
}

pub fn inheritance_diagnostics_snapshot_test() {
  let source =
    "module main\nclass Animal { speak() -> String { \"...\" } }\nclass Dog is Animal { speak() -> Int { 42 } }\nclass Shape {}\nclass Circle is Shape {}\nmain() { Shape() }\n"
  let diagnostics =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  let assert Ok(report) = diagnostics
  support.render_all(report.diagnostics, source)
  |> birdie.snap(title: "types: inheritance diagnostics")
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

pub fn methods_dispatch_on_the_runtime_class_test() {
  let output =
    run("inheritance_dispatch", [
      #(
        "main.pooka",
        "module main\n"
          <> animals
          <> "class Puppy is Dog {\n  new(name) { super.new(name, \"puppy\") }\n  speak() -> String { \"Yip\" }\n}\ntalk(animal: Animal) { animal.describe() }\nmain() { echo { #(talk(Animal(\"A\")), talk(Dog(\"D\", \"Beagle\")), talk(Puppy(\"P\"))) } }",
      ),
    ])
  assert output
    == "#(\"A says ...\", \"D says Woof (Beagle)\", \"P says Yip (puppy)\")\n"
}

pub fn hierarchy_patterns_execute_test() {
  let output =
    run("inheritance_patterns", [
      #(
        "main.pooka",
        "module main\n"
          <> shapes
          <> animals
          <> "area(shape: Shape) { match shape {\n Circle(r) -> r * 2.0\n Square(s) -> s * s\n} }\nkind(animal: Animal) { match animal {\n Dog(_, breed) -> breed\n Animal(name) -> name\n} }\nmain() { echo { #(area(Circle(1.0)), area(Square(3.0)), kind(Dog(\"Rex\", \"Beagle\")), kind(Animal(\"Cat\"))) } }",
      ),
    ])
  assert output == "#(2.0, 9.0, \"Beagle\", \"Cat\")\n"
}

pub fn inherited_private_state_stays_with_its_class_test() {
  let output =
    run("inheritance_private", [
      #(
        "main.pooka",
        "module main\nclass Counter {\n  let _start: Int = 10\n  start() -> Int { _start }\n}\nclass Fast is Counter {\n  let step: Int = 2\n}\nmain() { echo { #(Fast().start(), Fast().step) } }",
      ),
    ])
  assert output == "#(10, 2)\n"
}

pub fn equality_compares_the_concrete_class_test() {
  let output =
    run("inheritance_equality", [
      #(
        "main.pooka",
        "module main\n"
          <> animals
          <> "class Puppy is Dog {\n  new(name) { super.new(name, \"puppy\") }\n}\nmain() { echo { #(Dog(\"R\", \"puppy\") == Dog(\"R\", \"puppy\"), Dog(\"R\", \"puppy\") == Puppy(\"R\")) } }",
      ),
    ])
  assert output == "#(True, False)\n"
}

pub fn imported_hierarchies_dispatch_and_match_test() {
  let output =
    run("inheritance_imported", [
      #(
        "zoo.pooka",
        "module zoo\nclass Animal {\n  let name: String\n  new(name) { self.name = name }\n  speak() -> String { \"...\" }\n}\nclass Cat is Animal {\n  new(name) { super.new(name) }\n  speak() -> String { \"Meow\" }\n}\n",
      ),
      #(
        "main.pooka",
        "module main\nimport zoo.{Animal, Cat}\nloud(animal: Animal) { animal.speak() + \"!\" }\nname(animal: Animal) { match animal {\n Cat(name) -> \"cat \" + name\n Animal(name) -> name\n} }\nmain() { echo { #(loud(Cat(\"Tom\")), name(Cat(\"Tom\")), name(Animal(\"x\"))) } }",
      ),
    ])
  assert output == "#(\"Meow!\", \"cat Tom\", \"x\")\n"
}

pub fn implicit_parent_initialization_runs_test() {
  let output =
    run("inheritance_implicit", [
      #(
        "main.pooka",
        "module main\nclass Base {\n  let label: String = \"base\"\n}\nclass Child is Base {\n  let extra: Int = 1\n}\nmain() { echo { #(Child().label, Child().extra) } }",
      ),
    ])
  assert string.contains(output, "base")
  assert output == "#(\"base\", 1)\n"
}

pub fn the_original_subject_has_subclass_members_inside_its_branch_test() {
  assert type_of(
      "class Animal {}\nclass Dog is Animal { bark() { \"woof\" } }\nclass Cat is Animal {}\nspeak(animal: Animal) { match animal { Dog -> animal.bark()\nCat -> \"meow\" } }",
      "speak",
    )
    == "fn(main.Animal) -> String"
}

pub fn narrowed_subjects_are_available_in_guards_and_closures_test() {
  assert type_of(
      "class Animal {}\nclass Dog is Animal { bark() { True } }\nclass Cat is Animal {}\ncheck(animal: Animal) { match animal { Dog if animal.bark() -> { let bark = fn() { animal.bark() }\nbark() }\n_ -> False } }",
      "check",
    )
    == "fn(main.Animal) -> Bool"
}

pub fn subject_narrowing_does_not_escape_a_branch_or_match_test() {
  let declarations =
    "class Animal {}\nclass Dog is Animal { bark() { Nil } }\nclass Cat is Animal {}\n"
  assert ids(
      declarations
      <> "check(animal: Animal) { match animal { Dog -> animal.bark()\nCat -> animal.bark() } }",
    )
    == ["type.unknown_member"]
  assert ids(
      declarations
      <> "check(animal: Animal) { match animal { Dog -> animal.bark()\nCat -> Nil }\nanimal.bark() }",
    )
    == ["type.unknown_member"]
  assert ids(
      declarations
      <> "check(animal: Animal) { match animal { Dog if False -> animal.bark()\n_ -> animal.bark() } }",
    )
    == ["type.unknown_member"]
}

pub fn pattern_bindings_and_inner_locals_shadow_the_narrowed_subject_test() {
  assert type_of(
      "class Animal {}\nclass Dog is Animal { let label: String\nnew(label) { self.label = label } }\nclass Cat is Animal {}\nlabel(animal: Animal) { match animal { Dog(animal) -> animal + \"!\"\nCat -> \"cat\" } }",
      "label",
    )
    == "fn(main.Animal) -> String"
  assert type_of(
      "class Animal {}\nclass Dog is Animal { bark() { \"woof\" } }\nclass Cat is Animal {}\nlabel(animal: Animal) { match animal { Dog -> { let animal = 42\nanimal + 1 }\nCat -> 0 } }",
      "label",
    )
    == "fn(main.Animal) -> Int"
}

pub fn narrowing_reuses_the_generic_arguments_of_the_matched_pattern_test() {
  assert type_of(
      "class Value(a) {}\nclass Box(a) is Value(a) { let value: a\nnew(value) { self.value = value }\nget() { value } }\nread(value: Value(String)) { match value { Box(field) -> #(value.get(), field) } }",
      "read",
    )
    == "fn(main.Value(String)) -> #(String, String)"
}

pub fn nested_patterns_do_not_narrow_the_entire_subject_test() {
  assert type_of(
      "class Animal {}\nclass Dog is Animal { bark() { True } }\ncheck(pair: #(Animal, Int)) { match pair { #(Dog, n) -> pair } }",
      "check",
    )
    == "fn(#(main.Animal, Int)) -> #(main.Animal, Int)"
}

pub fn narrowed_subjects_execute_with_subclass_storage_and_bound_methods_test() {
  let output =
    run("inheritance_subject_narrowing", [
      #(
        "main.pooka",
        "module main\nclass Animal { let name: String\nnew(name) { self.name = name } }\nclass Dog is Animal { let breed: String\nnew(name, breed) { super.new(name)\nself.breed = breed }\nbark() { name + \" \" + breed } }\nclass Cat is Animal { new(name) { super.new(name) } }\nspeak(animal: Animal) { match animal { Dog(_, _) if animal.breed == \"Beagle\" -> { let bark = animal.bark\nbark() }\n_ -> \"other\" } }\nmain() { echo { #(speak(Dog(\"Rex\", \"Beagle\")), speak(Cat(\"Tom\")), speak(Dog(\"Max\", \"Poodle\"))) } }",
      ),
    ])
  assert output == "#(\"Rex Beagle\", \"other\", \"other\")\n"
}

pub fn narrowing_keeps_private_member_access_rules_test() {
  assert ids(
      "class Animal {}\nclass Dog is Animal { _bark() { True } }\ncheck(animal: Animal) { match animal { Dog -> animal._bark() } }",
    )
    == ["type.private_member"]
}

pub fn narrowing_an_unknown_subject_preserves_the_inferred_parent_signature_test() {
  assert type_of(
      "class Animal {}\nclass Dog is Animal { bark() { True } }\nclass Cat is Animal {}\ncheck(animal) { match animal { Dog -> animal.bark()\nCat -> False } }",
      "check",
    )
    == "fn(main.Animal) -> Bool"
}

pub fn nested_matches_preserve_the_enclosing_refinement_test() {
  assert type_of(
      "class Animal {}\nclass Dog is Animal { bark() { True } }\nclass Cat is Animal {}\ncheck(animal: Animal, flag: Bool) { match animal { Dog -> { match flag { True -> animal.bark()\nFalse -> False }\nanimal.bark() }\nCat -> False } }",
      "check",
    )
    == "fn(main.Animal, Bool) -> Bool"
}

pub fn branch_local_subject_narrowing_diagnostics_snapshot_test() {
  let source =
    "module main\nclass Animal {}\nclass Dog is Animal { bark() { Nil } }\nclass Cat is Animal {}\ncheck(animal: Animal) {\n  match animal {\n    Dog -> animal.bark()\n    Cat -> animal.bark()\n  }\n  animal.bark()\n}\n"
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  support.render_all(report.diagnostics, source)
  |> birdie.snap(title: "types: branch local subject narrowing")
}
