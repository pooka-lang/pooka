//// One mailbox, one owner of the state.
////
//// Follow actor declarations from inferred protocols to running BEAM
//// processes. Requests return a value; behaviors enqueue work and return Nil.
//// The tests keep ordering, isolated state, captured snapshots and failed
//// construction separate, so a reference is never mistaken for direct access
//// to its owner.
////
//// ```text
//// behavior -> enqueue and return
//// request  -> wait for the reply or observe failure
//// ```

import birdie
import cli/command
import compiler/codegen/beam
import compiler/codegen/erlang
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/typed_ast
import compiler/typesystem/unify
import gleam/dict
import gleam/list
import gleam/string
import support

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

const counter =
  "actor Counter { var count = 0\nbe increment() { count += 1\nNil }\nvalue() { count } }\n"

// The same actor offers two kinds of protocol entry. Keep request results
// visible to inference while a behavior call reports Nil to its sender.
pub fn actor_protocols_infer_request_and_behavior_results_test() {
  let report =
    check(
      counter
      <> "main() { echo { let counter = Counter.new()\n#(counter.increment(), counter.value()) } }",
    )
  assert report.diagnostics == []
  let assert [main] = report.functions
  assert monotype.to_string(main.type_) == "fn() -> #(Nil, Int)"
}

pub fn actor_fields_are_isolated_and_unknown_messages_are_errors_test() {
  assert ids(counter <> "main() { echo { Counter.new().count } }")
    == ["type.actor_field_access"]
  assert ids(counter <> "main() { echo { Counter.new().missing() } }")
    == ["type.unknown_member"]
}

pub fn behavior_bodies_must_evaluate_to_nil_test() {
  assert ids("actor Bad { be run() { 42 } }") != []
}

pub fn actor_state_updates_preserve_types_test() {
  assert ids("actor Bad { var count = 0\nupdate() { count = \"bad\" } }")
    == ["type.unification"]
}

pub fn generic_actor_constructors_preserve_parameter_types_test() {
  assert ids(
      "actor Cell(a) { var value: a\nnew(value) { self.value = value }\nset(next: a) { value = next }\nget() -> a { value } }\nmain() { echo { let cell = Cell.new(42)\ncell.set(\"bad\") } }",
    )
    == ["type.unification"]
}

fn run(name: String, source: String) -> command.Outcome {
  use directory <- support.with_directory(name)
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n" <> source)
  support.cli_main(["run"], command.plain(directory))
}

fn output(name: String, source: String) -> String {
  let outcome = run(name, source)
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
  outcome.stdout
}

pub fn behaviors_are_ordered_before_a_following_request_test() {
  assert output(
      "actor_counter",
      counter
        <> "main() { echo { let counter = Counter.new()\ncounter.increment()\ncounter.increment()\ncounter.value() } }",
    )
    == "2\n"
}

pub fn actor_initialization_and_local_methods_execute_test() {
  assert output(
      "actor_local",
      "actor Counter { let name: String\nvar count: Int\nnew(name, count) { self.name = name\nself.count = count }\nadd(value: Int) { count += value }\nwork() { add(2)\n#(name, count) } }\nmain() { echo { Counter.new(\"counter\", 40).work() } }",
    )
    == "#(\"counter\", 42)\n"
}

pub fn actor_references_have_identity_equality_test() {
  assert output(
      "actor_identity",
      counter
        <> "main() { echo { let first = Counter.new()\nlet second = Counter.new()\n#(first == first, first == second) } }",
    )
    == "#(True, False)\n"
}

pub fn actor_interface_calls_are_synchronous_test() {
  assert output(
      "actor_interface",
      "interface Resettable { reset() -> Nil }\nactor Counter with Resettable { var count = 0\nbe increment() { count += 1 }\nreset() { count = 0 }\nvalue() { count } }\nreset(value: Resettable) { value.reset() }\nmain() { echo { let counter = Counter.new()\ncounter.increment()\nreset(counter)\ncounter.value() } }",
    )
    == "0\n"
}

pub fn actor_state_diagnostics_snapshot_test() {
  let report = check(counter <> "main() { Counter.new().count }")
  support.pretty(report.diagnostics)
  |> birdie.snap(title: "types actor field isolation")
}

pub fn actor_references_are_distinct_from_raw_pids_test() {
  assert ids(
      counter
      <> "pid(value: Pid) { Nil }\nmain() { echo { pid(Counter.new()) } }",
    )
    == ["type.unification"]
  assert ids(
      counter
      <> "use_counter(value: Counter) { value.value() }\nmain() { echo { use_counter(Counter.new()) } }",
    )
    == []
}

pub fn behaviours_do_not_implement_synchronous_interface_requirements_test() {
  assert ids(
      "interface Resettable { reset() -> Nil }\nactor Counter with Resettable { be reset() { Nil } }",
    )
    == ["type.missing_interface_method"]
}

// A closure leaves the owning process carrying the field values it saw. Later
// state changes must not turn that captured snapshot into a remote mutable
// reference.
pub fn actor_closures_capture_immutable_field_snapshots_test() {
  assert output(
      "actor_snapshot",
      "actor Counter { var count = 1\nread() { fn() { count } }\nset(value: Int) { count = value } }\nmain() { let counter = Counter.new()\nlet read = counter.read()\ncounter.set(42)\necho #(read(), counter.read()()) }",
    )
    == "#(1, 42)\n"
  assert ids(
      "actor Counter { var count = 0\nchange() { fn() { count += 1 } } }",
    )
    == ["type.actor_state_assignment"]
}

pub fn actor_method_references_and_first_class_constructors_execute_test() {
  assert output(
      "actor_references",
      counter
        <> "main() { echo { let start = Counter.new\nlet counter = start()\nlet increment = counter.increment\nlet read = counter.value\nincrement()\nincrement()\nread() } }",
    )
    == "2\n"
}

// Calling a behavior from its owner still goes through the mailbox. Running
// it inline would change ordering relative to already queued work.
pub fn owner_behavior_calls_enqueue_instead_of_running_inline_test() {
  assert output(
      "actor_owner_behaviors",
      "actor Counter { var count = 0\nbe increment() { count += 1 }\nqueue() { increment()\ncount }\nvalue() { count } }\nmain() { echo { let counter = Counter.new()\nlet before = counter.queue()\n#(before, counter.value()) } }",
    )
    == "#(0, 1)\n"
}

pub fn actor_updates_support_branches_loops_and_parameter_shadowing_test() {
  assert output(
      "actor_control_flow",
      "actor Counter { var count = 0\nrun(flag: Bool) { match flag { True -> count += 1\nFalse -> count += 10 }\nloop { match count < 42 { True -> count += 1\nFalse -> break } }\ncount }\nshadow(count: String) { count } }\nmain() { echo { let counter = Counter.new()\n#(counter.run(True), counter.shadow(\"shadow\")) } }",
    )
    == "#(42, \"shadow\")\n"
}

pub fn immutable_actor_configuration_cannot_be_mutated_test() {
  assert ids(
      "actor Counter { let label = \"counter\"\nchange() { label = \"other\" } }",
    )
    == ["type.actor_state_assignment"]
}

pub fn actor_references_cannot_destructure_actor_state_test() {
  assert ids(
      counter
      <> "main() { echo { let assert Counter(value) = Counter.new()\nvalue } }",
    )
    == ["type.actor_pattern"]
}

// The sender must not wait for the asynchronous handler to finish. This
// distinguishes sending a behavior from making a synchronous request.
pub fn behaviors_return_before_their_handler_finishes_test() {
  use directory <- support.with_directory("actor_nonblocking")
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/ffi/gate.erl",
    "-module(gate).\n-export([wait/0, release/1]).\nwait() -> receive release -> nil after 5000 -> erlang:error(behavior_did_not_return) end.\nrelease({'$pooka_actor', _, _, Pid}) -> Pid ! release, nil.\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Gate from erlang \"gate\" { wait() -> Nil\nrelease(counter: Counter) -> Nil }\nactor Counter { var count = 0\nbe pause() { Gate.wait()\ncount += 1 }\nvalue() { count } }\nmain() { echo { let counter = Counter.new()\ncounter.pause()\nGate.release(counter)\ncounter.value() } }",
  )
  let outcome = support.cli_main(["run"], command.plain(directory))
  assert support.diagnostics(outcome.stderr) == ""
  assert outcome.status == 0
  assert outcome.stdout == "1\n"
}

// A failed handler must close the waiting conversation. A monitor or reply
// failure should reach the caller rather than leave it waiting forever.
pub fn request_failure_is_observed_without_hanging_the_caller_test() {
  let outcome =
    run(
      "actor_failure",
      "actor Worker { fail() { panic as \"worker failed\" } }\nmain() { echo { Worker.new().fail() } }",
    )
  assert outcome.status == 1
  assert string.contains(
    outcome.stderr,
    "the actor stopped before replying: panic: worker failed",
  )
}

// Do not hand out an actor reference before initialization succeeds.
// Otherwise the caller receives an address for a process that never became
// ready.
pub fn constructor_failure_is_observed_before_publishing_a_reference_test() {
  let outcome =
    run(
      "actor_initializer_failure",
      "actor Worker { new() { panic as \"initialization failed\" } }\nmain() { echo { Worker.new() } }",
    )
  assert outcome.status == 1
  assert string.contains(
    outcome.stderr,
    "the actor failed to start: panic: initialization failed",
  )
}

// An early Result return ends one request, not the actor process. The next
// request must still observe a live owner with consistent state.
pub fn result_propagation_preserves_actor_state_and_process_liveness_test() {
  assert output(
      "actor_result",
      "actor Counter { var count = 0\nadd(value: Result(Int, String)) -> Result(Int, String) { let number = value?\ncount += number\nOk(count) }\nvalue() { count } }\nmain() { echo { let counter = Counter.new()\n#(counter.add(Error(\"missing\")), counter.add(Ok(42)), counter.value()) } }",
    )
    == "#(Error(\"missing\"), Ok(42), 42)\n"
}

pub fn independent_actor_processes_do_not_share_state_test() {
  assert output(
      "actor_isolated",
      counter
        <> "main() { echo { let first = Counter.new()\nlet second = Counter.new()\nfirst.increment()\n#(first.value(), second.value()) } }",
    )
    == "#(1, 0)\n"
}

pub fn generic_actor_protocols_execute_with_independent_state_types_test() {
  assert output(
      "actor_generic",
      "actor Cell(a) { var value: a\nnew(value) { self.value = value }\nset(next: a) { value = next }\nget() -> a { value } }\nmain() { echo { let number = Cell.new(1)\nlet text = Cell.new(\"before\")\nnumber.set(42)\ntext.set(\"after\")\n#(number.get(), text.get()) } }",
    )
    == "#(42, \"after\")\n"
}

pub fn private_actor_protocol_members_are_checked_lexically_test() {
  assert ids(
      "actor Counter { _read() { 42 }\nread() { _read() } }\nmain() { echo { Counter.new()._read() } }",
    )
    == ["type.private_member"]
  assert output(
      "actor_private",
      "actor Counter { var count = 0\n_set(value: Int) { count = value }\nbe set(value: Int) { _set(value) }\nread() { count } }\nmain() { echo { let counter = Counter.new()\ncounter.set(42)\ncounter.read() } }",
    )
    == "42\n"
}

pub fn actor_constructor_loops_initialize_state_in_the_owning_process_test() {
  assert output(
      "actor_constructor_loop",
      "actor Counter { var count: Int\nnew() { loop { self.count = 42\nbreak } }\nvalue() { count } }\nmain() { echo { Counter.new().value() } }",
    )
    == "42\n"
}

/// Actor syntax lowers to generated functions that call the runtime protocol.
/// The snapshot includes the remote-call structure illustrated schematically
/// below; Args stands for the list of already lowered argument expressions.
///
/// ```erlang
/// {call, Anno, {remote, Anno,
///   {atom, Anno, pooka_runtime_ffi}, {atom, Anno, actor_start}}, Args}
/// ```
///
/// Erlang function declarations and calls:
/// https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms
/// https://www.erlang.org/doc/apps/erts/absform.html#expressions
pub fn actor_protocol_abstract_forms_snapshot_test() {
  let syntax =
    support.parse(
      "module main\n"
      <> counter
      <> "main() { let counter = Counter.new()\ncounter.increment()\ncounter.value() }",
    )
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  assert inferred.diagnostics == []
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  let assert Ok(generated) = erlang.generate(typed, "app", "main", dict.new())
  let assert Ok(_) = beam.compile(generated.forms)
  birdie.snap(
    beam.pretty(generated.forms),
    title: "codegen actor protocol abstract forms",
  )
}
