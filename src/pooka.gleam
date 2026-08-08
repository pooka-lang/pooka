//// A small command line for creating, checking and running local projects.
//// More tools can join this dispatcher as their modules become available.

// SPDX-License-Identifier: Apache-2.0

import argv
import cli/command
import cli/commands/add
import cli/commands/build
import cli/commands/check
import cli/commands/new
import cli/commands/run
import cli/commands/tests
import gleam/io
import utilities/process

pub const version = "0.1.0"

pub fn main() -> Nil {
  let assert Ok(environment) = command.from_system()
  let outcome = case argv.load().arguments {
    ["new", ..args] -> new.run(args, environment)
    ["add", ..args] -> add.run(args, environment)
    ["check", ..args] -> check.run(args, environment)
    ["build", ..args] -> build.run(args, environment)
    ["run", ..args] -> run.run(args, environment)
    ["test", ..args] -> tests.run(args, environment)
    ["--version"] -> command.success("pooka " <> version <> "\n")
    _ -> command.success("Pooka: new, add, check, build, run, test\n")
  }
  io.print(outcome.stdout)
  io.print_error(outcome.stderr)
  process.exit(outcome.status)
}
