//// Keep the checked manuscript behind a modest gate.
////
//// Wrap syntax together with a successful inference report and source path. Code
//// generation receives this checked bundle instead of treating a tree with type
//// errors as ready to emit.
////
//// ```text
//// inference diagnostics contain an error -> checked returns Error
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import compiler/typesystem/module_infer
import diagnostics/diagnostic

pub opaque type Module {
  Module(syntax: ast.Module, inferred: module_infer.Module, path: String)
}

/// Construct the opaque checked bundle only after inference has no error
/// diagnostics. This is the emitter's entrance ticket.
///
/// ```text
/// errors present -> Error(diagnostics); otherwise syntax + report + path
/// ```
pub fn checked(
  syntax: ast.Module,
  inferred: module_infer.Module,
  path: String,
) -> Result(Module, List(diagnostic.Diagnostic)) {
  case diagnostic.has_errors(inferred.diagnostics) {
    True -> Error(inferred.diagnostics)
    False -> Ok(Module(syntax, inferred, path))
  }
}

/// Read syntax from an already checked bundle.
///
/// ```text
/// checked module -> original declaration tree
/// ```
pub fn syntax(module: Module) -> ast.Module {
  module.syntax
}

/// Read the inference report associated with this exact syntax bundle.
///
/// ```text
/// checked module -> resolved types and nominal metadata
/// ```
pub fn inferred(module: Module) -> module_infer.Module {
  module.inferred
}

/// Read the source path carried across the checked boundary.
///
/// ```text
/// checked module -> the path used by emitted source annotations
/// ```
pub fn path(module: Module) -> String {
  module.path
}
