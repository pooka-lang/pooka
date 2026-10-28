//// Small library examples can expose large compiler assumptions.
////
//// Retain regressions discovered while implementing the standard library:
//// combining marks, generic factories and contextual callback types. Real CLI
//// subprocesses also check Unicode input, separate output streams, EOF and
//// prompts that must appear before input is supplied.

import cli/command
import compiler/lexer/lexer
import compiler/lexer/token
import compiler/typesystem/module_infer
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string as gleam_string
import support

// A leading combining mark still has bytes and meaning. The lexer must not
// lose it by treating grapheme boundaries as character boundaries.
pub fn raw_leading_combining_marks_are_preserved_test() {
  list.each(["́", "️", "́abc", "", "🐇é"], fn(value) {
    assert support.tokens("\"" <> value <> "\"") == [token.String(value)]
  })
}

pub fn unterminated_combining_literal_preserves_content_test() {
  let report = lexer.lex("\"́")
  assert list.length(report.errors) == 1
  assert support.tokens("\"́") == [token.String("́")]
}

pub fn generic_method_can_call_annotated_same_module_factory_test() {
  assert diagnostic_ids(
      "module main\nclass Box(a) { let value: a\nnew(value: a) { self.value = value }\nmap(transform: fn(a) -> b) -> Box(b) { make(transform(value)) } }\nmake(value: a) -> Box(a) { Box(value) }\nmain() { #(Box(1).map(fn(n) { n == 1 }).value, make(\"ok\").value) }",
    )
    == []
}

pub fn factory_annotation_still_checks_its_implementation_test() {
  assert diagnostic_ids(
      "module main\nclass Box(a) { let value: a\nnew(value: a) { self.value = value }\nmap(transform: fn(a) -> b) -> Box(b) { make(transform(value)) } }\nmake(value: a) -> Box(a) { Box(1) }",
    )
    != []
}

// The expected callback parameter type must reach the closure before member
// lookup. Otherwise a valid element method looks unknown simply because
// inference arrived late.
pub fn callback_receives_element_type_before_member_lookup_test() {
  assert diagnostic_ids(
      "module main\nclass User(name: String)\napply(value: a, transform: fn(a) -> b) -> b { transform(value) }\nmain() { apply(User(\"Ada\"), fn(user) { user.name }) }",
    )
    == []
}

pub fn callback_result_is_still_checked_test() {
  assert diagnostic_ids(
      "module main\nclass User(name: String)\napply(value: a, transform: fn(a) -> Int) -> Int { transform(value) }\nmain() { apply(User(\"Ada\"), fn(user) { user.name }) }",
    )
    != []
}

pub fn raw_unicode_and_factory_callbacks_execute_test() {
  use directory <- support.with_directory("stdlib_bug_regressions")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nclass Box(a) { let value: a\nnew(value: a) { self.value = value }\nmap(transform: fn(a) -> b) -> Box(b) { make(transform(value)) } }\nmake(value: a) -> Box(a) { Box(value) }\napply(value: a, transform: fn(a) -> b) -> b { transform(value) }\nmain() { assert \"́\" == \"\\u{301}\"\necho apply(Box(1).map(fn(n) { n == 1 }), fn(box) { box.value }) }",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert outcome.status == 0
  assert outcome.stdout == "True\n"
}

fn diagnostic_ids(source: String) -> List(String) {
  let assert Ok(report) =
    module_infer.infer(
      support.parse(source),
      dict.new(),
      unify.new(),
      support.path,
    )
  list.map(report.diagnostics, fn(error) { error.id })
}

@external(erlang, "shipment_test_ffi", "run_cli_stdio")
fn run_cli_stdio(
  arguments: List(String),
  directory: String,
  input: String,
) -> #(Int, String, String)

fn with_io_project(name: String, body: fn(String) -> a) -> a {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Io from erlang \"stdio_helper\" { read() -> String\nwrite(value: String) -> Nil\nerror() -> Nil }\nmain() { let value = Io.read()\nIo.write(value)\nIo.error() }",
  )
  support.write(
    directory <> "/ffi/stdio_helper.erl",
    "-module(stdio_helper).\n-export([read/0,write/1,error/0]).\nread() -> case io:get_line(\"Prompt: \") of eof -> <<\"EOF\">>; Text -> unicode:characters_to_binary(Text) end.\nwrite(Value) -> io:put_chars(Value), nil.\nerror() -> io:put_chars(standard_error, \"error stream\"), nil.",
  )
  body(directory)
}

pub fn run_keeps_streams_separate_and_forwards_unicode_input_test() {
  use directory <- with_io_project("run_unicode_stdio")
  let #(status, output, errors) = run_cli_stdio(["run"], directory, "🐇é\n")
  assert status == 0
  assert output == "Prompt: 🐇é\n"
  assert gleam_string.contains(errors, "error stream")
  assert !gleam_string.contains(output, "error stream")
  assert gleam_string.contains(errors, "Running")
}

pub fn run_forwards_eof_test() {
  use directory <- with_io_project("run_eof_stdio")
  let #(status, output, _) = run_cli_stdio(["run"], directory, "")
  assert status == 0
  assert output == "Prompt: EOF"
}

pub fn run_preserves_nonzero_exit_status_test() {
  use directory <- with_io_project("run_exit_stdio")
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Os from erlang \"erlang\" { halt(status: Int) -> Nil }\nmain() { Os.halt(7) }",
  )
  let #(status, _, _) = run_cli_stdio(["run"], directory, "")
  assert status == 7
}

@external(erlang, "shipment_test_ffi", "run_cli_prompt")
fn run_cli_prompt(directory: String, input: String) -> #(Int, String)

// Wait for the prompt before sending input. A runner that buffers all output
// until exit would deadlock this conversation rather than pass the test.
pub fn run_streams_prompt_before_input_is_supplied_test() {
  use directory <- with_io_project("run_live_prompt")
  let #(status, output) = run_cli_prompt(directory, "42\n")
  assert status == 0
  assert gleam_string.contains(output, "Prompt: 42\n")
}
