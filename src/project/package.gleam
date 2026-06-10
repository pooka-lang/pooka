//// Find one set of neighbours that can live together.
////
//// Resolve local, Git and Hex sources under version constraints and locked
//// choices. Keep source ownership explicit so errors point at the package that
//// requested the dependency.
////
//// ```text
//// root constraints + dependency constraints -> resolved graph
//// ```

// SPDX-License-Identifier: Apache-2.0

import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import project/dependency
import project/git
import project/hex
import project/lockfile
import project/project.{type Project, Project}
import project/project_error.{type ProjectError, DependencyProblem}
import project/semver

pub type Graph {
  Graph(root: Project, packages: List(Project))
}

pub type Candidate =
  fn() -> Result(Project, ProjectError)

pub type Provider =
  fn(Project, Project, dependency.Dependency, List(lockfile.Locked), Bool) ->
    Result(List(Candidate), ProjectError)

/// Choose the dependency graph requested by a checked root configuration and its
/// lock state.
///
/// ```text
/// local + Git + Hex requests -> one resolved package graph
/// ```
pub fn resolve(
  root: Project,
  include_dev: Bool,
) -> Result(Graph, ProjectError) {
  resolve_updated(root, include_dev, False)
}

pub fn resolve_updated(
  root: Project,
  include_dev: Bool,
  update: Bool,
) -> Result(Graph, ProjectError) {
  resolve_using(root, include_dev, update, hex.fetch)
}

pub fn resolve_using(
  root: Project,
  include_dev: Bool,
  update: Bool,
  fetch: hex.Fetch,
) -> Result(Graph, ProjectError) {
  resolve_selecting(root, include_dev, update, fetch, [])
}

pub fn resolve_selecting(
  root: Project,
  include_dev: Bool,
  update: Bool,
  fetch: hex.Fetch,
  unlocked: List(String),
) -> Result(Graph, ProjectError) {
  use canonical <- result.try(
    canonical(root.root)
    |> result.map_error(DependencyProblem(
      filepath.join(root.root, "pooka.toml"),
      _,
    )),
  )
  let root = Project(..root, root: canonical)
  use pins <- result.try(lockfile.read(root))
  let unlocked = unlock_closure(unlocked, pins, [])
  let pins = list.filter(pins, fn(pin) { !list.contains(unlocked, pin.name) })
  let provider = fn(root, owner, dep, pins, update) {
    case dep {
      dependency.Hex(name, requirement, _) ->
        hex.candidates(root, name, requirement, pins, update, fetch)
      _ -> Ok([fn() { source(owner, root, dep, pins, update) }])
    }
  }
  use graph <- result.try(solve(root, include_dev, pins, update, provider))
  use packages <- result.try(
    list.try_map(graph.packages, fn(package) {
      case package.origin {
        dependency.HexOrigin(_) -> hex.materialize(root, package, fetch)
        _ -> Ok(package)
      }
    }),
  )
  Ok(Graph(root, packages))
}

pub fn solve(
  root: Project,
  include_dev: Bool,
  pins: List(lockfile.Locked),
  update: Bool,
  provider: Provider,
) -> Result(Graph, ProjectError) {
  let requirements = case include_dev {
    True -> list.append(root.dependencies, root.dev_dependencies)
    False -> root.dependencies
  }
  search(
    root,
    include_dev,
    list.map(requirements, fn(dep) { #(root, dep) }),
    dict.from_list([#(root.name, root)]),
    dict.new(),
    pins,
    update,
    provider,
  )
}

fn source(
  owner: Project,
  root: Project,
  dep: dependency.Dependency,
  pins: List(lockfile.Locked),
  update: Bool,
) -> Result(Project, ProjectError) {
  case dep {
    dependency.Local(name, path) -> {
      let location = case filepath.is_absolute(path) {
        True -> path
        False -> filepath.join(owner.root, path)
      }
      use directory <- result.try(
        canonical(location)
        |> result.map_error(DependencyProblem(
          filepath.join(owner.root, "pooka.toml"),
          _,
        )),
      )
      project.load_package(directory, name)
    }
    dependency.Git(name, url, reference) ->
      git.load(root, owner, name, url, reference, pins, update)
    dependency.Hex(_, _, _) -> panic as "registry candidates use their transport"
  }
}

fn search(
  root: Project,
  include_dev: Bool,
  pending: List(#(Project, dependency.Dependency)),
  chosen: Dict(String, Project),
  optional: Dict(String, List(String)),
  pins: List(lockfile.Locked),
  update: Bool,
  provider: Provider,
) -> Result(Graph, ProjectError) {
  case pending {
    [] -> {
      use packages <- result.try(
        order(root, include_dev, chosen, root.name, [], []),
      )
      let applications = list.map(packages, project.application_name)
      case list.length(applications) == list.length(list.unique(applications)) {
        True -> Ok(Graph(root, packages))
        False ->
          Error(DependencyProblem(
            filepath.join(root.root, "pooka.toml"),
            "Conflicting OTP application names in the dependency graph.",
          ))
      }
    }
    [#(owner, dep), ..rest] -> {
      let failure = fn(message) {
        DependencyProblem(filepath.join(owner.root, "pooka.toml"), message)
      }
      case dep {
        dependency.Hex(name, requirement, True) -> {
          let optional =
            dict.insert(optional, name, [
              requirement,
              ..dict.get(optional, name)
              |> result.unwrap([])
            ])
          use Nil <- result.try(case dict.get(chosen, name) {
            Error(_) -> Ok(Nil)
            Ok(p) -> check_hex(p, requirement) |> result.map_error(failure)
          })
          search(
            root,
            include_dev,
            rest,
            chosen,
            optional,
            pins,
            update,
            provider,
          )
        }
        _ ->
          case dict.get(chosen, dep.name) {
            Ok(existing) -> {
              use Nil <- result.try(case dep {
                dependency.Hex(_, requirement, _) ->
                  check_hex(existing, requirement) |> result.map_error(failure)
                _ -> {
                  use requested <- result.try(source(
                    owner,
                    root,
                    dep,
                    pins,
                    update,
                  ))
                  case
                    requested.root == existing.root
                    && requested.origin == existing.origin
                  {
                    True -> Ok(Nil)
                    False ->
                      Error(failure(
                        "Conflicting sources for package `"
                        <> dep.name
                        <> "`: "
                        <> existing.root
                        <> " and "
                        <> requested.root,
                      ))
                  }
                }
              })
              search(
                root,
                include_dev,
                rest,
                chosen,
                optional,
                pins,
                update,
                provider,
              )
            }
            Error(_) -> {
              use candidates <- result.try(provider(
                root,
                owner,
                dep,
                pins,
                update,
              ))
              try_candidates(
                candidates,
                fn(candidate) {
                  use package <- result.try(candidate())
                  use Nil <- result.try(case package.name == dep.name {
                    True -> Ok(Nil)
                    False ->
                      Error(failure(
                        "Dependency `"
                        <> dep.name
                        <> "` declares package name `"
                        <> package.name
                        <> "`.",
                      ))
                  })
                  use Nil <- result.try(
                    list.try_each(
                      dict.get(optional, package.name) |> result.unwrap([]),
                      fn(req) {
                        check_hex(package, req) |> result.map_error(failure)
                      },
                    ),
                  )
                  search(
                    root,
                    include_dev,
                    list.append(
                      list.map(package.dependencies, fn(child) {
                        #(package, child)
                      }),
                      rest,
                    ),
                    dict.insert(chosen, package.name, package),
                    optional,
                    pins,
                    update,
                    provider,
                  )
                },
                failure(
                  "No compatible dependency graph for `" <> dep.name <> "`.",
                ),
              )
            }
          }
      }
    }
  }
}

fn try_candidates(
  candidates: List(Candidate),
  run: fn(Candidate) -> Result(Graph, ProjectError),
  last: ProjectError,
) -> Result(Graph, ProjectError) {
  case candidates {
    [] -> Error(last)
    [candidate, ..rest] ->
      case run(candidate) {
        Ok(graph) -> Ok(graph)
        Error(error) -> try_candidates(rest, run, error)
      }
  }
}

fn check_hex(package: Project, requirement: String) -> Result(Nil, String) {
  case package.origin, semver.parse(package.version) {
    dependency.HexOrigin(_), Ok(version) ->
      case semver.satisfies(version, requirement) {
        True -> Ok(Nil)
        False ->
          Error(
            "Version conflict for `"
            <> package.name
            <> "`: "
            <> package.version
            <> " does not satisfy "
            <> requirement
            <> ". Run `pooka deps update` if a lock pin prevents resolution.",
          )
      }
    _, _ ->
      Error("Conflicting sources for Hex package `" <> package.name <> "`.")
  }
}

fn order(
  root: Project,
  include_dev: Bool,
  chosen: Dict(String, Project),
  name: String,
  visiting: List(String),
  resolved: List(Project),
) -> Result(List(Project), ProjectError) {
  use Nil <- result.try(case list.contains(visiting, name) {
    True ->
      Error(DependencyProblem(
        filepath.join(root.root, "pooka.toml"),
        "Dependency cycle: "
          <> string.join(list.append(visiting, [name]), " -> "),
      ))
    False -> Ok(Nil)
  })
  case list.any(resolved, fn(p) { p.name == name }) {
    True -> Ok(resolved)
    False -> {
      let assert Ok(package) = dict.get(chosen, name)
      let deps = case name == root.name && include_dev {
        True -> list.append(package.dependencies, package.dev_dependencies)
        False -> package.dependencies
      }
      use resolved <- result.try(
        list.try_fold(deps, resolved, fn(resolved, dep) {
          case dict.has_key(chosen, dep.name) {
            True ->
              order(
                root,
                include_dev,
                chosen,
                dep.name,
                list.append(visiting, [name]),
                resolved,
              )
            False -> Ok(resolved)
          }
        }),
      )
      Ok(list.append(resolved, [package]))
    }
  }
}

@external(erlang, "pooka_package_ffi", "canonical")
fn canonical(path: String) -> Result(String, String)

pub fn source_path(package: String, relative: String) -> String {
  "src/$package/" <> package <> "/" <> string.drop_start(relative, 4)
}

pub fn owner(path: String, root: String) -> String {
  case string.split(path, "/") {
    ["src", "$package", name, ..] -> name
    _ -> root
  }
}

pub fn module_owner(identity: String, root: String) -> #(String, String) {
  case string.split(identity, "/") {
    ["$package", name, ..rest] -> #(name, string.join(rest, "/"))
    _ -> #(root, identity)
  }
}

fn unlock_closure(
  pending: List(String),
  pins: List(lockfile.Locked),
  seen: List(String),
) -> List(String) {
  case pending {
    [] -> seen
    [name, ..rest] ->
      case list.contains(seen, name) {
        True -> unlock_closure(rest, pins, seen)
        False -> {
          let children =
            list.find(pins, fn(pin) { pin.name == name })
            |> result.map(fn(pin) { pin.names })
            |> result.unwrap([])
          unlock_closure(list.append(children, rest), pins, [name, ..seen])
        }
      }
  }
}
