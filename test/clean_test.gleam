//// Sweep only the room we rented.
////
//// The clean command removes managed build output without requiring a valid
//// manifest. Argument failures must leave files alone. Symlink cases
//// distinguish removing the project entry from following it into somebody
//// else's directory.

import cli/command
import simplifile
import support

fn project(directory: String) -> Nil {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(directory <> "/src/main.pooka", "module main\n")
  support.write(directory <> "/test/main.spec.pooka", "module main_test\n")
}

// The neighbouring file is a boundary marker. A successful clean removes
// managed output without treating the project directory as disposable.
pub fn removes_only_the_project_build_directory_test() {
  use directory <- support.with_directory("clean_artifacts")
  project(directory)
  support.write(directory <> "/build/dev/erlang/main.beam", "generated")
  support.write(directory <> "/build/cache/data", "generated")
  support.write(directory <> "/pooka.lock", "locked")
  let outcome = support.cli_main(["clean"], command.plain(directory))
  assert outcome.status == 0
  assert outcome.stdout == "Cleaned build artifacts.\n"
  assert support.diagnostics(outcome.stderr) == ""
  assert simplifile.is_directory(directory <> "/build") == Ok(False)
  assert simplifile.read(directory <> "/src/main.pooka") == Ok("module main\n")
  assert simplifile.read(directory <> "/test/main.spec.pooka")
    == Ok("module main_test\n")
  assert simplifile.read(directory <> "/pooka.lock") == Ok("locked")
}

pub fn clean_is_idempotent_and_discovers_from_subdirectories_test() {
  use directory <- support.with_directory("clean_subdirectory")
  project(directory)
  support.write(directory <> "/build/artifact", "generated")
  let env = command.plain(directory <> "/src")
  let first = support.cli_main(["clean"], env)
  assert first.status == 0
  assert support.cli_main(["clean"], env) == first
}

pub fn invalid_arguments_do_not_remove_artifacts_test() {
  use directory <- support.with_directory("clean_arguments")
  project(directory)
  support.write(directory <> "/build/artifact", "generated")
  let outcome = support.cli_main(["clean", "--all"], command.plain(directory))
  assert outcome.status == 1
  assert simplifile.read(directory <> "/build/artifact") == Ok("generated")
}

pub fn clean_outside_a_project_fails_test() {
  use directory <- support.with_directory("clean_outside")
  support.write(directory <> "/build/artifact", "keep")
  let outcome = support.cli_main(["clean"], command.plain(directory))
  assert outcome.status == 1
  assert simplifile.read(directory <> "/build/artifact") == Ok("keep")
}

pub fn clean_does_not_need_a_valid_manifest_test() {
  use directory <- support.with_directory("clean_bad_manifest")
  support.write(directory <> "/pooka.toml", "not valid toml [")
  support.write(directory <> "/build/artifact", "generated")
  assert support.cli_main(["clean"], command.plain(directory)).status == 0
  assert simplifile.is_directory(directory <> "/build") == Ok(False)
}

// The build entry is ours; the directory behind its symlink may not be.
// Inspect the target after cleaning to make that distinction observable.
pub fn build_symlink_target_is_preserved_test() {
  use directory <- support.with_directory("clean_symlink")
  project(directory)
  support.write(directory <> "/elsewhere/artifact", "keep")
  let assert Ok(Nil) =
    simplifile.create_symlink(directory <> "/elsewhere", directory <> "/build")
  assert support.cli_main(["clean"], command.plain(directory)).status == 0
  assert simplifile.exists(directory <> "/build", False) == Ok(False)
  assert simplifile.read(directory <> "/elsewhere/artifact") == Ok("keep")
}

pub fn nested_symlink_target_is_preserved_test() {
  use directory <- support.with_directory("clean_nested_symlink")
  project(directory)
  support.write(directory <> "/elsewhere/artifact", "keep")
  support.write(directory <> "/build/artifact", "generated")
  let assert Ok(Nil) =
    simplifile.create_symlink(
      directory <> "/elsewhere",
      directory <> "/build/link",
    )
  assert support.cli_main(["clean"], command.plain(directory)).status == 0
  assert simplifile.is_directory(directory <> "/build") == Ok(False)
  assert simplifile.read(directory <> "/elsewhere/artifact") == Ok("keep")
}
