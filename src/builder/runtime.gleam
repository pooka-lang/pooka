//// Every package brings its own small lantern.
////
//// The compiler carries one runtime template and specializes its module name
//// for each package. Double @ reserves a namespace that ordinary source modules
//// cannot occupy. Libraries need neither a shared OTP app nor a Hex dependency.
////
//// ```text
//// package shapes -> pooka@shapes@@runtime
//// package argv   -> pooka@argv@@runtime
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/codegen/forms as f
import gleam/list

pub fn name(package: String) -> String {
  "pooka@" <> package <> "@@runtime"
}

/// Rewrite the compiler-private runtime atom in generated forms. Character data
/// remains unchanged: printing "pooka_runtime_ffi" must still print that string.
///
/// ```erlang
/// pooka_runtime_ffi:echo(Value) -> 'pooka@shapes@@runtime':echo(Value)
/// ```
/// https://www.erlang.org/doc/apps/erts/absform.html#expressions
pub fn scope(forms: List(f.Term), package: String) -> List(f.Term) {
  list.map(forms, replace(_, name(package)))
}

fn replace(term: f.Term, module: String) -> f.Term {
  case term {
    f.Tuple([
      f.Atom("remote"),
      annotation,
      f.Tuple([f.Atom("atom"), module_annotation, f.Atom("pooka_runtime_ffi")]),
      function,
    ]) ->
      f.Tuple([
        f.Atom("remote"),
        annotation,
        f.Tuple([f.Atom("atom"), module_annotation, f.Atom(module)]),
        replace(function, module),
      ])
    f.Tuple([
      f.Atom("function"),
      f.Tuple([f.Atom("atom"), annotation, f.Atom("pooka_runtime_ffi")]),
      function,
      arity,
    ]) ->
      f.Tuple([
        f.Atom("function"),
        f.Tuple([f.Atom("atom"), annotation, f.Atom(module)]),
        replace(function, module),
        arity,
      ])
    f.Tuple(items) -> f.Tuple(list.map(items, replace(_, module)))
    f.Sequence(items) -> f.Sequence(list.map(items, replace(_, module)))
    _ -> term
  }
}
