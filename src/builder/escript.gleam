//// Pack a runnable program into one travelling case.
////
//// Export compiled application modules and their dependencies as an escript. The
//// generated entrypoint starts the application's runtime before calling main.
////
//// ```text
//// pooka export escript -> build/<package>
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import builder/shipment
import compiler/codegen/beam
import compiler/codegen/entrypoint
import diagnostics/diagnostic
import filepath
import gleam/result
import simplifile

pub type Report {
  Report(build: build.Report, path: String)
}

pub fn export(directory: String) -> Result(Report, build.Failure) {
  use shipped <- result.try(shipment.export(directory))
  let built = shipped.build
  let package = built.checked.project.name
  let assert Ok(entry) = built.entry
  use bootstrap <- result.try(
    beam.compile(entrypoint.escript_forms(package, entry))
    |> result.map_error(failure(built, _)),
  )
  let path = filepath.join(built.checked.project.root, "build/" <> package)
  use Nil <- result.try(
    create(
      shipped.directory,
      path,
      entrypoint.module_name(package) <> "@escript",
      bootstrap,
    )
    |> result.map_error(failure(built, _)),
  )

  use Nil <- result.try(case simplifile.delete_file(path <> ".escript") {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) -> Error(failure(built, simplifile.describe_error(error)))
  })
  Ok(Report(built, path))
}

fn failure(built: build.Report, detail: String) -> build.Failure {
  build.Failure(Ok(built.checked), [
    diagnostic.error("export.escript", "escript could not be exported")
    |> diagnostic.conclusion(detail),
  ])
}

@external(erlang, "pooka_export_ffi", "create_escript")
fn create(
  shipment: String,
  destination: String,
  module: String,
  bootstrap: BitArray,
) -> Result(Nil, String)
