//// The executable needs one well-marked front door.
////
//// Build OTP and escript entrypoint forms that start the runtime and dispatch to
//// the selected main module. Keep command-line bootstrapping outside user
//// expressions.
////
//// ```text
//// start/0 -> pooka@package@@runtime:run_entry(Application, MainModule)
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/runtime
import compiler/codegen/forms as f

/// Reserve a package-qualified module name for the executable's front door.
///
/// ```text
/// package app -> pooka@app@@entrypoint
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
pub fn module_name(package: String) -> String {
  "pooka@" <> package <> "@@entrypoint"
}

/// Build the OTP start/0 wrapper that starts the application and calls its main
/// module through the runtime.
///
/// ```text
/// {function,1,start,0,[StartClause]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
pub fn forms(package: String, entry: String) -> List(f.Term) {
  let name = module_name(package)
  [
    f.node("attribute", 1, [f.Atom("module"), f.Atom(name)]),
    f.node("attribute", 1, [
      f.Atom("export"),
      f.Sequence([
        f.Tuple([f.Atom("start"), f.Integer(0)]),
      ]),
    ]),
    f.node("function", 1, [
      f.Atom("start"),
      f.Integer(0),
      f.Sequence([
        f.clause(
          [],
          [
            f.remote(
              runtime.name(package),
              "run_entry",
              [f.atom(package, 1), f.atom(entry, 1)],
              1,
            ),
          ],
          1,
        ),
      ]),
    ]),
  ]
}

/// Build main/1 for an escript entrypoint, keeping the archive launcher separate
/// from user main/0.
///
/// ```text
/// {function,1,main,1,[ArgumentClause]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#module-declarations-and-forms.
pub fn escript_forms(package: String, entry: String) -> List(f.Term) {
  [
    f.node("attribute", 1, [
      f.Atom("module"),
      f.Atom(module_name(package) <> "@escript"),
    ]),
    f.node("attribute", 1, [
      f.Atom("export"),
      f.Sequence([f.Tuple([f.Atom("main"), f.Integer(1)])]),
    ]),
    f.node("function", 1, [
      f.Atom("main"),
      f.Integer(1),
      f.Sequence([
        f.clause(
          [f.variable("Arguments", 1)],
          [
            f.remote(
              runtime.name(package),
              "escript_entry",
              [f.atom(package, 1), f.atom(entry, 1), f.variable("Arguments", 1)],
              1,
            ),
          ],
          1,
        ),
      ]),
    ]),
  ]
}
