//// Each package has its own address in the HexDocs reading room.
////
//// DNS labels use hyphens where Hex package names use underscores. Share this
//// conversion between README templates and publication messages.
////
//// ```text
//// pooka_stdlib -> https://pooka-stdlib.hexdocs.pm/
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/string

pub fn url(package: String) -> String {
  "https://" <> string.replace(package, "_", "-") <> ".hexdocs.pm/"
}
