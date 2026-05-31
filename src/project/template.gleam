//// Lay out a new project's first few pages.
////
//// Generate the manifest, source module, starter test and supporting files from a
//// validated package name. Return file contents before the caller writes them to
//// disk.
////
//// ```text
//// app -> pooka.toml, src/main.pooka, test/main.spec.pooka
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/uri
import project/hexdocs

pub fn directories() -> List(String) {
  ["src", "test", ".github", ".github/workflows"]
}

pub fn files(name: String) -> List(#(String, String)) {
  [
    #("pooka.toml", manifest(name)),
    #("src/main.pooka", main_module(name)),
    #("test/main.spec.pooka", main_spec()),
    #("README.md", readme(name)),
    #(".gitignore", gitignore()),
    #(".github/workflows/test.yml", github_workflow()),
  ]
}

/// The starter manifest. Optional package metadata is included as comments,
/// so a new project builds as-is and each field can be enabled by deleting
/// its `# `. The standard library is an active Hex dependency; its own package
/// template omits that declaration to avoid depending on itself.
pub fn manifest(name: String) -> String {
  "name = \""
  <> name
  <> "\"\nversion = \"1.0.0\"\n"
  <> "\n# A one-line summary, shown on Hex and in the generated documentation.\n"
  <> "# description = \"A Pooka project\"\n"
  <> "\n# The people who made it, shown in the generated documentation.\n"
  <> "# authors = [\"Your Name\"]\n"
  <> "\n# SPDX licence identifiers, for example \"Apache-2.0\" or \"MIT\".\n"
  <> "# licences = [\"Apache-2.0\"]\n"
  <> "\n# Where the source lives. `type` is github, gitlab, bitbucket, codeberg,\n"
  <> "# sourcehut, tangled, gitea or forgejo (with `host`), or custom (with `url`).\n"
  <> "# repository = { type = \"github\", user = \"your-name\", repo = \""
  <> name
  <> "\" }\n"
  <> "\n# Extra links for Hex and the documentation sidebar.\n"
  <> "# links = [\n"
  <> "#   { title = \"Website\", href = \"https://example.com\" },\n"
  <> "# ]\n"
  <> "\n[dependencies]\n"
  <> case name {
    "pooka_stdlib" -> ""
    _ -> "pooka_stdlib = \">= 0.1.0 and <= 1.0.0\"\n"
  }
  <> "# Add packages with `pooka add <package>`, or declare them here.\n"
  <> "# A package in a local directory:\n"
  <> "# helper = { path = \"../helper\" }\n"
  <> "# A Git repository, at one branch, tag or rev:\n"
  <> "# parser = { git = \"https://github.com/your-name/parser\", tag = \"v1.0.0\" }\n"
  <> "\n[dev-dependencies]\n"
  <> "# Packages used only by tests, declared the same way:\n"
  <> "# test_helpers = { path = \"../test_helpers\" }\n"
  <> "\n# Extra Markdown pages for `pooka docs`, one block per page:\n"
  <> "# [[documentation.pages]]\n"
  <> "# title = \"Guide\"\n"
  <> "# path = \"guide.html\"\n"
  <> "# source = \"docs/guide.md\"\n"
}

pub fn main_module(name: String) -> String {
  "module main\n\nmain() {\n  echo \"Hello from " <> name <> "!\"\n}\n"
}

/// Give the new project a small, passing test before its first change.
///
/// ```pooka
/// test "one plus one is two" {
///   assert 1 + 1 == 2
/// }
/// ```
pub fn main_spec() -> String {
  "module main_test\n\ntest \"one plus one is two\" {\n  assert 1 + 1 == 2\n}\n"
}

/// Leave publication status to the badge services rather than freezing it at
/// project creation. Hex's version badge reports `not found` for a missing
/// package, then its published version in purple. HexDocs checks the actual
/// documentation URL: grey `not found` before publication, orange `docs` after.
/// Both links always point to the package's own public pages.
pub fn readme(name: String) -> String {
  "# " <> name <> "

[![Package Version](https://img.shields.io/hexpm/v/" <> name <> "?style=for-the-badge&color=75618E)](https://hex.pm/packages/" <> name <> ")
[![Hex Docs](https://img.shields.io/website?url=" <> uri.percent_encode(
    hexdocs.url(name),
  ) <> "&style=for-the-badge&label=hex&up_message=docs&up_color=FF891F&down_message=not%20found&down_color=lightgrey)](" <> hexdocs.url(
    name,
  ) <> ")
[![Tests](https://img.shields.io/github/actions/workflow/status/YOUR_USERNAME/" <> name <> "/test.yml?style=for-the-badge&label=tests)](https://github.com/YOUR_USERNAME/" <> name <> "/actions/workflows/test.yml)

<!-- Replace YOUR_USERNAME with your GitHub account or organisation. -->

```sh
pooka add " <> name <> "
```

```pooka
import " <> name <> "

main() {
  // TODO: An example of the project in use
}
```

Further documentation can be found at <" <> hexdocs.url(name) <> ">.

## Development

```sh
pooka run   # Run the project
pooka test  # Run the tests
```
"
}

pub fn gitignore() -> String {
  "/build\n*.beam\n*.ez\nerl_crash.dump\n.DS_Store\n"
}

/// Check the package using a released compiler, with Erlang supplied separately.
pub fn github_workflow() -> String {
  "name: test

on:
  push:
    branches: [main, master]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
      - uses: erlef/setup-beam@v1
        with:
          otp-version: \"29\"
          rebar3-version: \"3\"
          # gleam-version: \"1.19.0\"
          # elixir-version: \"1\"
      - uses: peregrinefinch/setup-pooka@v1
        with:
          pooka-version: \"0.1.0\"
      - run: pooka deps download
      - run: pooka test
      - run: pooka format --check
"
}
