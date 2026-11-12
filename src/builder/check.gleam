//// Read the whole neighbourhood before judging one house.
////
//// Load the dependency graph, collect module exports and check sources in
//// dependency order. Reports retain source text so later diagnostics can point
//// back to the user's program.
////
//// ```text
//// library exports -> importing module -> checked package
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/nif
import compiler/analysis/module
import compiler/compiler.{type Checked}
import compiler/parser/ast
import compiler/parser/parser
import diagnostics/diagnostic.{type Diagnostic}
import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import project/package
import project/project.{type Project}
import project/project_error.{type ProjectError}
import simplifile
import utilities/location

pub type Report {
  Report(
    project: Project,
    files: List(Checked),
    packages: List(Project),
    project_diagnostics: List(Diagnostic),
  )
}

/// Resolve and check a project, preserving reports and original source for
/// diagnostics.
///
/// ```sh
/// pooka check
/// ```
pub fn check_project(directory: String) -> Result(Report, ProjectError) {
  check_sources(directory, True)
}

/// Check the production view of a package rather than executing or compiling its
/// tests.
///
/// ```text
/// production sources + dependency interfaces -> checked project
/// ```
pub fn check_production(directory: String) -> Result(Report, ProjectError) {
  check_sources(directory, False)
}

fn check_sources(
  directory: String,
  include_tests: Bool,
) -> Result(Report, ProjectError) {
  check_with_overlays(directory, include_tests, dict.new())
}

pub fn with_sources(
  directory: String,
  sources: List(#(String, String)),
) -> Result(Report, ProjectError) {
  check_with_overlays(directory, True, dict.from_list(sources))
}

fn check_with_overlays(
  directory: String,
  include_tests: Bool,
  overlays: Dict(String, String),
) -> Result(Report, ProjectError) {
  use root <- result.try(project.find_root(directory))
  use loaded <- result.try(project.load(root))
  use graph <- result.try(package.resolve(loaded, include_tests))
  check_graph_with_overlays(graph, include_tests, overlays)
}

pub fn check_graph(
  graph: package.Graph,
  include_tests: Bool,
) -> Result(Report, ProjectError) {
  check_graph_with_overlays(graph, include_tests, dict.new())
}

fn check_graph_with_overlays(
  graph: package.Graph,
  include_tests: Bool,
  overlays: Dict(String, String),
) -> Result(Report, ProjectError) {
  let loaded = graph.root
  use groups <- result.try(
    list.try_map(graph.packages, fn(owner) {
      let root = owner.name == loaded.name
      use sources <- result.try(case root && include_tests {
        True -> project.source_files(owner)
        False -> project.production_source_files(owner)
      })
      let extra =
        dict.keys(overlays)
        |> list.filter_map(fn(path) {
          case string.starts_with(path, owner.root <> "/") {
            False -> Error(Nil)
            True -> {
              let relative =
                string.drop_start(path, string.length(owner.root) + 1)
              case
                string.starts_with(relative, "src/"),
                string.ends_with(relative, ".pooka"),
                string.starts_with(relative, "test/"),
                string.ends_with(relative, ".spec.pooka"),
                root && include_tests
              {
                True, True, _, _, _ ->
                  Ok(project.SourceFile(relative, project.Production))
                _, _, True, True, True ->
                  Ok(project.SourceFile(relative, project.TestSource))
                _, _, _, _, _ -> Error(Nil)
              }
            }
          }
        })
      let sources =
        list.append(sources, extra)
        |> list.unique
        |> list.sort(fn(a, b) { string.compare(a.path, b.path) })
      use files <- result.try(
        list.try_map(sources, fn(source) {
          check_file(
            owner,
            source,
            root && include_tests,
            case root {
              True -> source.path
              False -> package.source_path(owner.name, source.path)
            },
            overlays,
          )
        }),
      )
      Ok(#(owner, files))
    }),
  )
  let files = list.flat_map(groups, fn(group) { group.1 })
  let imported_errors =
    list.flat_map(groups, fn(group) {
      let owner = group.0
      let dependencies = case owner.name == loaded.name && include_tests {
        True -> list.append(owner.dependencies, owner.dev_dependencies)
        False -> owner.dependencies
      }
      let visible = [owner.name, ..list.map(dependencies, fn(dep) { dep.name })]
      // Read only the neighbours this package is allowed to visit.
      let visible_files =
        groups
        |> list.filter(fn(target) { list.contains(visible, target.0.name) })
        |> list.flat_map(fn(target) { target.1 })

      // A broken file still has an address. Remember it without treating
      // its unfinished syntax as a usable module.
      let failed_modules =
        visible_files
        |> list.filter(fn(file) {
          file.lexed.errors != [] || file.parsed.errors != []
        })
        |> list.filter_map(fn(file) {
          compiler.expected_module_path(file.path)
          |> result.map(fn(identity) {
            package.module_owner(identity, loaded.name).1
          })
        })
        |> set.from_list

      // Only successfully parsed modules may lend their declarations.
      let targets =
        visible_files
        |> list.filter(fn(file) {
          file.lexed.errors == [] && file.parsed.errors == []
        })
        |> list.filter_map(fn(file) {
          compiler.expected_module_path(file.path)
          |> result.map(fn(identity) {
            module.SourceModule(
              package.module_owner(identity, loaded.name).1,
              file.path,
              file.parsed.module,
            )
          })
        })

      let clients =
        list.map(
          list.filter(group.1, fn(file) {
            file.lexed.errors == [] && file.parsed.errors == []
          }),
          fn(file) {
            module.SourceModule(file.path, file.path, file.parsed.module)
          },
        )
      module.check_imports(clients, targets, failed_modules)
    })

  let identities =
    list.filter_map(files, fn(file) {
      compiler.expected_module_path(file.path)
      |> result.map(fn(identity) {
        #(package.module_owner(identity, loaded.name).1, identity, file.path)
      })
    })
  let collisions =
    list.filter(identities, fn(item) {
      list.count(identities, fn(other) { other.0 == item.0 }) > 1
    })
    |> list.map(fn(item) {
      diagnostic.error(
        "module.package_collision",
        "module is provided by multiple packages",
      )
      |> diagnostic.primary(
        location.new(item.2, utilities_span()),
        "Module `" <> item.0 <> "` has more than one package owner.",
      )
    })
  let module_names =
    identities |> list.map(fn(item) { #(item.0, item.1) }) |> dict.from_list
  let files =
    list.map(files, fn(file) {
      let syntax = file.parsed.module
      let imports =
        list.map(syntax.imports, fn(imported) {
          let raw = string.join(imported.module.segments, "/")
          case dict.get(module_names, raw) {
            Error(_) -> imported
            Ok(identity) ->
              ast.Import(
                ..imported,
                module: ast.ModulePath(
                  ..imported.module,
                  segments: string.split(identity, "/"),
                ),
              )
          }
        })
      compiler.Checked(
        ..file,
        parsed: parser.Output(
          ..file.parsed,
          module: ast.Module(..syntax, imports: imports),
        ),
      )
    })
  let modules =
    list.filter_map(files, fn(file) {
      case
        compiler.expected_module_path(file.path),
        file.lexed.errors,
        file.parsed.errors
      {
        Ok(identity), [], [] ->
          Ok(module.SourceModule(identity, file.path, file.parsed.module))
        _, _, _ -> Error(Nil)
      }
    })
  let exports =
    modules
    |> list.map(fn(source) {
      let names =
        source.syntax.declarations
        |> list.filter_map(ast.declaration_name)
        |> list.map(fn(value) { value.name })
        |> list.filter(fn(name) { !string.starts_with(name, "_") })
        |> set.from_list
      #(source.identity, names)
    })
    |> dict.from_list
  let files = list.map(files, compiler.with_exports(_, exports))
  let report =
    Report(
      project: loaded,
      files:,
      packages: list.filter(graph.packages, fn(p) { p.name != loaded.name }),
      project_diagnostics: list.append(
        module.check(modules),
        list.flatten([imported_errors, collisions, nif.check(groups)]),
      ),
    )
  Ok(case diagnostic.has_errors(diagnostics(report)) {
    True -> report
    False ->
      Report(..report, files: list.map(report.files, compiler.with_lints))
  })
}

fn check_file(
  project: Project,
  file: project.SourceFile,
  include_tests: Bool,
  source_path: String,
  overlays: Dict(String, String),
) -> Result(Checked, ProjectError) {
  let absolute = filepath.join(project.root, file.path)
  use source <- result.try(
    case dict.get(overlays, absolute) {
      Ok(source) -> Ok(source)
      Error(_) -> simplifile.read(absolute)
    }
    |> result.map_error(project_error.FileSystemFailed(
      project_error.ReadingFile,
      absolute,
      _,
    )),
  )
  Ok(case include_tests {
    True -> compiler.check_source(source_path, source)
    False -> compiler.check_production_source(source_path, source)
  })
}

pub fn diagnostics(report: Report) -> List(Diagnostic) {
  list.append(
    list.flat_map(report.files, fn(file) { file.diagnostics }),
    report.project_diagnostics,
  )
  |> display_diagnostics(report, _)
  |> diagnostic.sort
}

pub fn sources(report: Report) -> Dict(String, String) {
  report.files
  |> list.flat_map(fn(file) {
    [#(file.path, file.source), #(display_path(report, file.path), file.source)]
  })
  |> dict.from_list
}

fn utilities_span() -> location.Span {
  location.Span(location.start(), location.start())
}

pub fn display_path(report: Report, path: String) -> String {
  let name = package.owner(path, report.project.name)
  case
    list.find(report.packages, fn(p) { p.name == name }),
    compiler.expected_module_path(path)
  {
    Ok(owner), Ok(identity) ->
      filepath.join(
        owner.root,
        "src/"
          <> package.module_owner(identity, report.project.name).1
          <> ".pooka",
      )
    _, _ -> path
  }
}

pub fn display_diagnostics(
  report: Report,
  diagnostics: List(Diagnostic),
) -> List(Diagnostic) {
  list.map(diagnostics, fn(value) {
    diagnostic.Diagnostic(
      ..value,
      title: display_text(report, value.title),
      conclusion: display_text(report, value.conclusion),
      notes: list.map(value.notes, display_text(report, _)),
      suggestions: list.map(value.suggestions, display_text(report, _)),
      labels: list.map(value.labels, fn(label) {
        diagnostic.Label(
          ..label,
          message: display_text(report, label.message),
          location: location.new(
            display_path(report, label.location.path),
            label.location.span,
          ),
        )
      }),
      fixes: list.map(value.fixes, fn(fix) {
        diagnostic.Fix(
          ..fix,
          description: display_text(report, fix.description),
          location: location.new(
            display_path(report, fix.location.path),
            fix.location.span,
          ),
        )
      }),
    )
  })
}

fn display_text(report: Report, text: String) -> String {
  list.fold(report.packages, text, fn(text, owner) {
    string.replace(text, "$package/" <> owner.name <> "/", "")
  })
}
