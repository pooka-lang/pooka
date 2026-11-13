//// Start at the porch and let the command layer answer the knock.
////
//// Provide the compiler version and executable entrypoint. Argument handling,
//// terminal detection and exit behavior belong to the CLI modules rather than
//// this small boot function.
////
//// ```text
//// pooka --help -> cli.cli(version)
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/cli

pub const version = "0.2.0"

pub fn main() -> Nil {
  cli.cli(version)
}
