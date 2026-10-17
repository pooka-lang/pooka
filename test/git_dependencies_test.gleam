//// A branch can move while a lockfile keeps its place.
////
//// Create local Git repositories to test branch, tag and revision selection
//// without a remote service. Cached pins must work offline and reject modified
//// checkouts. Failed updates preserve earlier locks, and repository identities
//// must not retain embedded credentials.

import cli/command
import gleam/string
import project/dependency as d
import simplifile
import support

@external(erlang, "shipment_test_ffi", "git")
fn git(directory: String, args: List(String)) -> #(Int, String)

fn command(directory: String, args: List(String)) {
  let assert #(0, _) = git(directory, args)
}

fn commit(repository: String, value: Int) {
  support.write(
    repository <> "/pooka.toml",
    "name = \"library\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    repository <> "/src/library.pooka",
    "module library\nanswer() { " <> int_string(value) <> " }\n",
  )
  command(repository, ["add", "."])
  command(repository, [
    "-c",
    "user.name=Pooka Test",
    "-c",
    "user.email=tests@example.invalid",
    "commit",
    "-qm",
    "test change",
  ])
}

import gleam/int

fn int_string(value: Int) {
  int.to_string(value)
}

fn setup(directory: String, reference: String) {
  let repository = directory <> "/repository"
  let assert Ok(Nil) = simplifile.create_directory_all(repository)
  command(repository, ["init", "-q", "-b", "main"])
  commit(repository, 41)
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n[dependencies]\nlibrary = { git = \"../repository\""
      <> reference
      <> " }\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nimport library\nmain() { echo library.answer() }\n",
  )
}

// Move the branch after resolving it. An ordinary build should retain its
// locked commit; only an explicit update follows the new branch tip.
pub fn branches_are_locked_until_explicit_update_test() {
  use directory <- support.with_directory("git_locked_branch")
  setup(directory, ", branch = \"main\"")
  let env = command.plain(directory <> "/app")
  let initial = support.cli_main(["run"], env)
  assert initial.stdout == "41\n"
  assert string.contains(initial.stderr, "Compiling library\n")
  assert string.contains(initial.stderr, "Compiling app\n")
  let assert Ok(before) = simplifile.read(directory <> "/app/pooka.lock")
  assert string.contains(before, "revision = ")
  assert !string.contains(before, directory)
  commit(directory <> "/repository", 42)

  let assert Ok(Nil) = simplifile.delete(directory <> "/app/build/packages")
  assert support.cli_main(["run"], env).stdout == "41\n"
  assert simplifile.read(directory <> "/app/pooka.lock") == Ok(before)
  assert support.cli_main(["deps", "update"], env).status == 0
  assert support.cli_main(["run"], env).stdout == "42\n"
  let assert Ok(after) = simplifile.read(directory <> "/app/pooka.lock")
  assert after != before
}

pub fn cached_pins_work_without_the_repository_and_after_production_export_test() {
  use directory <- support.with_directory("git_offline_pin")
  setup(directory, "")
  let env = command.plain(directory <> "/app")
  assert support.cli_main(["run"], env).stdout == "41\n"
  let assert Ok(Nil) =
    simplifile.rename(directory <> "/repository", directory <> "/offline")
  assert support.cli_main(["run"], env).stdout == "41\n"
  assert support.cli_main(["export", "escript"], env).status == 0
  assert support.cli_main(["run"], env).stdout == "41\n"
}

pub fn tags_and_explicit_commit_references_select_the_requested_commit_test() {
  use directory <- support.with_directory("git_tag_pin")
  setup(directory, ", tag = \"stable\"")
  command(directory <> "/repository", ["tag", "stable"])
  let assert #(0, revision) =
    git(directory <> "/repository", ["rev-parse", "HEAD"])
  commit(directory <> "/repository", 42)
  let env = command.plain(directory <> "/app")
  assert support.cli_main(["run"], env).stdout == "41\n"
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n[dependencies]\nlibrary = { git = \"../repository\", rev = \""
      <> string.trim(revision)
      <> "\" }\n",
  )
  assert support.cli_main(["run"], env).stdout == "41\n"
}

pub fn production_exports_preserve_inactive_dev_revision_pins_test() {
  use directory <- support.with_directory("git_dev_pin")
  setup(directory, "")
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n[dev-dependencies]\nlibrary = { git = \"../repository\" }\n",
  )
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nmain() { Nil }\n",
  )
  support.write(
    directory <> "/app/test/main.spec.pooka",
    "module main_test\nimport library\ntest \"locked dev package\" { assert library.answer() == 41 }\n",
  )
  let env = command.plain(directory <> "/app")
  assert support.cli_main(["deps", "download"], env).status == 0
  let assert Ok(before) = simplifile.read(directory <> "/app/pooka.lock")
  assert support.cli_main(["export", "escript"], env).status == 0
  assert simplifile.read(directory <> "/app/pooka.lock") == Ok(before)
  commit(directory <> "/repository", 42)
  assert support.cli_main(["test"], env).status == 0
}

pub fn git_gleam_packages_build_without_mutating_the_checkout_test() {
  use directory <- support.with_directory("git_native_gleam")
  setup(directory, "")
  let repo = directory <> "/repository"
  let assert Ok(Nil) = simplifile.delete_file(repo <> "/pooka.toml")
  support.write(
    repo <> "/gleam.toml",
    "name = \"library\"\nversion = \"0.1.0\"\n",
  )
  support.write(repo <> "/src/library.gleam", "pub fn answer() { 42 }\n")
  command(repo, ["add", "."])
  command(repo, [
    "-c",
    "user.name=Pooka Test",
    "-c",
    "user.email=tests@example.invalid",
    "commit",
    "-qm",
    "native package",
  ])
  support.write(
    directory <> "/app/src/main.pooka",
    "module main\nexternal Library from erlang \"library\" { answer() -> Int }\nmain() { echo Library.answer() }\n",
  )
  let env = command.plain(directory <> "/app")
  assert support.cli_main(["run"], env).stdout == "42\n"
  assert support.cli_main(["run"], env).stdout == "42\n"
}

// A missing branch should fail before publishing replacement pins. Keep the
// previous successful lockfile byte-for-byte.
pub fn failed_git_updates_preserve_the_previous_lockfile_test() {
  use directory <- support.with_directory("git_failed_update")
  setup(directory, "")
  let env = command.plain(directory <> "/app")
  assert support.cli_main(["deps", "download"], env).status == 0
  let assert Ok(before) = simplifile.read(directory <> "/app/pooka.lock")
  support.write(
    directory <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n[dependencies]\nlibrary = { git = \"../repository\", branch = \"missing-branch\" }\n",
  )
  assert support.cli_main(["deps", "update"], env).status == 1
  assert simplifile.read(directory <> "/app/pooka.lock") == Ok(before)
}

// Credentials are transport details rather than package identity. Removing
// them from the recorded identity prevents a lockfile from becoming a secret
// carrier.
pub fn repository_credentials_are_not_written_to_lock_identities_test() {
  assert d.repository_identity(
      "https://user:secret@example.invalid/library.git",
    )
    == "https://example.invalid/library.git"
  assert d.repository_identity("ssh://git@example.invalid/library.git")
    == "ssh://example.invalid/library.git"
}

pub fn modified_git_checkouts_are_rejected_test() {
  use directory <- support.with_directory("git_dirty_cache")
  setup(directory, "")
  let env = command.plain(directory <> "/app")
  assert support.cli_main(["run"], env).stdout == "41\n"
  let assert Ok(names) =
    simplifile.read_directory(directory <> "/app/build/packages")
  let assert [cache] = names
  support.write(
    directory <> "/app/build/packages/" <> cache <> "/src/extra.pooka",
    "module extra\n",
  )
  let failed = support.cli_main(["deps", "download"], env)
  assert failed.status == 1
  assert string.contains(failed.stderr, "modified")
}
