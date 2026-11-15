//// Show the guest's own name, not the compartments in their suitcase.

import birdie
import cli/command
import gleam/string
import support

fn project(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
}

pub fn derived_classes_print_without_wrappers_and_keep_declared_nil_fields_test() {
  use directory <- support.with_directory("class_inspection_hierarchy")
  project(directory)
  support.write(
    directory <> "/src/main.pooka",
    "module main\nclass Shape { new() {} }\nclass Circle is Shape { let radius: Float\n new(radius) { super.new()\n self.radius = radius } }\nclass Root(value: Int)\nclass Middle is Root { let note: Nil\n new(value, note) { super.new(value)\n self.note = note } }\nclass Leaf is Middle { let name: String\n new(value, note, name) { super.new(value, note)\n self.name = name } }\nclass Box(value: Shape)\nmain() { echo Circle(2.5)\n echo [Circle(1.0)]\n echo Leaf(1, Nil, \"leaf\")\n echo Box(Circle(3.0))\n echo #(Some(Circle(4.0)), Ok(Circle(5.0)))\n echo Shape() }\n",
  )
  let report = support.cli_main(["run"], command.plain(directory))
  assert report.status == 0
  assert string.contains(report.stdout, "Circle(2.5)")
  assert string.contains(report.stdout, "[Circle(1.0)]")
  assert string.contains(report.stdout, "Leaf(1, Nil, \"leaf\")")
  assert string.contains(report.stdout, "Box(Circle(3.0))")
  assert string.contains(report.stdout, "#(Some(Circle(4.0)), Ok(Circle(5.0)))")
  assert string.contains(report.stdout, "Shape()")
  assert !string.contains(report.stdout, "Shape(Circle")
  birdie.snap(report.stdout, "class inspection declared fields and hierarchy")
}

pub fn test_failure_values_share_the_corrected_class_inspection_test() {
  use directory <- support.with_directory("class_inspection_assertion")
  project(directory)
  support.write(
    directory <> "/src/types.pooka",
    "module types\nclass Shape {}\nclass Circle(radius: Float) is Shape\n",
  )
  support.write(
    directory <> "/test/types.spec.pooka",
    "module types_test\nimport types.{Circle}\ntest \"two circles\" { assert Circle(1.0) == Circle(2.0) }\n",
  )
  let report = support.cli_main(["test"], command.plain(directory))
  assert report.status == 1
  assert string.contains(report.stdout, "expected Circle(2.0)")
  assert string.contains(report.stdout, "got Circle(1.0)")
  assert !string.contains(report.stdout, "Shape(Circle")
}
