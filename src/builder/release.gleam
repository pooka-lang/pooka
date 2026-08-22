//// Give an application enough provisions to run elsewhere.
////
//// Assemble a release from compiled applications and their runtime requirements.
//// This is deployment packaging; it does not change the language's expression
//// semantics.
////
//// ```text
//// compiled application graph -> deployable release
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/build
import builder/shipment
import diagnostics/diagnostic
import filepath
import gleam/result
import project/semver

pub type Report {
  Report(build: build.Report, directory: String)
}

pub fn export(
  directory: String,
  include_erts: Bool,
) -> Result(Report, build.Failure) {
  use shipped <- result.try(shipment.export(directory))
  let built = shipped.build
  let project = built.checked.project
  use _ <- result.try(
    semver.parse(project.version)
    |> result.map_error(fn(_) {
      build.Failure(Ok(built.checked), [
        diagnostic.error("export.version", "invalid release version")
        |> diagnostic.conclusion(
          "Release versions must be semantic versions, such as 1.2.3.",
        ),
      ])
    }),
  )
  let assert Ok(entry) = built.entry
  let destination = filepath.join(project.root, "build/release")
  use Nil <- result.try(
    create(
      shipped.directory,
      destination,
      project.name,
      project.version,
      entry,
      include_erts,
    )
    |> result.map_error(fn(detail) {
      build.Failure(Ok(built.checked), [
        diagnostic.error("export.release", "release could not be exported")
        |> diagnostic.conclusion(detail),
      ])
    }),
  )
  Ok(Report(built, destination))
}

@external(erlang, "pooka_release_ffi", "create")
fn create(
  shipment: String,
  destination: String,
  name: String,
  version: String,
  entry: String,
  include_erts: Bool,
) -> Result(Nil, String)
