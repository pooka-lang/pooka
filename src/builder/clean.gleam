//// Put away the workshop's temporary furniture.
////
//// Remove generated build artifacts through the project layout. Source files and
//// the package manifest remain the owner's belongings.
////
//// ```text
//// pooka clean -> remove generated build output
//// ```

// SPDX-License-Identifier: Apache-2.0

import filepath
import gleam/result
import project/project
import project/project_error.{type ProjectError}
import simplifile

pub fn clean_project(directory: String) -> Result(Nil, ProjectError) {
  use root <- result.try(project.find_root(directory))
  let build = filepath.join(root, "build")

  let deleted = case simplifile.is_symlink(build) {
    Ok(True) -> simplifile.delete_file(build)
    Ok(False) -> simplifile.delete(build)
    Error(error) -> Error(error)
  }
  case deleted {
    Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
    Error(reason) ->
      Error(project_error.FileSystemFailed(
        project_error.RemovingBuildArtifacts,
        build,
        reason,
      ))
  }
}
