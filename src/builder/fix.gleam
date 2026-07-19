//// An automatic repair should carry a ruler.
////
//// Plan safe diagnostic edits, check that ranges do not overlap and apply the
//// accepted replacements. Planning and writing stay separate so a failed plan
//// cannot leave a half-repaired file.
////
//// ```text
//// diagnostic fix ranges -> validated edit plan -> updated source
//// ```

// SPDX-License-Identifier: Apache-2.0

import builder/check.{type Report}
import diagnostics/fix
import filepath
import gleam/list
import gleam/result
import project/package
import project/project_error.{type ProjectError}
import simplifile

pub type Change {
  Change(path: String, original: String, replacement: String)
}

/// Collect safe edits and reject conflicts before touching the source files.
///
/// ```text
/// overlapping replacements -> rejected plan
/// ```
pub fn plan(report: Report) -> Result(List(Change), ProjectError) {
  let diagnostics = check.diagnostics(report)
  use changes <- result.try(
    list.try_map(
      list.filter(report.files, fn(file) {
        package.owner(file.path, report.project.name) == report.project.name
      }),
      fn(file) {
        let edits = fix.automatic(diagnostics, file.path)
        use replacement <- result.try(
          fix.apply(file.source, edits)
          |> result.map_error(fn(error) {
            project_error.CannotApplyFixes(file.path, case error {
              fix.InvalidSpan -> "a fix has an invalid UTF-8 source span"
              fix.ConflictingEdits -> "automatic fixes overlap or disagree"
            })
          }),
        )
        Ok(Change(file.path, file.source, replacement))
      },
    ),
  )
  Ok(list.filter(changes, fn(change) { change.original != change.replacement }))
}

/// Apply an already validated fix plan to its intended files.
///
/// ```sh
/// pooka check --fix
/// ```
pub fn apply(report: Report) -> Result(Report, ProjectError) {
  use changes <- result.try(plan(report))
  use Nil <- result.try(list.try_each(changes, unchanged(report, _)))
  use Nil <- result.try(
    list.try_each(changes, fn(change) {
      use Nil <- result.try(unchanged(report, change))
      let absolute = filepath.join(report.project.root, change.path)
      simplifile.write(absolute, change.replacement)
      |> result.map_error(project_error.FileSystemFailed(
        project_error.WritingFile,
        absolute,
        _,
      ))
    }),
  )
  check.check_project(report.project.root)
}

fn unchanged(report: Report, change: Change) -> Result(Nil, ProjectError) {
  let absolute = filepath.join(report.project.root, change.path)
  use current <- result.try(
    simplifile.read(absolute)
    |> result.map_error(project_error.FileSystemFailed(
      project_error.ReadingFile,
      absolute,
      _,
    )),
  )
  case current == change.original {
    True -> Ok(Nil)
    False ->
      Error(project_error.CannotApplyFixes(
        change.path,
        "the source changed after it was checked",
      ))
  }
}
