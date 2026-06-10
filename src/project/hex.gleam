//// Read the registry's catalogue before choosing a parcel.
////
//// Obtain release candidates, validate archives and materialize Hex packages.
//// Transport failures and unsuitable package metadata must remain distinct from
//// version-solving conflicts.
////
//// ```text
//// package + selected version -> verified package archive
//// ```

// SPDX-License-Identifier: Apache-2.0

import filepath
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import project/config
import project/dependency as d
import project/lockfile
import project/project.{type Project, Project}
import project/project_error.{type ProjectError, DependencyProblem}
import project/project_name
import project/semver

pub type Fetch =
  fn(String) -> Result(BitArray, String)

pub fn candidates(
  root: Project,
  name: String,
  requirement: String,
  pins: List(lockfile.Locked),
  update: Bool,
  fetch: Fetch,
) -> Result(List(fn() -> Result(Project, ProjectError)), ProjectError) {
  let problem = fn(text) {
    DependencyProblem(filepath.join(root.root, "pooka.toml"), text)
  }
  let pinned =
    list.find_map(pins, fn(pin) {
      case pin.name == name, pin.origin {
        True, d.HexOrigin(_) -> Ok(pin)
        _, _ -> Error(Nil)
      }
    })
  case pinned, update {
    Ok(pin), False ->
      case
        semver.parse(pin.version)
        |> result.map(semver.satisfies(_, requirement))
      {
        Ok(True) ->
          Ok([
            fn() {
              Ok(Project(
                filepath.join(
                  root.root,
                  "build/packages/" <> name <> "-" <> pin.version,
                ),
                name,
                pin.version,
                pin.dependencies,
                [],
                pin.origin,
                pin.kind,
                [],
                config.defaults(),
              ))
            },
          ])
        _ ->
          Error(problem(
            "Locked version of `"
            <> name
            <> "` does not satisfy `"
            <> requirement
            <> "`. Run `pooka deps update`.",
          ))
      }
    _, _ -> {
      use body <- result.try(
        fetch("https://hex.pm/api/packages/" <> name)
        |> result.map_error(problem),
      )
      use versions <- result.try(
        json.parse(bits_text(body), {
          use releases <- decode.field(
            "releases",
            decode.list({
              use version <- decode.field("version", decode.string)
              decode.success(version)
            }),
          )
          decode.success(releases)
        })
        |> result.map_error(fn(_) {
          problem("Invalid Hex package metadata for `" <> name <> "`.")
        }),
      )
      let candidates =
        versions
        |> list.filter_map(fn(version) {
          use parsed <- result.try(semver.parse(version))
          case
            semver.satisfies(parsed, requirement)
            && { parsed.pre == None || string.contains(requirement, "-") }
          {
            True -> Ok(#(parsed, version))
            False -> Error(Nil)
          }
        })
        |> list.sort(fn(a, b) { semver.compare(b.0, a.0) })
      case candidates {
        [] ->
          Error(problem(
            "No Hex version of `"
            <> name
            <> "` satisfies `"
            <> requirement
            <> "`.",
          ))
        _ ->
          Ok(
            list.map(candidates, fn(candidate) {
              fn() {
                use body <- result.try(
                  fetch(
                    "https://hex.pm/api/packages/"
                    <> name
                    <> "/releases/"
                    <> candidate.1,
                  )
                  |> result.map_error(problem),
                )
                release(root, name, candidate.1, bits_text(body))
              }
            }),
          )
      }
    }
  }
}

pub fn release(
  root: Project,
  name: String,
  version: String,
  body: String,
) -> Result(Project, ProjectError) {
  let decoder = {
    use actual_version <- decode.field("version", decode.string)
    use retired <- decode.optional_field(
      "retirement",
      None,
      decode.optional(decode.dynamic),
    )
    use checksum <- decode.field("checksum", decode.string)
    use requirements <- decode.field(
      "requirements",
      decode.dict(decode.string, {
        use requirement <- decode.field("requirement", decode.string)
        use optional <- decode.field("optional", decode.bool)
        decode.success(#(requirement, optional))
      }),
    )
    use app <- decode.field(
      "meta",
      decode.field("app", decode.string, decode.success),
    )
    use tools <- decode.field(
      "meta",
      decode.field("build_tools", decode.list(decode.string), decode.success),
    )
    decode.success(#(
      checksum,
      requirements,
      app,
      tools,
      actual_version,
      retired != None,
    ))
  }
  let problem = fn() {
    DependencyProblem(
      filepath.join(root.root, "pooka.toml"),
      "Invalid Hex release metadata for `" <> name <> "@" <> version <> "`.",
    )
  }
  use data <- result.try(
    json.parse(body, decoder) |> result.map_error(fn(_) { problem() }),
  )
  use Nil <- result.try(case data.4 == version && !data.5 {
    True -> Ok(Nil)
    False -> Error(problem())
  })
  use Nil <- result.try(
    list.try_each(dict.values(data.1), fn(req) {
      case semver.valid_requirement(req.0) {
        True -> Ok(Nil)
        False -> Error(problem())
      }
    }),
  )
  use Nil <- result.try(case lockfile.hash(data.0, 64) {
    True -> Ok(Nil)
    False -> Error(problem())
  })
  use Nil <- result.try(
    project_name.validate(data.2) |> result.map_error(fn(_) { problem() }),
  )
  use Nil <- result.try(
    list.try_each(dict.keys(data.1), fn(name) {
      project_name.validate(name) |> result.map_error(fn(_) { problem() })
    }),
  )
  let deps =
    dict.to_list(data.1)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) { d.Hex(pair.0, pair.1.0, pair.1.1) })
  let kind = case list.contains(data.3, "pooka") {
    True -> d.Pooka
    False -> d.Beam(data.2, data.3)
  }
  Ok(Project(
    filepath.join(root.root, "build/packages/" <> name <> "-" <> version),
    name,
    version,
    deps,
    [],
    d.HexOrigin(string.lowercase(data.0)),
    kind,
    [],
    config.defaults(),
  ))
}

pub fn materialize(
  root: Project,
  package: Project,
  fetch: Fetch,
) -> Result(Project, ProjectError) {
  let assert d.HexOrigin(checksum) = package.origin
  let problem = fn(text) {
    DependencyProblem(
      filepath.join(root.root, "pooka.toml"),
      package.name
        <> "@"
        <> package.version
        <> ": "
        <> text
        <> "\nCache: "
        <> package.root,
    )
  }
  use cached <- result.try(
    verify_cache(package.root, checksum) |> result.map_error(problem),
  )
  use Nil <- result.try(case cached {
    True -> Ok(Nil)
    False -> {
      use bytes <- result.try(
        fetch(
          "https://repo.hex.pm/tarballs/"
          <> package.name
          <> "-"
          <> package.version
          <> ".tar",
        )
        |> result.map_error(problem),
      )
      unpack(bytes, checksum, package.root) |> result.map_error(problem)
    }
  })
  case package.kind {
    d.Beam(_, _) -> Ok(package)
    d.Pooka -> {
      use actual <- result.try(project.load(package.root))
      case
        actual.name == package.name
        && actual.version == package.version
        && actual.dependencies == package.dependencies
      {
        True ->
          Ok(
            Project(
              ..actual,
              origin: package.origin,
              dependencies: package.dependencies,
            ),
          )
        False ->
          Error(problem(
            "Hex archive manifest does not match the release metadata.",
          ))
      }
    }
  }
}

fn bits_text(bytes: BitArray) -> String {
  bytes
  |> bit_array.to_string
  |> result.unwrap("invalid UTF-8 registry response")
}

@external(erlang, "pooka_package_ffi", "http_get")
pub fn fetch(url: String) -> Result(BitArray, String)

@external(erlang, "pooka_package_ffi", "hex_unpack")
pub fn unpack(
  bytes: BitArray,
  checksum: String,
  destination: String,
) -> Result(Nil, String)

@external(erlang, "pooka_package_ffi", "hex_cached")
fn verify_cache(destination: String, checksum: String) -> Result(Bool, String)
