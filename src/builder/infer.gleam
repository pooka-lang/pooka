//// Ask the type checker what it learned from the syntax.
////
//// Bridge checked source modules to inference reports and convert unsupported
//// cases into diagnostics. Preserve the originating path when a lower layer
//// reports a problem.
////
//// ```text
//// parsed module + imported interfaces -> inferred signatures
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/check
import builder/type_cache
import compiler/analysis/module
import compiler/compiler
import compiler/typesystem/infer
import compiler/typesystem/module_infer
import compiler/typesystem/nominal
import compiler/typesystem/unify
import diagnostics/diagnostic.{type Diagnostic}
import filepath
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import project/project_error.{type ProjectError}
import utilities/location

pub type TypedModule {
  TypedModule(identity: String, path: String, inferred: module_infer.Module)
}

pub type Report {
  Report(
    checked: check.Report,
    modules: List(TypedModule),
    diagnostics: List(Diagnostic),
    checked_modules: List(String),
  )
}

pub type PreviewError {
  ProjectFailed(ProjectError)
  InvalidProgram(check.Report)
  UnsupportedSource(path: String, feature: infer.Unsupported)
}

type Role {
  Production
  TestClient
}

type Progress {
  Progress(
    available: Dict(String, TypedModule),
    modules: List(TypedModule),
    state: unify.State,
    diagnostics: List(Diagnostic),
    cache: String,
    checked_modules: List(String),
  )
}

pub fn preview(directory: String) -> Result(Report, PreviewError) {
  use checked <- result.try(
    check.check_project(directory) |> result.map_error(ProjectFailed),
  )
  preview_report(checked)
}

pub fn preview_report(checked: check.Report) -> Result(Report, PreviewError) {
  preview_with_cache(
    checked,
    filepath.join(checked.project.root, "build/analysis"),
    False,
  )
}

/// Editor buffers must never populate the build's on-disk analysis cache.
pub fn preview_in_memory(
  checked: check.Report,
) -> Result(Report, PreviewError) {
  // Editor reports retain lints from intact buffers even when a neighbour
  // is still being typed and has structural errors.
  let files = list.map(checked.files, compiler.with_lints)
  preview_with_cache(check.Report(..checked, files:), "", True)
}

fn preview_with_cache(
  checked: check.Report,
  cache: String,
  editor: Bool,
) -> Result(Report, PreviewError) {
  let structural = check.diagnostics(checked)
  use Nil <- result.try(case !editor && diagnostic.has_errors(structural) {
    True -> Error(InvalidProgram(checked))
    False -> Ok(Nil)
  })
  // Skip broken modules and their importers during inference. Continue
  // checking independent modules rather than inventing missing types.
  let blocked =
    list.flat_map(structural, fn(item) {
      case item.severity {
        diagnostic.ErrorSeverity ->
          list.filter_map(item.labels, fn(label) {
            case label.importance {
              diagnostic.Primary -> Ok(label.location.path)
              diagnostic.Secondary -> Error(Nil)
            }
          })
        _ -> []
      }
    })
  let files = case editor {
    False -> checked.files
    True ->
      list.filter(checked.files, fn(file) {
        !diagnostic.has_errors(file.diagnostics)
        && !list.contains(blocked, check.display_path(checked, file.path))
      })
  }
  let sources =
    list.filter_map(files, fn(file) {
      compiler.expected_module_path(file.path)
      |> result.map(fn(identity) {
        module.SourceModule(identity, file.path, file.parsed.module)
      })
    })
  use ordered <- result.try(
    module.order(sources)
    |> result.map_error(fn(errors) {
      InvalidProgram(
        check.Report(
          ..checked,
          project_diagnostics: list.append(checked.project_diagnostics, errors),
        ),
      )
    }),
  )
  let state = unify.new()
  let initial =
    Progress(dict.new(), [], state, check.diagnostics(checked), cache, [])
  use progress <- result.try(
    list.try_fold(ordered, initial, fn(progress, source) {
      infer_next(source, Production, progress, editor)
    }),
  )
  let tests =
    list.filter_map(files, fn(file) {
      case compiler.expected_module_path(file.path) {
        Ok(_) -> Error(Nil)
        Error(Nil) ->
          Ok(module.SourceModule(file.path, file.path, file.parsed.module))
      }
    })
  use progress <- result.try(
    list.try_fold(tests, progress, fn(progress, source) {
      infer_next(source, TestClient, progress, editor)
    }),
  )
  Ok(Report(
    checked,
    list.reverse(progress.modules),
    diagnostic.sort(check.display_diagnostics(checked, progress.diagnostics)),
    list.reverse(progress.checked_modules),
  ))
}

fn infer_next(
  source: module.SourceModule,
  role: Role,
  progress: Progress,
  editor: Bool,
) -> Result(Progress, PreviewError) {
  let ready =
    list.all(source.syntax.imports, fn(imported) {
      dict.has_key(
        progress.available,
        string.join(imported.module.segments, "/"),
      )
    })
  case editor && !ready {
    True -> Ok(progress)
    False -> {
      case infer_source(source, role, progress) {
        Error(UnsupportedSource(path, feature)) if editor ->
          Ok(
            Progress(..progress, diagnostics: [
              unsupported_diagnostic(path, feature),
              ..progress.diagnostics
            ]),
          )
        outcome -> outcome
      }
    }
  }
}

fn infer_source(
  source: module.SourceModule,
  role: Role,
  progress: Progress,
) -> Result(Progress, PreviewError) {
  let dependencies =
    source.syntax.imports
    |> list.filter_map(fn(imported) {
      dict.get(progress.available, string.join(imported.module.segments, "/"))
    })
  let state =
    unify.module_state(
      source.identity,
      list.map(dependencies, fn(dep) { dep.inferred.state }),
    )
  let key =
    type_cache.key(
      source,
      list.map(dependencies, fn(dep) {
        #(dep.identity, type_cache.interface(dep.inferred))
      }),
    )
  use environment <- result.try(imports(source, progress.available, state))
  let state =
    list.fold(source.syntax.imports, state, fn(state, imported) {
      let identity = string.join(imported.module.segments, "/")
      let alias = case imported.alias {
        Some(alias) -> alias.name
        None -> list.last(imported.module.segments) |> result.unwrap(identity)
      }
      let types =
        list.append(
          list.map(unify.classes_in(state, identity), fn(class) {
            #(class.module, class.source.name.name)
          }),
          list.map(unify.interfaces_in(state, identity), fn(interface) {
            #(interface.module, interface.source.name.name)
          }),
        )
        |> list.append(list.map(
          unify.enums_in(state, identity),
          nominal.enum_identity,
        ))
      list.fold(types, state, fn(state, type_) {
        case string.starts_with(type_.1, "_") {
          True -> state
          False -> {
            let state =
              unify.bind_type(state, source.path, alias, type_.1, type_)
            list.fold(imported.items, state, fn(state, item) {
              case item.name.name == type_.1 {
                False -> state
                True ->
                  unify.bind_type(
                    state,
                    source.path,
                    "",
                    case item.alias {
                      Some(alias) -> alias.name
                      None -> item.name.name
                    },
                    type_,
                  )
              }
            })
          }
        }
      })
    })
  let cached = type_cache.load(progress.cache, source.identity, key)
  use report <- result.try(
    case cached {
      Ok(cached) ->
        Ok(
          module_infer.Module(
            ..cached,
            state: unify.rebase_module(
              cached.state,
              state,
              source.identity,
              source.path,
            ),
          ),
        )
      Error(_) -> {
        module_infer.infer(source.syntax, environment, state, source.path)
      }
    }
    |> result.map_error(UnsupportedSource(source.path, _)),
  )

  case diagnostic.has_errors(report.diagnostics) || result.is_ok(cached) {
    False -> {
      // A cache hit rebases the saved local inference onto the current
      // imports. Keep only the state that survives that operation on disk.
      let local =
        unify.rebase_module(
          report.state,
          unify.new(),
          source.identity,
          source.path,
        )
      type_cache.save(
        progress.cache,
        source.identity,
        key,
        module_infer.Module(..report, state: local),
      )
    }
    True -> Nil
  }
  let typed = TypedModule(source.identity, source.path, report)
  let available = case role {
    Production -> dict.insert(progress.available, source.identity, typed)
    TestClient -> progress.available
  }
  Ok(
    Progress(
      available,
      [typed, ..progress.modules],
      report.state,
      list.append(progress.diagnostics, report.diagnostics),
      progress.cache,
      case cached {
        Ok(_) -> progress.checked_modules
        Error(_) -> [source.identity, ..progress.checked_modules]
      },
    ),
  )
}

fn imports(
  source: module.SourceModule,
  available: Dict(String, TypedModule),
  state: unify.State,
) -> Result(infer.Environment, PreviewError) {
  list.try_fold(source.syntax.imports, dict.new(), fn(environment, imported) {
    let identity = string.join(imported.module.segments, "/")

    let namespaces = case dict.get(available, identity) {
      Ok(target) ->
        target.inferred.externals
        |> list.filter(fn(value) { !string.starts_with(value.name.name, "_") })
        |> list.map(fn(value) {
          #(
            value.name.name,
            value.functions
              |> list.map(fn(function) {
                #(function.name.name, function.scheme)
              })
              |> dict.from_list,
          )
        })
        |> dict.from_list
      Error(Nil) -> dict.new()
    }
    use declarations <- result.try(case dict.get(available, identity) {
      Ok(target) ->
        Ok(
          target.inferred.functions
          |> list.filter(fn(value) { !string.starts_with(value.name.name, "_") })
          |> list.map(fn(value) { #(value.name.name, value.scheme) })
          |> dict.from_list,
        )
      Error(Nil) ->
        Error(UnsupportedSource(
          source.path,
          infer.Unsupported(
            imported.module.span,
            "unresolved module `" <> identity <> "`",
          ),
        ))
    })
    use alias <- result.try(case imported.alias {
      Some(alias) -> Ok(alias.name)
      None ->
        list.last(imported.module.segments)
        |> result.map_error(fn(_) {
          UnsupportedSource(
            source.path,
            infer.Unsupported(imported.span, "empty module path"),
          )
        })
    })
    let environment =
      dict.insert(
        environment,
        alias,
        infer.ModuleBinding(identity, declarations, namespaces),
      )
    list.try_fold(imported.items, environment, fn(environment, item) {
      let local = case item.alias {
        Some(alias) -> alias.name
        None -> item.name.name
      }
      use <- bool.lazy_guard(dict.has_key(namespaces, item.name.name), fn() {
        let functions =
          dict.get(namespaces, item.name.name) |> result.unwrap(dict.new())
        Ok(dict.insert(
          environment,
          local,
          infer.NamespaceBinding(local, functions),
        ))
      })
      let interface = case dict.get(available, identity) {
        Error(Nil) ->
          list.find(unify.interfaces_in(state, identity), fn(interface) {
            interface.source.name.name == item.name.name
            && !string.starts_with(item.name.name, "_")
          })
        Ok(target) ->
          list.find(
            unify.interfaces_in(target.inferred.state, identity),
            fn(interface) {
              interface.source.name.name == item.name.name
              && !string.starts_with(item.name.name, "_")
            },
          )
      }
      use <- bool.lazy_guard(result.is_ok(interface), fn() {
        let assert Ok(interface) = interface
        Ok(dict.insert(
          environment,
          local,
          infer.InterfaceBinding(#(interface.module, interface.source.name.name)),
        ))
      })
      let enum = case dict.get(available, identity) {
        Error(Nil) -> Error(Nil)
        Ok(target) ->
          list.find(unify.enums_in(target.inferred.state, identity), fn(enum) {
            enum.source.name.name == item.name.name
            && !string.starts_with(item.name.name, "_")
          })
      }
      use <- bool.lazy_guard(result.is_ok(enum), fn() {
        let assert Ok(enum) = enum
        Ok(dict.insert(
          environment,
          local,
          infer.EnumBinding(nominal.enum_identity(enum)),
        ))
      })
      let class = case dict.get(available, identity) {
        Error(Nil) -> Error(Nil)
        Ok(target) ->
          list.find(
            unify.classes_in(target.inferred.state, identity),
            fn(class) {
              class.source.name.name == item.name.name
              && !string.starts_with(item.name.name, "_")
            },
          )
      }
      use <- bool.lazy_guard(result.is_ok(class), fn() {
        let assert Ok(class) = class
        Ok(dict.insert(
          environment,
          local,
          infer.ClassBinding(#(class.module, class.source.name.name)),
        ))
      })
      use signature <- result.try(
        dict.get(declarations, item.name.name)
        |> result.map_error(fn(_) {
          UnsupportedSource(
            source.path,
            infer.Unsupported(
              item.span,
              "inferred public declaration `"
                <> identity
                <> "."
                <> item.name.name
                <> "`",
            ),
          )
        }),
      )
      Ok(dict.insert(
        environment,
        local,
        infer.Binding(signature, item.name.span),
      ))
    })
  })
}

pub fn check_diagnostics(checked: check.Report) -> List(Diagnostic) {
  let structural = check.diagnostics(checked)
  case diagnostic.has_errors(structural) {
    True -> structural
    False ->
      case preview_report(checked) {
        Ok(report) -> report.diagnostics
        Error(InvalidProgram(checked)) -> check.diagnostics(checked)
        Error(UnsupportedSource(path, feature)) ->
          list.append(structural, [unsupported_diagnostic(path, feature)])
          |> check.display_diagnostics(checked, _)
          |> diagnostic.sort
        Error(ProjectFailed(error)) -> [project_error.to_diagnostic(error)]
      }
  }
}

pub fn unsupported_diagnostic(
  path: String,
  feature: infer.Unsupported,
) -> Diagnostic {
  diagnostic.error("type.unsupported", "unsupported type-system feature")
  |> diagnostic.primary(location.new(path, feature.span), feature.feature)
  |> diagnostic.conclusion(
    "This program uses a feature outside the executable core.",
  )
}
