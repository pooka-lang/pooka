//// Check the bridge before inviting native code across it.
////
//// Validate declared native components, prepare their generated modules and
//// locate the resulting shared libraries. Configuration errors belong to the
//// component's manifest entry.
////
//// ```text
//// [native.fast] -> component command -> shared library
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/compiler
import compiler/parser/ast
import diagnostics/diagnostic.{type Diagnostic}
import filepath
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import project/native_component.{type NativeComponent}
import project/project.{type Project}
import simplifile
import utilities/location

pub fn check(
  groups: List(#(Project, List(compiler.Checked))),
) -> List(Diagnostic) {
  let unknown =
    list.flat_map(groups, fn(group) {
      let #(owner, files) = group
      let names = list.map(owner.natives, fn(component) { component.name })
      list.flat_map(files, fn(file) {
        declarations(file)
        |> list.filter(fn(native) {
          native_component.valid_name(native.module)
          && !list.contains(names, native.module)
        })
        |> list.map(fn(native) {
          diagnostic.error(
            "native.unknown_component",
            "unknown native component",
          )
          |> diagnostic.primary(
            location.new(file.path, native.module_span),
            "`" <> native.module <> "` is not a component of this package",
          )
          |> diagnostic.conclusion(
            "Native components are declared in the package's pooka.toml, with the command that builds them.",
          )
          |> diagnostic.help(
            "Add a `[native."
            <> native.module
            <> "]` table with a `build` command, and put the component in `native/"
            <> native.module
            <> "`.",
          )
        })
      })
    })
  let declared =
    list.flat_map(groups, fn(group) {
      list.map({ group.0 }.natives, fn(component) { #(component.name, group.0) })
    })
  let duplicates =
    declared
    |> list.map(fn(entry) { entry.0 })
    |> list.unique
    |> list.filter_map(fn(name) {
      case list.filter(declared, fn(entry) { entry.0 == name }) {
        [_, _, ..] as owners ->
          Ok(
            diagnostic.error(
              "native.duplicate_component",
              "native component declared by several packages",
            )
            |> diagnostic.conclusion(
              "The native component `"
              <> name
              <> "` is declared by "
              <> string.join(
                list.map(owners, fn(entry) { "`" <> { entry.1 }.name <> "`" }),
                " and ",
              )
              <> ". Its loader module, `"
              <> native_component.module(name)
              <> "`, must be unique in an application.",
            )
            |> diagnostic.help("Rename the component in one of the packages."),
          )
        _ -> Error(Nil)
      }
    })
  let missing =
    list.flat_map(groups, fn(group) {
      let owner = group.0
      list.filter_map(owner.natives, fn(component) {
        let directory = directory(owner, component)
        case simplifile.is_directory(directory) {
          Ok(True) -> Error(Nil)
          _ ->
            Ok(
              diagnostic.error(
                "native.missing_component",
                "missing native component",
              )
              |> diagnostic.conclusion(
                "The native component `"
                <> component.name
                <> "` of `"
                <> owner.name
                <> "` has no directory at `"
                <> directory
                <> "`.",
              )
              |> diagnostic.help(
                "Native components live in `native/<name>` beside `src/`.",
              ),
            )
        }
      })
    })
  list.flatten([unknown, duplicates, missing])
}

fn declarations(file: compiler.Checked) -> List(ast.External) {
  list.filter_map(file.parsed.module.declarations, fn(declaration) {
    case declaration {
      ast.ExternalDeclaration(value) if value.language == ast.Native -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

pub fn directory(owner: Project, component: NativeComponent) -> String {
  filepath.join(owner.root, filepath.join("native", component.name))
}

pub type Prepared {
  Prepared(loaders: List(#(String, BitArray)), rebuilt: List(String))
}

pub fn prepare(
  owner: Project,
  files: List(compiler.Checked),
  package: String,
  artifacts: String,
  application: String,
  mode: String,
) -> Result(Prepared, Diagnostic) {
  let functions = declared_functions(files)
  remove_stale(owner, package)
  list.try_fold(owner.natives, Prepared([], []), fn(prepared, component) {
    use rebuilt <- result.try(build(owner, component, package, artifacts, mode))
    let module = native_component.module(component.name)
    use beam <- result.try(
      loader(
        module,
        application,
        component.name,
        dict.get(functions, component.name) |> result.unwrap([]),
      )
      |> result.map_error(fn(detail) {
        diagnostic.error("native.loader", "cannot generate native loader")
        |> diagnostic.conclusion(
          "The loader module `" <> module <> "` did not compile: " <> detail,
        )
      }),
    )
    Ok(
      Prepared(
        loaders: list.append(prepared.loaders, [#(module, beam)]),
        rebuilt: case rebuilt {
          True -> list.append(prepared.rebuilt, [component.name])
          False -> prepared.rebuilt
        },
      ),
    )
  })
}

fn declared_functions(
  files: List(compiler.Checked),
) -> Dict(String, List(#(String, Int))) {
  files
  |> list.flat_map(declarations)
  |> list.fold(dict.new(), fn(found, native) {
    let functions =
      list.map(native.functions, fn(function) {
        #(function.name.name, list.length(function.parameters))
      })
    dict.upsert(found, native.module, fn(existing) {
      case existing {
        Some(existing) -> list.unique(list.append(existing, functions))
        None -> functions
      }
    })
  })
}

fn remove_stale(owner: Project, package: String) -> Nil {
  let directory = filepath.join(package, "native")
  let current =
    list.map(owner.natives, fn(component) { component.name <> ".so" })
  case simplifile.read_directory(directory) {
    Ok(names) ->
      list.each(names, fn(name) {
        case list.contains(current, name) {
          True -> Nil
          False -> {
            let _ = simplifile.delete(filepath.join(directory, name))
            Nil
          }
        }
      })
    Error(_) -> Nil
  }
}

pub fn library(package: String, component: String) -> String {
  filepath.join(package, filepath.join("native", component <> ".so"))
}

fn build(
  owner: Project,
  component: NativeComponent,
  package: String,
  artifacts: String,
  mode: String,
) -> Result(Bool, Diagnostic) {
  let source = directory(owner, component)
  let target = library(package, component.name)
  let key_path =
    filepath.join(artifacts, filepath.join("native", component.name <> ".key"))
  let key =
    component_key(
      source,
      component.build,
      option.unwrap(component.artifact, ""),
      mode,
    )
  let fresh =
    simplifile.read_bits(key_path) == Ok(key)
    && simplifile.is_file(target) == Ok(True)
  case fresh {
    True -> Ok(False)
    False -> {
      let staging =
        filepath.join(artifacts, filepath.join("native", component.name))
      let output = filepath.join(staging, component.name <> ".so")
      let _ = simplifile.delete(staging)
      use Nil <- result.try(directory_for(staging, component))
      use output_text <- result.try(
        run_build(component.build, source, [
          #("POOKA_NATIVE_COMPONENT", component.name),
          #("POOKA_NATIVE_MODULE", native_component.module(component.name)),
          #("POOKA_NATIVE_OUTPUT", output),
          #("POOKA_ERTS_INCLUDE", erts_include()),
          #("POOKA_BUILD_MODE", mode),
        ])
        |> result.map_error(fn(printed) {
          diagnostic.error("native.build_failed", "native build failed")
          |> diagnostic.conclusion(
            "The build command of native component `"
            <> component.name
            <> "` failed. It ran in `"
            <> source
            <> "`:\n\n    "
            <> component.build
            <> "\n\n"
            <> tail(printed),
          )
        }),
      )
      let produced = case component.artifact {
        Some(path) -> filepath.join(source, path)
        None -> output
      }
      use Nil <- result.try(validate(component, produced, output_text))
      use Nil <- result.try(directory_for(
        filepath.join(package, "native"),
        component,
      ))
      use Nil <- result.try(
        simplifile.copy_file(produced, target)
        |> result.map_error(fn(error) {
          io_failure(component, target, simplifile.describe_error(error))
        }),
      )
      let _ = simplifile.delete(staging)

      let key =
        component_key(
          source,
          component.build,
          option.unwrap(component.artifact, ""),
          mode,
        )
      use Nil <- result.try(
        simplifile.write_bits(key_path, key)
        |> result.map_error(fn(error) {
          io_failure(component, key_path, simplifile.describe_error(error))
        }),
      )
      Ok(True)
    }
  }
}

fn validate(
  component: NativeComponent,
  produced: String,
  printed: String,
) -> Result(Nil, Diagnostic) {
  case simplifile.is_file(produced), shared_library(produced) {
    Ok(True), True -> Ok(Nil)
    Ok(True), False ->
      Error(
        diagnostic.error(
          "native.invalid_artifact",
          "native artifact is not a shared library",
        )
        |> diagnostic.conclusion(
          "Native component `"
          <> component.name
          <> "` produced `"
          <> produced
          <> "`, which is not a shared library. A NIF is loaded with `erlang:load_nif/2`, which needs a dynamic library such as a `.so`, `.dylib` or `.dll`.",
        ),
      )
    _, _ ->
      Error(
        diagnostic.error("native.missing_artifact", "missing native artifact")
        |> diagnostic.conclusion(
          "The build of native component `"
          <> component.name
          <> "` succeeded but did not produce `"
          <> produced
          <> "`."
          <> case printed {
            "" -> ""
            _ -> "\n\n" <> tail(printed)
          },
        )
        |> diagnostic.help(case component.artifact {
          Some(_) -> "Check the `artifact` path, relative to the component."
          None ->
            "Write the library to `$POOKA_NATIVE_OUTPUT`, or set `artifact` to where the build leaves it."
        }),
      )
  }
}

fn directory_for(
  path: String,
  component: NativeComponent,
) -> Result(Nil, Diagnostic) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(error) {
    io_failure(component, path, simplifile.describe_error(error))
  })
}

fn io_failure(
  component: NativeComponent,
  path: String,
  detail: String,
) -> Diagnostic {
  diagnostic.error("native.build_failed", "native build failed")
  |> diagnostic.conclusion(
    "Native component `" <> component.name <> "`: " <> path <> ": " <> detail,
  )
}

fn tail(printed: String) -> String {
  let lines = string.split(string.trim_end(printed), "\n")
  let count = list.length(lines)
  case count > 40 {
    True ->
      "… "
      <> string.inspect(count - 40)
      <> " earlier lines omitted\n"
      <> string.join(list.drop(lines, count - 40), "\n")
    False -> string.join(lines, "\n")
  }
}

@external(erlang, "pooka_nif_ffi", "run_build")
fn run_build(
  command: String,
  directory: String,
  environment: List(#(String, String)),
) -> Result(String, String)

@external(erlang, "pooka_nif_ffi", "erts_include")
fn erts_include() -> String

@external(erlang, "pooka_nif_ffi", "shared_library")
fn shared_library(path: String) -> Bool

@external(erlang, "pooka_nif_ffi", "component_key")
fn component_key(
  directory: String,
  command: String,
  artifact: String,
  mode: String,
) -> BitArray

@external(erlang, "pooka_nif_ffi", "loader")
fn loader(
  module: String,
  application: String,
  component: String,
  functions: List(#(String, Int)),
) -> Result(BitArray, String)
