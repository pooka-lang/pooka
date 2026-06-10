//// Fetch the named revision, not a convenient moving shadow.
////
//// Materialize Git dependencies and report the resolved revision for locking.
//// Keep repository, ref and package subdirectory failures attached to the owning
//// manifest.
////
//// ```text
//// Git URL + revision -> checked-out package source
//// ```

// SPDX-License-Identifier: Apache-2.0

import filepath
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import project/dependency as d
import project/lockfile
import project/project.{type Project, Project}
import project/project_error.{DependencyProblem}

pub fn load(
  root: Project,
  owner: Project,
  name: String,
  url: String,
  reference: String,
  pins: List(lockfile.Locked),
  update: Bool,
) -> Result(Project, project_error.ProjectError) {
  let url = normalize_url(owner.root, url)
  let identity = d.repository_identity(url)
  let pin = case update {
    True -> None
    False ->
      list.find_map(pins, fn(pin) {
        case pin.name == name, pin.origin {
          True, d.GitOrigin(locked_url, locked_reference, revision)
            if locked_reference == reference
          ->
            case
              d.repository_identity(normalize_url(root.root, locked_url))
              == identity
            {
              True -> Ok(revision)
              False -> Error(Nil)
            }
          _, _ -> Error(Nil)
        }
      })
      |> result.map(Some)
      |> result.unwrap(None)
  }
  use #(directory, revision) <- result.try(
    checkout(
      filepath.join(root.root, "build/packages"),
      name,
      url,
      reference,
      pin,
    )
    |> result.map_error(DependencyProblem(
      filepath.join(owner.root, "pooka.toml"),
      _,
    )),
  )
  use project <- result.try(project.load_package(directory, name))
  Ok(Project(..project, origin: d.GitOrigin(identity, reference, revision)))
}

@external(erlang, "pooka_package_ffi", "git_url")
fn normalize_url(owner: String, url: String) -> String

@external(erlang, "pooka_package_ffi", "git_checkout")
fn checkout(
  cache: String,
  name: String,
  url: String,
  reference: String,
  pin: Option(String),
) -> Result(#(String, String), String)
