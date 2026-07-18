//// Introduce the foreign compiler at the front desk.
////
//// Discover supported foreign source files and invoke the corresponding
//// toolchain. Translate tool failures into Pooka diagnostics instead of
//// pretending they were language type errors.
////
//// ```text
//// ffi/helper.erl -> Erlang compiler -> helper.beam
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/codegen/beam
import compiler/foreign_language
import compiler/parser/ast.{type ForeignLanguage}
import diagnostics/diagnostic.{type Diagnostic}
import filepath
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type Source {
  Source(path: String, relative: String, language: ForeignLanguage)
}

pub type Command {
  Command(program: String, arguments: List(String), beams: String)
}

pub type ForeignError {

  MissingCompiler(language: ForeignLanguage, program: String)

  CompilationFailed(source: String, output: String)

  WorkingDirectoryFailed(path: String, reason: simplifile.FileError)
}

pub fn discover(root: String) -> List(Source) {
  let directory = filepath.join(root, "ffi")
  case simplifile.is_directory(directory) {
    Ok(True) ->
      simplifile.get_files(directory)
      |> result.unwrap([])
      |> list.sort(string.compare)
      |> list.filter_map(fn(path) {
        let relative = string.drop_start(path, string.length(directory) + 1)
        case
          string.starts_with(relative, ".") || string.contains(relative, "/.")
        {
          True -> Error(Nil)
          False ->
            foreign_language.of_file(relative)
            |> result.map(Source(path, relative, _))
        }
      })
    Ok(False) | Error(_) -> []
  }
}

pub fn compile(
  root: String,
  work: String,
) -> Result(List(#(String, BitArray)), ForeignError) {
  let sources = discover(root)
  foreign_language.all
  |> list.try_map(fn(language) {
    let files = list.filter(sources, fn(source) { source.language == language })
    case files {
      [] -> Ok([])
      [_, ..] -> compile_language(language, files, work)
    }
  })
  |> result.map(list.flatten)
}

fn compile_language(
  language: ForeignLanguage,
  sources: List(Source),
  work: String,
) -> Result(List(#(String, BitArray)), ForeignError) {
  case command(language, sources, work) {
    Error(Nil) ->
      list.try_map(sources, fn(source) {
        beam.compile_foreign_erlang(source.path)
        |> result.map_error(CompilationFailed("ffi/" <> source.relative, _))
      })
    Ok(command) -> {
      use Nil <- result.try(prepare(language, sources, work, command))
      beam.run_foreign_compiler(
        command.program,
        command.arguments,
        command.beams,
      )
      |> result.map_error(fn(error) {
        case error {
          beam.MissingCompiler -> MissingCompiler(language, command.program)
          beam.CompilerFailed(output) ->
            CompilationFailed(
              "ffi/*"
                <> string.join(foreign_language.extensions(language), ", ffi/*"),
              output,
            )
        }
      })
    }
  }
}

pub fn command(
  language: ForeignLanguage,
  sources: List(Source),
  work: String,
) -> Result(Command, Nil) {
  let paths = list.map(sources, fn(source) { source.path })
  case language {
    ast.Elixir -> {
      let out = filepath.join(work, "elixir")
      Ok(Command(
        "elixirc",
        ["--ignore-module-conflict", "-o", out, ..paths],
        out,
      ))
    }
    ast.Lfe -> {
      let out = filepath.join(work, "lfe")
      Ok(Command("lfec", ["-o", out, ..paths], out))
    }
    ast.Gleam -> {
      let gleam = filepath.join(work, "gleam")
      Ok(Command(
        "gleam",
        [
          "compile-package",
          "--target",
          "erlang",
          "--package",
          filepath.join(gleam, "package"),
          "--out",
          filepath.join(gleam, "out"),
          "--lib",
          filepath.join(gleam, "lib"),
        ],
        filepath.join(gleam, "out/ebin"),
      ))
    }

    ast.Erlang | ast.Native -> Error(Nil)
  }
}

fn prepare(
  language: ForeignLanguage,
  sources: List(Source),
  work: String,
  command: Command,
) -> Result(Nil, ForeignError) {
  let fresh = fn(path) {
    let _ = simplifile.delete(path)
    simplifile.create_directory_all(path)
    |> result.map_error(WorkingDirectoryFailed(path, _))
  }
  case language {
    ast.Gleam -> {
      let gleam = filepath.join(work, "gleam")
      let package = filepath.join(gleam, "package")
      use Nil <- result.try(fresh(gleam))
      use Nil <- result.try(fresh(filepath.join(package, "src")))
      use Nil <- result.try(fresh(filepath.join(gleam, "lib")))
      let manifest = filepath.join(package, "gleam.toml")
      use Nil <- result.try(
        simplifile.write(
          manifest,
          "name = \"pooka_ffi\"\nversion = \"1.0.0\"\n",
        )
        |> result.map_error(WorkingDirectoryFailed(manifest, _)),
      )
      list.try_each(sources, fn(source) {
        let target = filepath.join(package, "src/" <> source.relative)
        use Nil <- result.try(
          simplifile.create_directory_all(filepath.directory_name(target))
          |> result.map_error(WorkingDirectoryFailed(target, _)),
        )
        simplifile.copy_file(source.path, target)
        |> result.map_error(WorkingDirectoryFailed(target, _))
      })
    }
    ast.Elixir | ast.Lfe | ast.Erlang | ast.Native -> fresh(command.beams)
  }
}

pub fn to_diagnostic(error: ForeignError, root: String) -> Diagnostic {
  let relative = string.replace(_, root <> "/", "")
  case error {
    MissingCompiler(language:, program:) ->
      diagnostic.error(
        "build.missing_foreign_compiler",
        "foreign compiler not found",
      )
      |> diagnostic.conclusion(
        "The project has "
        <> foreign_language.name(language)
        <> " source in `ffi/`, but `"
        <> program
        <> "` was not found on PATH.",
      )
      |> diagnostic.help(
        "Install the "
        <> foreign_language.name(language)
        <> " compiler, or remove its files from `ffi/`.",
      )
    CompilationFailed(source:, output:) ->
      diagnostic.error(
        "build.foreign_compilation",
        "foreign source could not be compiled",
      )
      |> diagnostic.conclusion(
        "`"
        <> source
        <> "` failed to compile:\n\n"
        <> string.trim(relative(output)),
      )
    WorkingDirectoryFailed(path:, reason:) ->
      diagnostic.error("build.failed", "build failed")
      |> diagnostic.conclusion(
        relative(path) <> ": " <> simplifile.describe_error(reason),
      )
  }
}
