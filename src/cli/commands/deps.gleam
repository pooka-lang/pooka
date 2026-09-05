//// Ask the package graph to show its paperwork.
////
//// Dispatch dependency subcommands and render locked, resolved or requested
//// package information. Every subcommand retains its own usage information.
////
//// ```sh
//// pooka deps --help
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/help
import cli/commands/new
import filepath
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import project/dependency
import project/lockfile
import project/package
import project/project
import project/project_error
import tools/logger
import utilities/colour
import utilities/timer

pub const info =
  Info(name: "deps", arguments: "<command>", summary: "Manage dependencies")

pub fn run(arguments: List(String), environment: Environment) -> Outcome {
  case arguments {
    [] | ["--help"] | ["-h"] ->
      help.for_command([info], ["deps"], environment.stdout)
    ["download"] -> download(False, environment)
    ["update"] -> download(True, environment)
    ["list"] -> inspect(False, environment)
    ["tree"] -> inspect(True, environment)
    _ -> {
      let usage = help.for_command([info], ["deps"], environment.stderr)
      command.failure(
        "error: unknown deps subcommand or unexpected arguments `"
        <> string.join(arguments, " ")
        <> "`\n\n"
        <> usage.stdout,
      )
    }
  }
}

fn download(update: Bool, environment: Environment) -> Outcome {
  let started = environment.clock()
  case resolve(environment.working_directory, update) {
    Error(error) -> new.failure(error, environment)
    Ok(graph) ->
      Outcome(
        listing(
          graph.root,
          list.filter_map(graph.packages, fn(p) {
            case p.name == graph.root.name {
              True -> Error(Nil)
              False ->
                Ok(lockfile.Locked(
                  p.name,
                  p.version,
                  p.root,
                  p.origin,
                  p.kind,
                  p.dependencies,
                  list.map(p.dependencies, fn(dep) { dep.name }),
                ))
            }
          }),
          environment.stdout,
        ),
        logger.activity(
          "Resolved",
          "dependencies in " <> timer.format(environment.clock() - started),
          environment.stderr,
        ),
        0,
      )
  }
}

fn resolve(
  directory: String,
  update: Bool,
) -> Result(package.Graph, project_error.ProjectError) {
  use root <- result.try(project.find_root(directory))
  use config <- result.try(project.load(root))
  use graph <- result.try(package.resolve_updated(config, True, update))
  use Nil <- result.try(lockfile.write(graph.root, graph.packages))
  Ok(graph)
}

fn inspect(tree: Bool, environment: Environment) -> Outcome {
  let loaded = {
    use directory <- result.try(project.find_root(environment.working_directory))
    use root <- result.try(project.load(directory))
    use entries <- result.try(lockfile.read(root))
    Ok(#(root, entries))
  }
  case loaded {
    Error(error) -> new.failure(error, environment)
    Ok(#(root, entries)) ->
      command.success(case tree {
        False -> listing(root, entries, environment.stdout)
        True -> {
          let roots =
            list.append(root.dependencies, root.dev_dependencies)
            |> list.map(fn(dep) { dep.name })
            |> list.unique
          let #(_, children) =
            branches(roots, entries, root, set.new(), "", environment.stdout)
          colour.paint(
            root.name <> " " <> root.version,
            colour.bold_lantern_orange,
            environment.stdout,
          )
          <> "\n"
          <> children
        }
      })
  }
}

fn listing(
  root: project.Project,
  entries: List(lockfile.Locked),
  output: colour.Output,
) -> String {
  case entries {
    [] ->
      "No locked dependencies. Run `pooka deps download` to resolve dependencies.\n"
    _ ->
      entries
      |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
      |> list.map(fn(p) { "  " <> label(p, root, output) <> "\n" })
      |> string.concat
  }
}

fn label(
  p: lockfile.Locked,
  root: project.Project,
  output: colour.Output,
) -> String {
  colour.paint(p.name, colour.lantern_orange, output)
  <> " "
  <> p.version
  <> case p.origin {
    dependency.LocalOrigin ->
      " (path: " <> lockfile.relative(root.root, p.path) <> ")"
    dependency.GitOrigin(url, _, revision) ->
      " (git: "
      <> case filepath.is_absolute(url) {
        True -> lockfile.relative(root.root, url)
        False -> url
      }
      <> " @ "
      <> string.slice(revision, 0, 12)
      <> ")"
    dependency.HexOrigin(_) -> " (hex)"
  }
}

fn branches(
  names: List(String),
  entries: List(lockfile.Locked),
  root: project.Project,
  seen: set.Set(String),
  prefix: String,
  output: colour.Output,
) -> #(set.Set(String), String) {
  let count = list.length(names)
  list.index_fold(names, #(seen, ""), fn(acc, name, index) {
    let #(seen, text) = acc
    let last = index == count - 1
    let connector = case last {
      True -> "└── "
      False -> "├── "
    }
    let indent = case last {
      True -> "    "
      False -> "│   "
    }
    case list.find(entries, fn(p) { p.name == name }) {
      Error(_) -> #(
        seen,
        text <> prefix <> connector <> name <> " (not locked)\n",
      )
      Ok(p) -> {
        let repeated = set.contains(seen, name)
        let row =
          prefix
          <> connector
          <> label(p, root, output)
          <> case repeated {
            True -> " (*)"
            False -> ""
          }
          <> "\n"
        let #(seen, children) = case repeated {
          True -> #(seen, "")
          False ->
            branches(
              p.names,
              entries,
              root,
              set.insert(seen, name),
              prefix <> indent,
              output,
            )
        }
        #(seen, text <> row <> children)
      }
    }
  })
}
