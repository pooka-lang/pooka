//// Whitespace may move; the program must keep its belongings.
////
//// Check declaration spacing, comment attachment, line wrapping and nested
//// callback layout. The helper formats twice, reparses the result and compares
//// token values, so an attractive layout cannot silently alter syntax or keep
//// changing on each pass.
////
//// ```text
//// format(source) = output
//// format(output) = output
//// tokens(source) = tokens(output)
//// ```

import birdie
import compiler/lexer/lexer
import compiler/parser/parser
import gleam/list
import gleam/string
import tools/formatter

// Each layout assertion also checks a fixed point, valid syntax and unchanged
// token values. A visually pleasing output must satisfy all three
// obligations.
fn formatted(source: String) -> String {
  let assert Ok(output) = formatter.format(source)
  let assert Ok(again) = formatter.format(output)
  assert again == output
  assert parser.parse(lexer.lex(output).tokens).errors == []
  assert list.map(lexer.lex(source).tokens, fn(t) { t.token })
    == list.map(lexer.lex(output).tokens, fn(t) { t.token })
  output
}

pub fn uncommented_declarations_have_one_blank_line_test() {
  assert formatted("module main\nf() { 1 }\ng() { 2 }\n")
    == "module main\n\nf() {\n  1\n}\n\ng() {\n  2\n}\n"
}

pub fn declaration_comments_stay_attached_test() {
  assert formatted(
      "module main\nf() { 1 } // trailing\n/// Next.\n// More.\ng() { 2 }\n",
    )
    == "module main\n\nf() {\n  1\n} // trailing\n\n/// Next.\n// More.\ng() {\n  2\n}\n"
}

pub fn imports_remain_a_group_test() {
  assert formatted("module main\nimport one\nimport two.{Thing}\nf() { 1 }\n")
    == "module main\n\nimport one\nimport two.{Thing}\n\nf() {\n  1\n}\n"
}

pub fn methods_and_constructor_are_separated_test() {
  assert formatted(
      "module main\nclass Box {\nlet value: Int\nnew(value) { self.value = value }\nget() { value }\n/// Doubles.\ndouble() { value * 2 }\n}\n",
    )
    == "module main\n\nclass Box {\n  let value: Int\n\n  new(value) {\n    self.value = value\n  }\n\n  get() {\n    value\n  }\n\n  /// Doubles.\n  double() {\n    value * 2\n  }\n}\n"
}

// The parser synthesizes members from concise fields, but the formatter
// prints the original declaration. Synthetic constructor nodes must not
// create extra blank sections.
pub fn concise_fields_are_not_synthetic_declarations_test() {
  assert formatted(
      "module main\nclass Point(x: Int, y: Int) { sum() { x + y } }\n",
    )
    == "module main\n\nclass Point(x: Int, y: Int) {\n  sum() {\n    x + y\n  }\n}\n"
}

pub fn interface_and_external_methods_are_separated_test() {
  assert formatted(
      "module main\ninterface Reader {\nread() -> Int\nclose() -> Nil\n}\nexternal Native from erlang \"native\" {\nread() -> Int\nclose() -> Nil\n}\n",
    )
    == "module main\n\ninterface Reader {\n  read() -> Int\n\n  close() -> Nil\n}\n\nexternal Native from erlang \"native\" {\n  read() -> Int\n\n  close() -> Nil\n}\n"
}

pub fn one_line_matches_expand_each_branch_test() {
  assert formatted("module main\nf(x) { match x { True -> 1 False -> 0 } }\n")
    == "module main\n\nf(x) {\n  match x {\n    True -> 1\n    False -> 0\n  }\n}\n"
}

pub fn nested_matches_and_branch_blocks_expand_test() {
  assert formatted(
      "module main\nf(x) { match x { Some(y) -> match y { 0 -> 1 _ -> { let z = y + 1\nz } } None -> 0 } }\n",
    )
    == "module main\n\nf(x) {\n  match x {\n    Some(y) -> match y {\n      0 -> 1\n      _ -> {\n        let z = y + 1\n        z\n      }\n    }\n    None -> 0\n  }\n}\n"
}

pub fn branch_comments_are_preserved_test() {
  assert formatted(
      "module main\nf(x) { match x { True -> 1 // yes\n// no\nFalse -> 0 } }\n",
    )
    == "module main\n\nf(x) {\n  match x {\n    True -> 1 // yes\n    // no\n    False -> 0\n  }\n}\n"
}

pub fn long_function_parameters_wrap_at_eighty_columns_test() {
  assert formatted(
      "module main\ncalculate(first_value: Int, second_value: Int, third_value: Int, fourth_value: Int) -> Int { first_value }\n",
    )
    == "module main\n\ncalculate(\n  first_value: Int,\n  second_value: Int,\n  third_value: Int,\n  fourth_value: Int\n) -> Int {\n  first_value\n}\n"
}

pub fn long_calls_wrap_arguments_and_preserve_nested_calls_test() {
  assert formatted(
      "module main\nf() { send(\"a moderately long argument value\", nested(1, 2), \"another moderately long argument value\") }\n",
    )
    == "module main\n\nf() {\n  send(\n    \"a moderately long argument value\",\n    nested(1, 2),\n    \"another moderately long argument value\"\n  )\n}\n"
}

pub fn short_calls_stay_inline_test() {
  assert formatted("module main\nf() { add(1, 2) }\n")
    == "module main\n\nf() {\n  add(1, 2)\n}\n"
}

pub fn wrapped_arguments_keep_trailing_comments_test() {
  let source =
    "module main\nf() { send(\"a moderately long argument value\", // first\n\"another moderately long argument value\", 3) }\n"
  let output = formatted(source)
  assert string.contains(
    output,
    "\"a moderately long argument value\", // first\n",
  )
  assert string.contains(output, "\n  )\n")
}

pub fn matches_in_callbacks_expand_the_callback_body_test() {
  assert formatted(
      "module main\nf(xs) { map(xs, fn(x) { match x { True -> 1 False -> 0 } }) }\n",
    )
    == "module main\n\nf(xs) {\n  map(xs, fn(x) {\n    match x {\n      True -> 1\n      False -> 0\n    }\n  })\n}\n"
}

pub fn long_callbacks_and_nested_generics_are_idempotent_test() {
  let output =
    formatted(
      "module main\nf(xs) { map(xs, fn(item: #(String, Int)) { let #(name, count) = item\ncombine(name, \"a moderately long first argument\", count, \"a moderately long second argument\") }) }\n",
    )
  assert string.contains(output, "combine(\n")
  assert list.all(string.split(output, "\n"), fn(line) {
    string.length(line) <= 80
  })
}

pub fn compact_field_initializers_and_empty_bodies_are_preserved_test() {
  assert formatted(
      "module main\nactor Count { var value = 0\nnew() {}\nget() { value } }\n",
    )
    == "module main\n\nactor Count {\n  var value = 0\n\n  new() {}\n\n  get() {\n    value\n  }\n}\n"
}

pub fn layout_snapshot_test() {
  formatted(
    "module main\nimport pooka/list\nclass Counter { let value: Int\nnew(value) { self.value = value }\n/// Read.\nget() { value }\nmap(f) { match f(value) { Some(x) -> x None -> 0 } }\n}\nmain() { list.map([Counter(1),Counter(2)], fn(counter: Counter) { counter.get() }) }\n",
  )
  |> birdie.snap(title: "formatter: declaration and method layout")
}

pub fn wrapping_snapshot_test() {
  formatted(
    "module main\ncalculate(first_value: Int, second_value: Int, third_value: Int, fourth_value: Int) -> Int { combine(first_value, second_value, third_value, fourth_value, \"a long final argument for wrapping\") }\n",
  )
  |> birdie.snap(title: "formatter: long parameters and arguments")
}

pub fn nested_function_types_wrap_without_splitting_short_return_types_test() {
  assert formatted(
      "module main\nexternal Native from erlang \"native\" {\ncreate(factory: fn(fn(k) -> Option(v), fn() -> List(#(k, v)), fn() -> Int, fn(k, Option(v)) -> Storage(k, v)) -> Storage(k, v)) -> Storage(k, v)\n}\n",
    )
    == "module main\n\nexternal Native from erlang \"native\" {\n  create(\n    factory: fn(\n      fn(k) -> Option(v),\n      fn() -> List(#(k, v)),\n      fn() -> Int,\n      fn(k, Option(v)) -> Storage(k, v)\n    ) -> Storage(k, v)\n  ) -> Storage(k, v)\n}\n"
}

pub fn argument_width_boundary_includes_indentation_test() {
  let fitting =
    formatted(
      "module main\nf() { send(\"" <> string.repeat("x", 70) <> "\") }\n",
    )
  assert string.contains(fitting, "  send(\"")
  assert !string.contains(fitting, "send(\n")
  let wrapped =
    formatted(
      "module main\nf() { send(\"" <> string.repeat("x", 71) <> "\") }\n",
    )
  assert string.contains(wrapped, "  send(\n")
  assert list.all(string.split(wrapped, "\n"), fn(line) {
    string.length(line) <= 80
  })
}

pub fn short_binding_patterns_do_not_wrap_because_the_rhs_is_long_test() {
  assert formatted(
      "module main\nf() { let #(value, _) = Input.with_input(\"\\n\", fn() { #(read_line(), read_line(), read_line()) })\nvalue }\n",
    )
    == "module main\n\nf() {\n  let #(value, _) = Input.with_input(\"\\n\", fn() {\n    #(read_line(), read_line(), read_line())\n  })\n  value\n}\n"
}

pub fn already_split_patterns_and_callback_headers_are_compacted_test() {
  assert formatted(
      "module main\ntest \"empty line is not EOF\" {\n  let #(\n    value,\n    _\n  ) = _Input.with_input(\n    \"\\n\",\n    fn() { #(io.read_line(), io.read_line()) }\n  )\n  assert value == #(Ok(Some(\"\\n\")), Ok(None))\n}\n",
    )
    == "module main\n\ntest \"empty line is not EOF\" {\n  let #(value, _) = _Input.with_input(\"\\n\", fn() {\n    #(io.read_line(), io.read_line())\n  })\n  assert value == #(Ok(Some(\"\\n\")), Ok(None))\n}\n"
}

pub fn pattern_comments_are_not_removed_when_compacting_test() {
  let output =
    formatted(
      "module main\nf() { let #(\nvalue, // keep\n_\n) = source()\nvalue }\n",
    )
  assert string.contains(output, "value, // keep\n")
}

pub fn genuinely_long_patterns_remain_wrapped_test() {
  let output =
    formatted(
      "module main\nf() { let #(first_very_long_binding_name, second_very_long_binding_name, third_very_long_binding_name) = source()\nfirst_very_long_binding_name }\n",
    )
  assert string.contains(output, "let #(\n")
  assert list.all(string.split(output, "\n"), fn(line) {
    string.length(line) <= 80
  })
}

pub fn nested_multistatement_callback_followed_by_callback_test() {
  let output =
    formatted(
      "module main\napply(x: Int, f: fn(Int) -> Int) -> Int { f(x) }\nmain() -> Int {\napply(apply(1, fn(a) {\nlet b = a\nb\n}), fn(c) { c })\n}\n",
    )
  assert string.contains(output, "let b = a\n")
  output |> birdie.snap("formatter_nested_callback_arguments")
}

pub fn nested_callback_with_comments_and_trailing_arguments_test() {
  let output =
    formatted(
      "module main\nmain() { transform(filter([1, 2], fn(x) {\n// Keep this statement boundary.\nlet value = x\nvalue > 0\n}), fn(y) { y + 1 }, 3) }\n",
    )
  assert string.contains(output, "// Keep this statement boundary.")
}
