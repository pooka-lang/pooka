//// Carry the command's surroundings in one small satchel.
////
//// Describe working directory, output styles, clock and standard-stream behavior
//// explicitly. Plain environments let tests inspect output without inheriting the
//// real terminal.
////
//// ```text
//// command.plain(directory) -> deterministic, captured command output
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/result
import project/project_error.{type ProjectError}
import simplifile
import utilities/colour.{type Output}
import utilities/timer

pub type Environment {
  Environment(
    working_directory: String,
    stdout: Output,
    stderr: Output,
    clock: fn() -> Int,
    inherit_stdio: Bool,
  )
}

/// Discover the real working directory and terminal capabilities for an
/// executable invocation.
///
/// ```text
/// real CLI -> inherited program streams and detected output styles
/// ```
pub fn from_system() -> Result(Environment, ProjectError) {
  use working_directory <- result.try(
    simplifile.current_directory()
    |> result.map_error(project_error.FileSystemFailed(
      project_error.FindingWorkingDirectory,
      ".",
      _,
    )),
  )
  Ok(Environment(
    working_directory:,
    stdout: colour.detect(colour.Stdout),
    stderr: colour.detect(colour.Stderr),
    clock: timer.now,
    inherit_stdio: True,
  ))
}

/// Create a captured environment with a deterministic clock for command tests. It
/// does not inherit the caller's terminal descriptors.
///
/// ```text
/// plain(directory) -> no colour and inspectable output
/// ```
pub fn plain(working_directory: String) -> Environment {
  Environment(
    working_directory:,
    stdout: colour.PlainText,
    stderr: colour.PlainText,
    clock: fn() { 0 },
    inherit_stdio: False,
  )
}

pub type Outcome {
  Outcome(stdout: String, stderr: String, status: Int)
}

pub fn success(stdout: String) -> Outcome {
  Outcome(stdout:, stderr: "", status: 0)
}

pub fn failure(stderr: String) -> Outcome {
  Outcome(stdout: "", stderr:, status: 1)
}

pub type Info {
  Info(name: String, arguments: String, summary: String)
}
