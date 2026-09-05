//// Let a dependency leave without disturbing the furniture.
////
//// Edit the requested manifest dependency and update resolution through the
//// project layer. Unrelated TOML tables are preserved.
////
//// ```sh
//// pooka remove helper
//// ```

// SPDX-License-Identifier: Apache-2.0

import cli/command.{type Environment, type Outcome, Info, Outcome}
import cli/commands/new
import project/edit
import project/project_error
import tools/logger

pub const info = Info("remove", "<package>", "Remove a dependency")

pub fn run(args: List(String), env: Environment) -> Outcome {
  case args {
    [name] ->
      case edit.apply(env.working_directory, edit.Remove(name)) {
        Ok(name) -> Outcome("", logger.activity("Removed", name, env.stderr), 0)
        Error(error) -> new.failure(error, env)
      }
    _ -> new.failure(project_error.UnexpectedArguments("remove", args), env)
  }
}
