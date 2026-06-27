//// Hand the completed forms to the Erlang workshop.
////
//// Expose compilation, inspection and execution through a narrow FFI boundary.
//// Real runs inherit descriptors; deterministic compiler tests can capture output
//// through a separate execution path.
////
//// ```text
//// List(forms.Term) -> compile:forms -> BEAM binary
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/codegen/forms.{type Term}

/// Decode and compile the finished forms through Erlang's compiler. Return the
/// BEAM binary or formatted compiler errors.
///
/// ```text
/// checked forms -> compile:forms -> Ok(beam)
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
@external(erlang, "pooka_beam_ffi", "compile")
pub fn compile(forms: List(Term)) -> Result(BitArray, String)

/// Render abstract forms as Erlang source for inspection; this does not make .erl
/// files a required build artifact.
///
/// ```text
/// {integer,1,42} in a form -> readable Erlang source
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
@external(erlang, "pooka_beam_ffi", "pretty")
pub fn pretty(forms: List(Term)) -> String

/// Load the runtime helper's compiled object code for inclusion in a built
/// application.
///
/// ```text
/// runtime module -> BEAM payload
/// ```
@external(erlang, "pooka_beam_ffi", "runtime_binary")
pub fn runtime_binary() -> Result(BitArray, String)

/// Specialize the embedded helper for one package without emitting Erlang files.
///
/// ```text
/// shapes -> BEAM module pooka@shapes@@runtime
/// ```
@external(erlang, "pooka_beam_ffi", "runtime_binary_for")
pub fn runtime_binary_for(package: String) -> Result(BitArray, String)

/// Run in a fresh VM with deterministic combined capture, primarily for compiler
/// test helpers. Real interactive CLI execution uses execute_inherited.
///
/// ```text
/// compiled main -> captured output or failure text
/// ```
@external(erlang, "pooka_beam_ffi", "execute")
pub fn execute(
  directory: String,
  module: String,
  arguments: List(String),
  colour: Bool,
) -> Result(String, String)

pub type TestFailure {
  TestFailure(
    output: String,
    reason: String,
    details: List(#(String, String)),
    stacktrace: String,
  )
}

pub type TestRun {
  TestRun(outcome: Result(String, TestFailure), duration: Int)
}

pub type TestVm

/// Start an isolated test VM under the requested colour policy.
///
/// ```text
/// start VM -> run selected tests -> stop VM
/// ```
@external(erlang, "pooka_beam_ffi", "start_test_vm")
pub fn start_test_vm(colour: Bool) -> TestVm

/// Close a test VM handle after its work. Keep VM lifecycle at the caller that
/// opened it.
///
/// ```text
/// completed or empty test batch -> stop VM
/// ```
@external(erlang, "pooka_beam_ffi", "stop_test_vm")
pub fn stop_test_vm(vm: TestVm) -> Nil

/// Run selected module/function pairs and recover per-test outcome and timing
/// frames.
///
/// ```text
/// [(module, test)] -> [TestRun]
/// ```
@external(erlang, "pooka_beam_ffi", "execute_tests")
pub fn execute_tests(
  vm: TestVm,
  directory: String,
  tests: List(#(String, String)),
) -> List(TestRun)

/// Encode forms for the .abstr debug artifact. The payload is an Erlang external
/// term, not textual Erlang.
///
/// ```text
/// forms -> term_to_binary -> .abstr artifact
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
@external(erlang, "pooka_beam_ffi", "abstract_forms")
pub fn abstract_forms(forms: List(Term)) -> BitArray

/// Fingerprint the compiler/runtime inputs that influence generated artifacts.
///
/// ```text
/// changed compiler module -> changed build fingerprint
/// ```
@external(erlang, "pooka_beam_ffi", "build_fingerprint")
pub fn build_fingerprint() -> BitArray

/// Render an Erlang resource term for application packaging.
///
/// ```text
/// application term -> textual .app resource
/// ```
@external(erlang, "pooka_beam_ffi", "resource")
pub fn resource(term: Term) -> String

/// Check that an existing BEAM payload belongs to the expected module before
/// reusing it.
///
/// ```text
/// wrong module identity -> False
/// ```
@external(erlang, "pooka_beam_ffi", "valid_module")
pub fn valid_module(binary: BitArray, name: String) -> Bool

/// Compile a foreign Erlang source file and return its declared module name with
/// the binary.
///
/// ```text
/// ffi/helper.erl -> Ok(#(name, beam))
/// ```
@external(erlang, "pooka_beam_ffi", "compile_foreign_erlang")
pub fn compile_foreign_erlang(
  path: String,
) -> Result(#(String, BitArray), String)

pub type CompilerError {

  MissingCompiler

  CompilerFailed(output: String)
}

/// Run a supported foreign compiler and collect the BEAM files it produces.
///
/// ```text
/// tool + args + output directory -> named BEAM payloads
/// ```
@external(erlang, "pooka_beam_ffi", "run_foreign_compiler")
pub fn run_foreign_compiler(
  program: String,
  arguments: List(String),
  beams: String,
) -> Result(List(#(String, BitArray)), CompilerError)

/// Run a fresh VM inheriting stdin, stdout and stderr, and return its actual exit
/// status. Prompts are visible before input arrives.
///
/// ```text
/// pooka run -> child descriptors 0/1/2 -> Ok(exit_status)
/// ```
@external(erlang, "pooka_beam_ffi", "execute_inherited")
pub fn execute_inherited(
  directory: String,
  module: String,
  arguments: List(String),
  colour: Bool,
) -> Result(Int, String)
