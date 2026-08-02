//// Bring the checked program to the workshop door.
////
//// Coordinate package checking, cached compilation, foreign modules and runtime
//// artifacts. Production and test builds share the pipeline but choose different
//// source sets.
////
//// ```text
//// pooka.toml + src/ -> check -> abstract forms -> BEAM
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/application
import builder/check
import builder/foreign
import builder/infer
import builder/layout
import builder/native
import builder/nif
import builder/runtime
import builder/stamp
import compiler/codegen/beam
import compiler/codegen/erlang
import compiler/codegen/forms
import compiler/typesystem/monotype
import compiler/typesystem/typed_ast
import diagnostics/diagnostic.{type Diagnostic}
import filepath
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import project/dependency
import project/lockfile
import project/package
import project/project
import project/project_error
import project/project_name
import simplifile
import utilities/location.{type Span}

pub type Report {
  Report(
    checked: check.Report,
    diagnostics: List(Diagnostic),
    directory: String,
    modules: List(String),
    entry: Result(String, Nil),
    tests: List(Test),
    layout: layout.Layout,
    compiled: List(String),
    reused: Bool,
    compiled_foreign: List(String),
    compiled_packages: List(String),
  )
}

pub type Test {
  Test(
    module: String,
    function: String,
    description: String,
    path: String,
    span: Span,
    skipped: Bool,
  )
}

pub type Failure {
  Failure(checked: Result(check.Report, Nil), diagnostics: List(Diagnostic))
}

type Artifact {
  Artifact(
    name: String,
    abstract: BitArray,
    binary: BitArray,
    compiled: Bool,
    tests: List(Test),
  )
}

/// Build the current development project and its dependencies through the shared
/// compilation pipeline.
///
/// ```sh
/// pooka build
/// ```
pub fn build(directory: String) -> Result(Report, Failure) {
  build_mode(directory, layout.Development)
}

/// Build a test-capable source set so test execution can share checked package
/// artifacts.
///
/// ```sh
/// pooka test
/// ```
pub fn build_tests(directory: String) -> Result(Report, Failure) {
  build_mode(directory, layout.Development)
}

/// Build the production source set used by exports without promoting test bodies
/// into the application.
///
/// ```sh
/// pooka export escript
/// ```
pub fn build_production(directory: String) -> Result(Report, Failure) {
  build_mode(directory, layout.Production)
}

fn build_mode(directory: String, mode: layout.Mode) -> Result(Report, Failure) {
  use graph <- result.try(
    {
      use root <- result.try(project.find_root(directory))
      use loaded <- result.try(project.load(root))
      package.resolve(loaded, mode == layout.Development)
    }
    |> result.map_error(fn(error) {
      Failure(Error(Nil), [project_error.to_diagnostic(error)])
    }),
  )
  let snapshot = stamp.snapshot(graph, layout.mode_name(mode))
  let paths = layout.erlang(graph.root.root, graph.root.name, mode)
  let packages =
    list.map(graph.packages, fn(p) {
      layout.erlang(graph.root.root, native.application(p), mode).package
    })
  let cache_path = filepath.join(paths.artifacts, "build.cache")
  let cached = case snapshot {
    Ok(snapshot) -> read_cached(cache_path, snapshot.key, packages)
    Error(_) -> Error(Nil)
  }
  case cached {
    Ok(report) ->
      Ok(
        Report(
          ..report,
          compiled: [],
          reused: True,
          compiled_foreign: [],
          compiled_packages: [],
        ),
      )
    Error(_) -> {
      use report <- result.try(compile_project(graph, mode, snapshot))

      case snapshot {
        Ok(before) ->
          case stamp.snapshot(graph, layout.mode_name(mode)) {
            Ok(after) if before == after -> {
              let _ = write_cached(cache_path, after.key, packages, report)
              Ok(report)
            }
            _ -> Ok(report)
          }
        Error(_) -> Ok(report)
      }
    }
  }
}

@external(erlang, "pooka_incremental_ffi", "read_report")
fn read_cached(
  path: String,
  key: BitArray,
  packages: List(String),
) -> Result(Report, Nil)

@external(erlang, "pooka_incremental_ffi", "write_report")
fn write_cached(
  path: String,
  key: BitArray,
  packages: List(String),
  report: Report,
) -> Result(Nil, Nil)

fn compile_project(
  graph: package.Graph,
  mode: layout.Mode,
  snapshot: Result(stamp.Snapshot, Nil),
) -> Result(Report, Failure) {
  let include_tests = mode == layout.Development
  use checked <- result.try(
    case mode {
      layout.Development -> check.check_graph(graph, True)
      layout.Production -> check.check_graph(graph, False)
    }
    |> result.map_error(fn(error) {
      Failure(Error(Nil), [project_error.to_diagnostic(error)])
    }),
  )
  use inferred <- result.try(
    infer.preview_report(checked)
    |> result.map_error(fn(error) {
      let failure = preview_failure(error)
      Failure(
        Ok(checked),
        check.display_diagnostics(checked, failure.diagnostics),
      )
    }),
  )
  use Nil <- result.try(case diagnostic.has_errors(inferred.diagnostics) {
    True -> Error(Failure(Ok(checked), inferred.diagnostics))
    False -> Ok(Nil)
  })
  use Nil <- result.try(
    lockfile.validate(checked.project)
    |> result.map_error(fn(error) {
      Failure(Ok(checked), [project_error.to_diagnostic(error)])
    }),
  )
  let paths = layout.erlang(checked.project.root, checked.project.name, mode)
  let fingerprint = beam.build_fingerprint()
  let reuse = simplifile.read_bits(paths.fingerprint) == Ok(fingerprint)
  let available =
    inferred.modules
    |> list.map(fn(value) { #(value.identity, value.inferred) })
    |> dict.from_list
  let production =
    list.filter(inferred.modules, fn(value) {
      string.starts_with(value.path, "src/")
    })
  let targets = case include_tests {
    True -> inferred.modules
    False -> production
  }
  use artifacts <- result.try(
    list.try_map(targets, fn(module) {
      use file <- result.try(
        list.find(checked.files, fn(file) { file.path == module.path })
        |> result.map_error(fn(_) {
          failure(checked, module.path, "missing checked source")
        }),
      )
      use typed <- result.try(
        typed_ast.checked(file.parsed.module, module.inferred, module.path)
        |> result.map_error(Failure(Ok(checked), _)),
      )
      use generated <- result.try(
        case include_tests {
          False ->
            erlang.generate(
              typed,
              checked.project.name,
              module.identity,
              available,
            )
          True ->
            erlang.generate_tests(
              typed,
              checked.project.name,
              case string.starts_with(module.path, "src/") {
                True -> module.identity
                False -> "$test/" <> module.identity
              },
              available,
            )
        }
        |> result.map_error(fn(error) {
          Failure(Ok(checked), [
            diagnostic.error(
              "codegen.unsupported",
              "unsupported code generation",
            )
            |> diagnostic.primary(
              location.new(module.path, error.span),
              error.feature,
            )
            |> diagnostic.conclusion(
              "This construct is not supported by the executable core yet.",
            ),
          ])
        }),
      )
      let generated =
        erlang.Output(
          ..generated,
          forms: runtime.scope(
            generated.forms,
            package.module_owner(module.identity, checked.project.name).0,
          ),
        )
      let abstract = beam.abstract_forms(generated.forms)
      use #(binary, compiled) <- result.try(
        compile_module(
          layout.erlang(
            checked.project.root,
            package.module_owner(module.identity, checked.project.name).0,
            mode,
          ),
          generated.name,
          generated.forms,
          abstract,
          reuse,
        )
        |> result.map_error(fn(detail) { failure(checked, module.path, detail) }),
      )
      Ok(Artifact(
        generated.name,
        abstract,
        binary,
        compiled,
        list.map(generated.tests, fn(test_case) {
          Test(
            generated.name,
            test_case.name,
            test_case.description,
            module.path,
            test_case.span,
            test_case.skipped,
          )
        }),
      ))
    }),
  )
  let owners = list.append(checked.packages, [checked.project])
  use native_library <- result.try(
    native.directory(paths.target)
    |> result.map_error(failure(checked, paths.target, _)),
  )
  use <- native.using_directory(native_library)

  use Nil <- result.try(
    list.try_each(owners, fn(owner) {
      case owner.kind {
        dependency.Beam(_, _) -> Ok(Nil)
        dependency.Pooka -> {
          let selected =
            list.filter(artifacts, fn(a) {
              string.starts_with(a.name, "pooka@" <> owner.name <> "@")
            })
          use binary <- result.try(
            beam.runtime_binary_for(owner.name)
            |> result.map_error(failure(checked, owner.root, _)),
          )
          let resource =
            application.render_with_metadata(
              owner.name,
              owner.version,
              [runtime.name(owner.name), ..list.map(selected, fn(a) { a.name })],
              [],
              owner.config,
            )
          native.stage_pooka(
            owner,
            native_library,
            [
              #(runtime.name(owner.name), binary),
              ..list.map(selected, fn(a) { #(a.name, a.binary) })
            ],
            resource,
          )
          |> result.map_error(failure(checked, owner.root, _))
        }
      }
    }),
  )
  use packages <- result.try(
    list.try_map(owners, fn(owner) {
      let paths =
        layout.erlang(checked.project.root, native.application(owner), mode)
      let local =
        check.Report(
          ..checked,
          project: owner,
          files: list.filter(checked.files, fn(file) {
            package.owner(file.path, checked.project.name) == owner.name
          }),
        )
      let key = stamp.package_key(snapshot, owner.name)
      use #(foreign, resource, rebuilt) <- result.try(case owner.kind {
        dependency.Pooka ->
          cached_foreign(
            filepath.join(paths.artifacts, "foreign.cache"),
            stamp.foreign_key(snapshot, owner.name),
            fn() { foreign_modules(local, paths) },
          )
          |> result.map(fn(value) { #(value.0, None, value.1) })
        dependency.Beam(_, _) ->
          native.compile_cached(
            owner,
            native_library,
            filepath.join(paths.artifacts, "native.cache"),
            key,
          )
          |> result.map(fn(value) { #(value.0.0, Some(value.0.1), value.1) })
          |> result.map_error(failure(checked, owner.root, _))
      })

      use natives <- result.try(case owner.kind {
        dependency.Pooka ->
          nif.prepare(
            owner,
            local.files,
            paths.package,
            paths.artifacts,
            native.application(owner),
            layout.mode_name(mode),
          )
          |> result.map_error(fn(error) { Failure(Ok(checked), [error]) })
        dependency.Beam(_, _) -> Ok(nif.Prepared([], []))
      })
      Ok(#(
        local,
        paths,
        list.append(foreign, natives.loaders),
        resource,
        rebuilt || natives.rebuilt != [],
      ))
    }),
  )
  let names = list.map(artifacts, fn(value) { value.name })
  let foreign_names =
    list.flat_map(packages, fn(p) { list.map(p.2, fn(value) { value.0 }) })
  let runtime_names =
    owners
    |> list.filter(fn(owner) { owner.kind == dependency.Pooka })
    |> list.map(fn(owner) { runtime.name(owner.name) })
  use Nil <- result.try(validate_foreign_names(
    checked,
    list.append(names, runtime_names),
    foreign_names,
  ))

  use Nil <- result.try(
    list.try_each(packages, fn(prepared) {
      let #(local, paths, foreign, native_resource, _) = prepared
      let selected =
        list.filter(artifacts, fn(a) {
          string.starts_with(a.name, "pooka@" <> local.project.name <> "@")
        })
      let own_names = list.map(selected, fn(a) { a.name })
      let foreign_names = list.map(foreign, fn(value) { value.0 })
      use Nil <- result.try(
        list.try_each(
          [paths.ebin, paths.artifacts, paths.include],
          fn(directory) {
            simplifile.create_directory_all(directory)
            |> result.map_error(fn(error) {
              failure(local, directory, simplifile.describe_error(error))
            })
          },
        ),
      )
      use Nil <- result.try(
        list.try_each(selected, fn(artifact) {
          use Nil <- result.try(write_bits(
            local,
            layout.beam(paths, artifact.name),
            artifact.binary,
          ))
          use Nil <- result.try(write_bits(
            local,
            layout.abstract_forms(paths, artifact.name),
            artifact.abstract,
          ))
          write_bits(
            local,
            filepath.join(paths.artifacts, artifact.name <> ".beam.hash"),
            stamp.digest(artifact.binary),
          )
        }),
      )
      use Nil <- result.try(case local.project.kind {
        dependency.Pooka -> {
          use binary <- result.try(
            beam.runtime_binary_for(local.project.name)
            |> result.map_error(failure(local, paths.ebin, _)),
          )
          write_bits(
            local,
            layout.beam(paths, runtime.name(local.project.name)),
            binary,
          )
        }
        _ -> Ok(Nil)
      })
      let root = local.project.name == checked.project.name
      // Remove the obsolete unqualified helper from earlier compiler output.
      // The package-qualified module is the only runtime this app owns.
      use Nil <- result.try(
        case simplifile.delete_file(layout.beam(paths, "pooka_runtime_ffi")) {
          Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
          Error(error) ->
            Error(failure(local, paths.ebin, simplifile.describe_error(error)))
        },
      )
      use Nil <- result.try(
        write_foreign(local, paths, foreign, [
          runtime.name(local.project.name),
          "pooka_runtime_ffi",
          ..names
        ]),
      )
      let requirements = case root && include_tests {
        True ->
          list.append(
            local.project.dependencies,
            local.project.dev_dependencies,
          )
        False -> local.project.dependencies
      }
      let resource = case native_resource {
        Some(resource) -> resource
        None ->
          application.render_with_metadata(
            local.project.name,
            local.project.version,
            list.flatten([
              [runtime.name(local.project.name), ..own_names],
              foreign_names,
            ]),
            native.applications(requirements, owners),
            local.project.config,
          )
      }
      use Nil <- result.try(write_text(
        local,
        filepath.join(paths.ebin, native.application(local.project) <> ".app"),
        resource,
      ))
      use Nil <- result.try(
        prune(local, paths.ebin, [".beam"], [
          runtime.name(local.project.name),
          ..list.append(own_names, foreign_names)
        ]),
      )
      use Nil <- result.try(prune(local, paths.artifacts, [".erl"], []))
      use Nil <- result.try(prune(local, paths.ebin, [".erl"], []))
      use Nil <- result.try(prune(
        local,
        paths.artifacts,
        [".abstr", ".beam.hash"],
        own_names,
      ))
      write_text(
        local,
        paths.module_manifest,
        string.join(own_names, "\n") <> "\n",
      )
    }),
  )
  use Nil <- result.try(migrate_legacy(checked))
  use Nil <- result.try(write_bits(checked, paths.fingerprint, fingerprint))
  let managed = filepath.join(paths.artifacts, "dependencies")
  let dependency_names =
    list.map(checked.packages, fn(p) { native.application(p) })
  let previous = case simplifile.read(managed) {
    Ok(text) -> string.split(text, "\n")
    Error(_) -> []
  }
  use Nil <- result.try(
    list.try_each(previous, fn(name) {
      case
        project_name.validate(name),
        list.contains(dependency_names, name),
        name == checked.project.name
      {
        Ok(Nil), False, False ->
          simplifile.delete(
            layout.erlang(checked.project.root, name, mode).package,
          )
          |> result.map_error(fn(error) {
            failure(checked, name, simplifile.describe_error(error))
          })
        _, _, _ -> Ok(Nil)
      }
    }),
  )
  use Nil <- result.try(write_text(
    checked,
    managed,
    string.join(dependency_names, "\n"),
  ))
  use Nil <- result.try(
    lockfile.write(checked.project, checked.packages)
    |> result.map_error(fn(error) {
      Failure(Ok(checked), [project_error.to_diagnostic(error)])
    }),
  )
  let entry = case
    list.find(production, fn(module) { module.identity == "main" })
  {
    Error(Nil) -> Error(Nil)
    Ok(module) ->
      case
        list.find(module.inferred.functions, fn(value) {
          value.name.name == "main"
        })
      {
        Error(Nil) -> Error(Nil)
        Ok(function) ->
          case function.type_ {
            monotype.FunctionType([], _) ->
              Ok(erlang.module_name(checked.project.name, "main"))
            _ -> Error(Nil)
          }
      }
  }
  Ok(Report(
    checked,
    inferred.diagnostics,
    paths.ebin,
    names,
    entry,
    list.flat_map(artifacts, fn(value) { value.tests }),
    paths,
    artifacts
      |> list.filter(fn(value) { value.compiled })
      |> list.map(fn(value) { value.name }),
    False,
    list.flat_map(packages, fn(prepared) {
      case prepared.4 {
        True -> list.map(prepared.2, fn(value) { value.0 })
        False -> []
      }
    }),
    list.filter_map(packages, fn(prepared) {
      let name = prepared.0.project.name
      case
        { prepared.4 && prepared.2 != [] }
        || list.any(artifacts, fn(a) {
          a.compiled && string.starts_with(a.name, "pooka@" <> name <> "@")
        })
      {
        True -> Ok(name)
        False -> Error(Nil)
      }
    }),
  ))
}

@external(erlang, "pooka_incremental_ffi", "foreign")
fn cached_foreign(
  path: String,
  key: BitArray,
  run: fn() -> Result(List(#(String, BitArray)), Failure),
) -> Result(#(List(#(String, BitArray)), Bool), Failure)

fn failure(checked: check.Report, path: String, detail: String) -> Failure {
  Failure(Ok(checked), [
    diagnostic.error("build.failed", "build failed")
    |> diagnostic.conclusion(path <> ": " <> detail),
  ])
}

fn preview_failure(error: infer.PreviewError) -> Failure {
  case error {
    infer.ProjectFailed(error) ->
      Failure(Error(Nil), [project_error.to_diagnostic(error)])
    infer.InvalidProgram(checked) ->
      Failure(Ok(checked), check.diagnostics(checked))
    infer.UnsupportedSource(path, feature) ->
      Failure(Error(Nil), [infer.unsupported_diagnostic(path, feature)])
  }
}

fn compile_module(
  paths: layout.Layout,
  name: String,
  forms: List(forms.Term),
  abstract: BitArray,
  reuse: Bool,
) -> Result(#(BitArray, Bool), String) {
  let cached = case
    reuse
    && simplifile.read_bits(layout.abstract_forms(paths, name)) == Ok(abstract)
  {
    True -> simplifile.read_bits(layout.beam(paths, name))
    False -> Error(simplifile.Enoent)
  }
  case cached {
    Ok(binary) ->
      case
        beam.valid_module(binary, name)
        && simplifile.read_bits(filepath.join(
          paths.artifacts,
          name <> ".beam.hash",
        ))
        == Ok(stamp.digest(binary))
      {
        True -> Ok(#(binary, False))
        False ->
          beam.compile(forms) |> result.map(fn(binary) { #(binary, True) })
      }
    Error(_) ->
      beam.compile(forms) |> result.map(fn(binary) { #(binary, True) })
  }
}

fn write_bits(
  checked: check.Report,
  path: String,
  contents: BitArray,
) -> Result(Nil, Failure) {
  case simplifile.read_bits(path) == Ok(contents) {
    True -> Ok(Nil)
    False ->
      simplifile.write_bits(path, contents)
      |> result.map_error(fn(error) {
        failure(checked, path, simplifile.describe_error(error))
      })
  }
}

fn write_text(
  checked: check.Report,
  path: String,
  contents: String,
) -> Result(Nil, Failure) {
  case simplifile.read(path) == Ok(contents) {
    True -> Ok(Nil)
    False ->
      simplifile.write(path, contents)
      |> result.map_error(fn(error) {
        failure(checked, path, simplifile.describe_error(error))
      })
  }
}

fn prune(
  checked: check.Report,
  directory: String,
  extensions: List(String),
  current: List(String),
) -> Result(Nil, Failure) {
  let prefix = "pooka@" <> checked.project.name <> "@"
  use entries <- result.try(case simplifile.read_directory(directory) {
    Ok(entries) -> Ok(entries)
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error(failure(checked, directory, simplifile.describe_error(error)))
  })
  list.try_each(entries, fn(entry) {
    let obsolete =
      list.any(extensions, fn(extension) {
        string.starts_with(entry, prefix)
        && string.ends_with(entry, extension)
        && !list.contains(
          current,
          string.drop_end(entry, string.length(extension)),
        )
      })
    case obsolete {
      False -> Ok(Nil)
      True ->
        simplifile.delete_file(filepath.join(directory, entry))
        |> result.map_error(fn(error) {
          failure(checked, directory, simplifile.describe_error(error))
        })
    }
  })
}

fn migrate_legacy(checked: check.Report) -> Result(Nil, Failure) {
  let legacy = filepath.join(checked.project.root, "build/erlang")
  case simplifile.is_symlink(legacy) {
    Ok(True) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) ->
      Error(failure(checked, legacy, simplifile.describe_error(error)))
    Ok(False) -> {
      use Nil <- result.try(prune(checked, legacy, [".beam", ".erl"], []))
      use Nil <- result.try(
        case
          simplifile.delete_file(filepath.join(legacy, "pooka_runtime_ffi.beam"))
        {
          Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
          Error(error) ->
            Error(failure(checked, legacy, simplifile.describe_error(error)))
        },
      )
      case simplifile.read_directory(legacy) {
        Ok([]) ->
          simplifile.delete(legacy)
          |> result.map_error(fn(error) {
            failure(checked, legacy, simplifile.describe_error(error))
          })
        _ -> Ok(Nil)
      }
    }
  }
}

fn foreign_modules(
  checked: check.Report,
  paths: layout.Layout,
) -> Result(List(#(String, BitArray)), Failure) {
  foreign.compile(
    checked.project.root,
    filepath.join(paths.artifacts, "foreign"),
  )
  |> result.map_error(fn(error) {
    Failure(Ok(checked), [foreign.to_diagnostic(error, checked.project.root)])
  })
}

fn foreign_manifest(paths: layout.Layout) -> String {
  filepath.join(paths.artifacts, "foreign_modules")
}

fn write_foreign(
  checked: check.Report,
  paths: layout.Layout,
  modules: List(#(String, BitArray)),
  protected: List(String),
) -> Result(Nil, Failure) {
  let names = list.map(modules, fn(module) { module.0 })
  let previous = case simplifile.read(foreign_manifest(paths)) {
    Ok(text) -> string.split(text, "\n") |> list.filter(fn(name) { name != "" })
    Error(_) -> []
  }
  use Nil <- result.try(
    previous
    |> list.filter(fn(name) {
      !list.contains(names, name) && !list.contains(protected, name)
    })
    |> list.try_each(fn(name) {
      case simplifile.delete_file(layout.beam(paths, name)) {
        Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
        Error(error) ->
          Error(failure(
            checked,
            layout.beam(paths, name),
            simplifile.describe_error(error),
          ))
      }
    }),
  )
  use Nil <- result.try(
    list.try_each(modules, fn(module) {
      write_bits(checked, layout.beam(paths, module.0), module.1)
    }),
  )
  write_text(checked, foreign_manifest(paths), string.join(names, "\n") <> "\n")
}

fn validate_foreign_names(
  checked: check.Report,
  generated: List(String),
  foreign: List(String),
) -> Result(Nil, Failure) {
  let protected = ["pooka_runtime_ffi", ..generated]
  let collisions =
    foreign
    |> list.filter(fn(name) {
      list.contains(protected, name)
      || list.count(foreign, fn(other) { other == name }) > 1
    })
    |> list.unique
  case collisions {
    [] -> Ok(Nil)
    _ ->
      Error(
        Failure(Ok(checked), [
          diagnostic.error(
            "build.foreign_module_collision",
            "foreign module name collision",
          )
          |> diagnostic.conclusion(
            "These foreign module names have more than one owner: "
            <> string.join(collisions, ", ")
            <> ".",
          )
          |> diagnostic.help(
            "Rename the foreign module or its conflicting declaration before building.",
          ),
        ]),
      )
  }
}
