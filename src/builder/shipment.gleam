//// A shipment is a program with its boots and coat.
////
//// Export the Erlang application tree and launch scripts for supported shells.
//// The scripts locate the shipment's modules rather than relying on the
//// compiler's checkout.
////
//// ```text
//// erlang-shipment/entrypoint.sh run <command>
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/application
import builder/build
import builder/layout
import builder/native
import compiler/codegen/beam
import compiler/codegen/entrypoint
import compiler/foreign_language
import compiler/parser/ast
import diagnostics/diagnostic
import filepath
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type Report {
  Report(build: build.Report, directory: String)
}

pub fn export(directory: String) -> Result(Report, build.Failure) {
  use built <- result.try(build.build_production(directory))
  let project = built.checked.project
  use entry <- result.try(
    built.entry
    |> result.map_error(fn(_) {
      failure(
        built,
        "export.missing_entry",
        "missing executable entrypoint",
        "Shipment export requires src/main.pooka to define main() with no arguments.",
      )
    }),
  )
  let bootstrap = entrypoint.module_name(project.name)
  use Nil <- result.try(
    case
      simplifile.exists(
        filepath.join(built.directory, bootstrap <> ".beam"),
        False,
      )
    {
      Ok(False) -> Ok(Nil)
      Ok(True) ->
        Error(failure(
          built,
          "export.module_collision",
          "export entrypoint conflicts with a foreign module",
          bootstrap,
        ))
      Error(error) -> Error(io_failure(built, built.directory, error))
    },
  )
  use wrapper <- result.try(
    beam.compile(entrypoint.forms(project.name, entry))
    |> result.map_error(failure(
      built,
      "export.compile",
      "export entrypoint could not be compiled",
      _,
    )),
  )
  let foreign_targets =
    built.checked.files
    |> list.flat_map(fn(file) {
      file.parsed.module.declarations
      |> list.filter_map(fn(declaration) {
        case declaration {
          ast.ExternalDeclaration(value) ->
            Ok(foreign_language.beam_module(value.language, value.module))
          _ -> Error(Nil)
        }
      })
    })
  use runtimes <- result.try(
    list.try_map(
      list.append(
        [#(built.directory, project.name)],
        list.map(built.checked.packages, fn(p) {
          #(
            layout.erlang(
              project.root,
              native.application(p),
              layout.Production,
            ).ebin,
            native.application(p),
          )
        }),
      ),
      fn(package) { runtime_packages(package.0, foreign_targets, package.1) },
    )
    |> result.map(fn(groups) { list.flatten(groups) |> list.unique })
    |> result.map_error(failure(
      built,
      "export.runtime",
      "foreign runtime could not be packaged",
      _,
    )),
  )
  use Nil <- result.try(
    case
      list.any(runtimes, fn(runtime) {
        runtime.0 == project.name
        || list.any(built.checked.packages, fn(p) {
          native.application(p) == runtime.0
        })
      })
    {
      True ->
        Error(failure(
          built,
          "export.package_collision",
          "application name conflicts with a foreign runtime",
          project.name,
        ))
      False -> Ok(Nil)
    },
  )
  let destination = filepath.join(project.root, "build/shipment")
  use staging <- result.try(
    temporary_directory(destination)
    |> result.map_error(failure(
      built,
      "export.filesystem",
      "could not prepare shipment",
      _,
    )),
  )
  let prepared = prepare(built, bootstrap, wrapper, runtimes, staging)
  let published = case prepared {
    Error(error) -> Error(error)
    Ok(Nil) ->
      publish_directory(staging, destination)
      |> result.map_error(failure(
        built,
        "export.filesystem",
        "could not publish shipment",
        _,
      ))
  }

  let _ = simplifile.delete(staging)
  result.map(published, fn(_) { Report(built, destination) })
}

fn prepare(
  built: build.Report,
  bootstrap: String,
  wrapper: BitArray,
  runtimes: List(#(String, String)),
  staging: String,
) -> Result(Nil, build.Failure) {
  let project = built.checked.project
  let package = filepath.join(staging, project.name)
  let ebin = filepath.join(package, "ebin")
  use Nil <- result.try(copy_ebin(built, built.directory, ebin, project.name))
  use Nil <- result.try(
    simplifile.write_bits(filepath.join(ebin, bootstrap <> ".beam"), wrapper)
    |> result.map_error(io_failure(built, ebin, _)),
  )
  use names <- result.try(
    simplifile.read_directory(ebin)
    |> result.map_error(io_failure(built, ebin, _)),
  )
  let modules =
    names
    |> list.filter(string.ends_with(_, ".beam"))
    |> list.map(string.drop_end(_, 5))
  use Nil <- result.try(
    simplifile.write(
      filepath.join(ebin, project.name <> ".app"),
      application.render_with_metadata(
        project.name,
        project.version,
        modules,
        list.append(
          list.map(runtimes, fn(value) { value.0 }),
          native.applications(
            project.dependencies,
            list.append(built.checked.packages, [project]),
          ),
        ),
        project.config,
      ),
    )
    |> result.map_error(io_failure(built, ebin, _)),
  )
  use Nil <- result.try(copy_optional_priv(
    built,
    filepath.join(project.root, "priv"),
    filepath.join(package, "priv"),
  ))

  use Nil <- result.try(copy_optional_priv(
    built,
    filepath.join(filepath.directory_name(built.directory), "native"),
    filepath.join(package, "native"),
  ))
  use Nil <- result.try(
    list.try_each(built.checked.packages, fn(dependency) {
      let destination = filepath.join(staging, native.application(dependency))
      use Nil <- result.try(copy_ebin(
        built,
        layout.erlang(
          project.root,
          native.application(dependency),
          layout.Production,
        ).ebin,
        filepath.join(destination, "ebin"),
        native.application(dependency),
      ))
      use Nil <- result.try(copy_optional_priv(
        built,
        filepath.join(dependency.root, "priv"),
        filepath.join(destination, "priv"),
      ))
      copy_optional_priv(
        built,
        filepath.join(
          layout.erlang(
            project.root,
            native.application(dependency),
            layout.Production,
          ).package,
          "native",
        ),
        filepath.join(destination, "native"),
      )
    }),
  )
  use Nil <- result.try(
    list.try_each(runtimes, fn(runtime) {
      let package = filepath.join(staging, runtime.0)
      use Nil <- result.try(copy_ebin(
        built,
        filepath.join(runtime.1, "ebin"),
        filepath.join(package, "ebin"),
        runtime.0,
      ))
      copy_optional_priv(
        built,
        filepath.join(runtime.1, "priv"),
        filepath.join(package, "priv"),
      )
    }),
  )
  use Nil <- result.try(write_launcher(
    built,
    filepath.join(staging, "entrypoint.sh"),
    shell_script(bootstrap),
  ))
  simplifile.write(
    filepath.join(staging, "entrypoint.ps1"),
    powershell_script(bootstrap),
  )
  |> result.map_error(io_failure(built, staging, _))
}

fn copy_ebin(
  built: build.Report,
  source: String,
  destination: String,
  app_name: String,
) -> Result(Nil, build.Failure) {
  use Nil <- result.try(
    simplifile.create_directory_all(destination)
    |> result.map_error(io_failure(built, destination, _)),
  )
  use modules <- result.try(
    package_modules(source, app_name)
    |> result.map_error(failure(
      built,
      "export.application",
      "invalid OTP application resource",
      _,
    )),
  )
  let name = app_name
  list.append(list.map(modules, fn(module) { module <> ".beam" }), [
    name <> ".app",
  ])
  |> list.try_each(fn(name) {
    copy_file(
      built,
      filepath.join(source, name),
      filepath.join(destination, name),
    )
  })
}

fn copy_optional_priv(
  built: build.Report,
  source: String,
  destination: String,
) -> Result(Nil, build.Failure) {
  case simplifile.exists(source, False) {
    Ok(False) -> Ok(Nil)
    Ok(True) -> {
      use Nil <- result.try(regular_path(built, source))
      use directory <- result.try(
        simplifile.is_directory(source)
        |> result.map_error(io_failure(built, source, _)),
      )
      case directory {
        True -> copy_tree(built, source, destination)
        False ->
          Error(failure(
            built,
            "export.resource_type",
            "priv must be a directory",
            source,
          ))
      }
    }
    Error(error) -> Error(io_failure(built, source, error))
  }
}

fn copy_tree(
  built: build.Report,
  source: String,
  destination: String,
) -> Result(Nil, build.Failure) {
  use Nil <- result.try(regular_path(built, source))
  use directory <- result.try(
    simplifile.is_directory(source)
    |> result.map_error(io_failure(built, source, _)),
  )
  case directory {
    False -> copy_file(built, source, destination)
    True -> {
      use Nil <- result.try(
        simplifile.create_directory_all(destination)
        |> result.map_error(io_failure(built, destination, _)),
      )
      use entries <- result.try(
        simplifile.read_directory(source)
        |> result.map_error(io_failure(built, source, _)),
      )
      entries
      |> list.sort(string.compare)
      |> list.try_each(fn(name) {
        copy_tree(
          built,
          filepath.join(source, name),
          filepath.join(destination, name),
        )
      })
    }
  }
}

fn regular_path(
  built: build.Report,
  path: String,
) -> Result(Nil, build.Failure) {
  case simplifile.is_symlink(path) {
    Ok(False) -> Ok(Nil)
    Ok(True) ->
      Error(failure(
        built,
        "export.resource_symlink",
        "shipment resource is a symbolic link",
        path
          <> ": replace the link with the resource to include in the shipment.",
      ))
    Error(error) -> Error(io_failure(built, path, error))
  }
}

fn copy_file(
  built: build.Report,
  source: String,
  destination: String,
) -> Result(Nil, build.Failure) {
  use Nil <- result.try(regular_path(built, source))
  use info <- result.try(
    simplifile.file_info(source)
    |> result.map_error(io_failure(built, source, _)),
  )
  use Nil <- result.try(case simplifile.file_info_type(info) {
    simplifile.File -> Ok(Nil)
    _ ->
      Error(failure(
        built,
        "export.resource_type",
        "unsupported shipment resource",
        source <> ": expected a regular file.",
      ))
  })
  use Nil <- result.try(
    simplifile.copy_file(source, destination)
    |> result.map_error(io_failure(built, destination, _)),
  )
  simplifile.set_permissions_octal(
    destination,
    simplifile.file_info_permissions_octal(info),
  )
  |> result.map_error(io_failure(built, destination, _))
}

fn write_launcher(
  built: build.Report,
  path: String,
  source: String,
) -> Result(Nil, build.Failure) {
  use Nil <- result.try(
    simplifile.write(path, source)
    |> result.map_error(io_failure(built, path, _)),
  )
  simplifile.set_permissions_octal(path, 0o755)
  |> result.map_error(io_failure(built, path, _))
}

fn io_failure(
  built: build.Report,
  path: String,
  error: simplifile.FileError,
) -> build.Failure {
  failure(
    built,
    "export.filesystem",
    "shipment could not be written",
    path <> ": " <> simplifile.describe_error(error),
  )
}

fn failure(
  built: build.Report,
  id: String,
  title: String,
  detail: String,
) -> build.Failure {
  build.Failure(Ok(built.checked), [
    diagnostic.error(id, title) |> diagnostic.conclusion(detail),
  ])
}

pub fn shell_script(bootstrap: String) -> String {
  "#!/bin/sh\nset -eu\nBASE=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\nCOMMAND=${1-run}\ncase \"$COMMAND\" in\n  run)\n    if [ \"$#\" -gt 0 ]; then shift; fi\n    exec erl -noshell -pa \"$BASE\"/*/ebin -s '"
  <> bootstrap
  <> "' start -extra \"$@\"\n    ;;\n  shell)\n    exec erl -pa \"$BASE\"/*/ebin\n    ;;\n  *)\n    echo 'usage: entrypoint.sh [run [arguments...] | shell]' >&2\n    exit 1\n    ;;\nesac\n"
}

pub fn powershell_script(bootstrap: String) -> String {
  "param(\n  [Parameter(Position=0)][string]$Command = 'run',\n  [Parameter(ValueFromRemainingArguments=$true)][string[]]$ProgramArguments\n)\n$Base = $PSScriptRoot\n$CodePaths = @(Get-ChildItem -LiteralPath $Base -Directory | ForEach-Object { Join-Path $_.FullName 'ebin' } | Where-Object { Test-Path -LiteralPath $_ -PathType Container })\nswitch ($Command) {\n  'run' { & erl -noshell -pa @CodePaths -s '"
  <> bootstrap
  <> "' start -extra @ProgramArguments; exit $LASTEXITCODE }\n  'shell' { & erl -pa @CodePaths; exit $LASTEXITCODE }\n  default { [Console]::Error.WriteLine('usage: entrypoint.ps1 [run [arguments...] | shell]'); exit 1 }\n}\n"
}

@external(erlang, "pooka_export_ffi", "runtime_packages")
fn runtime_packages(
  ebin: String,
  targets: List(String),
  application: String,
) -> Result(List(#(String, String)), String)

@external(erlang, "pooka_export_ffi", "temporary_directory")
fn temporary_directory(destination: String) -> Result(String, String)

@external(erlang, "pooka_export_ffi", "publish_directory")
fn publish_directory(
  staging: String,
  destination: String,
) -> Result(Nil, String)

@external(erlang, "pooka_export_ffi", "package_modules")
fn package_modules(
  ebin: String,
  application: String,
) -> Result(List(String), String)
