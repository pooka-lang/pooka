//// Every artifact needs an address, especially after midnight.
////
//// Centralize development and production output paths. Builders ask this module
//// for directories instead of inventing slightly different layouts of their own.
////
//// ```text
//// build/dev/erlang/<package>/ebin/<module>.beam
//// ```

// SPDX-License-Identifier: Apache-2.0

import filepath

pub type Mode {
  Development
  Production
}

pub type Layout {
  Layout(
    target: String,
    package: String,
    ebin: String,
    artifacts: String,
    include: String,
    application: String,
    fingerprint: String,
    module_manifest: String,
  )
}

pub fn mode_name(mode: Mode) -> String {
  case mode {
    Development -> "dev"
    Production -> "prod"
  }
}

pub fn erlang(root: String, name: String, mode: Mode) -> Layout {
  let target = filepath.join(root, "build/" <> mode_name(mode) <> "/erlang")
  let package = filepath.join(target, name)
  let ebin = filepath.join(package, "ebin")
  let artifacts = filepath.join(package, "_pooka_artefacts")
  Layout(
    target,
    package,
    ebin,
    artifacts,
    filepath.join(package, "include"),
    filepath.join(ebin, name <> ".app"),
    filepath.join(target, "fingerprint"),
    filepath.join(artifacts, "modules"),
  )
}

pub fn beam(layout: Layout, module: String) -> String {
  filepath.join(layout.ebin, module <> ".beam")
}

pub fn abstract_forms(layout: Layout, module: String) -> String {
  filepath.join(layout.artifacts, module <> ".abstr")
}
