//// Share one corridor with neighbouring BEAM toolchains.
////
//// Stage and compile native packages through their own supported build tools.
//// Keep package ownership and cached output locations explicit when crossing that
//// boundary.
////
//// ```text
//// dependency source -> native build -> application artifacts
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/list
import gleam/result
import project/dependency as d
import project/project.{type Project}

pub fn application(package: Project) -> String {
  project.application_name(package)
}

pub fn applications(
  requirements: List(d.Dependency),
  packages: List(Project),
) -> List(String) {
  requirements
  |> list.filter_map(fn(dep) {
    list.find(packages, fn(p) { p.name == dep.name }) |> result.map(application)
  })
  |> list.unique
}

pub fn compile(
  package: Project,
  library: String,
) -> Result(#(List(#(String, BitArray)), String), String) {
  compile_with(
    package,
    library,
    list.map(package.dependencies, fn(dep) { dep.name }),
  )
}

fn compile_with(
  package: Project,
  library: String,
  dependencies: List(String),
) -> Result(#(List(#(String, BitArray)), String), String) {
  let assert d.Beam(app, tools) = package.kind
  build(
    package.root,
    library,
    package.name,
    app,
    package.version,
    tools,
    dependencies,
  )
}

pub fn compile_cached(
  package: Project,
  library: String,
  path: String,
  key: BitArray,
  packages: List(Project),
) -> Result(#(#(List(#(String, BitArray)), String), Bool), String) {
  cached(path, key, library, application(package), fn() {
    compile_with(package, library, applications(package.dependencies, packages))
  })
}

@external(erlang, "pooka_incremental_ffi", "native")
fn cached(
  path: String,
  key: BitArray,
  library: String,
  application: String,
  run: fn() -> Result(#(List(#(String, BitArray)), String), String),
) -> Result(#(#(List(#(String, BitArray)), String), Bool), String)

pub fn stage_pooka(
  project: Project,
  library: String,
  modules: List(#(String, BitArray)),
  resource: String,
) -> Result(Nil, String) {
  stage(library, project.name, modules, resource)
}

@external(erlang, "pooka_package_ffi", "native_build")
fn build(
  root: String,
  library: String,
  name: String,
  application: String,
  version: String,
  tools: List(String),
  dependencies: List(String),
) -> Result(#(List(#(String, BitArray)), String), String)

@external(erlang, "pooka_package_ffi", "stage_library")
fn stage(
  library: String,
  name: String,
  modules: List(#(String, BitArray)),
  resource: String,
) -> Result(Nil, String)

@external(erlang, "pooka_package_ffi", "native_directory")
pub fn directory(target: String) -> Result(String, String)

@external(erlang, "pooka_package_ffi", "using_directory")
pub fn using_directory(directory: String, run: fn() -> a) -> a

/// Keep native private files beside their application, including on cached builds.
@external(erlang, "pooka_package_ffi", "stage_assets")
pub fn stage_assets(
  library: String,
  application: String,
  destination: String,
) -> Result(Nil, String)
