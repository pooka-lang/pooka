//// Answer the small question on the label.
////
//// Render the compiler version without loading a project. A version query should
//// work even outside a package directory.
////
//// ```sh
//// pooka --version
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Outcome, Info}

pub const info =
  Info(name: "-V, --version", arguments: "", summary: "Print the version")

pub fn run(version: String) -> Outcome {
  command.success(text(version))
}

pub fn text(version: String) -> String {
  "pooka " <> version <> "\n"
}
