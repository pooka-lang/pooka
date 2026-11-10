//// Edit one entry without rearranging the whole notebook.
////
//// Dependency commands must select one source and scope, preserve surrounding
//// TOML and resolve the edited graph. A failed edit must leave the previous
//// manifest and lockfile together, rather than publishing half a change.

import cli/cli
import cli/command
import cli/commands/add
import gleam/option.{None, Some}
import gleam/string
import pooka
import project/dependency as d
import project/edit
import simplifile
import support

pub fn dependency_options_select_one_source_and_scope_test() {
  assert add.parse(["parser@1.2.3", "--dev"])
    == Ok(edit.Add(d.Hex("parser", "~> 1.2.3", False), True))
  assert add.parse([
      "parser",
      "--git",
      "https://example.org/parser.git",
      "--rev",
      "abc1234",
    ])
    == Ok(edit.Add(
      d.Git("parser", "https://example.org/parser.git", "rev:abc1234"),
      False,
    ))
  assert add.parse(["parser", "--path", "../parser"])
    == Ok(edit.Add(d.Local("parser", "../parser"), False))
  assert case add.parse(["parser", "--git", "x", "--path", "y"]) {
    Error(_) -> True
    _ -> False
  }
}

// Treat the manifest as the author's notebook. Editing one dependency must
// preserve comments, unrelated tool tables and the remaining multiline
// entries.
pub fn editing_preserves_comments_other_tables_and_multiline_dependencies_test() {
  let original =
    "# Keep this comment\nname = \"app\"\nversion = \"0.1.0\"\n[dependencies]\n# Keep this dependency note\nold = {\n path = \"../old\"\n}\nother = { path = \"../other\" }\n[links]\nrepository = \"https://example.org/app\"\n"
  let removed = edit.rewrite(original, "old", None)
  assert !string.contains(removed, "../old")
  assert string.contains(removed, "# Keep this comment")
  assert string.contains(removed, "# Keep this dependency note")
  assert string.contains(removed, "other = { path = \"../other\" }")
  assert string.contains(
    removed,
    "[links]\nrepository = \"https://example.org/app\"",
  )
  let moved =
    edit.rewrite(original, "old", Some(#(d.Local("old", "../new"), True)))
  assert string.contains(
    moved,
    "[dev-dependencies]\nold = { path = \"../new\" }",
  )
  assert !string.contains(moved, "../old")
}

// The manifest and lockfile form one published result. A resolution failure
// must restore both, not leave a new declaration paired with an old graph.
pub fn local_add_remove_are_resolved_and_failed_changes_preserve_manifest_and_lock_test() {
  use dir <- support.with_directory("dependency_edit_transaction")
  support.write(
    dir <> "/app/pooka.toml",
    "# hello\nname = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(dir <> "/app/src/main.pooka", "module main\nmain() { Nil }\n")
  support.write(
    dir <> "/library/pooka.toml",
    "name = \"library\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    dir <> "/library/src/library.pooka",
    "module library\nanswer() { 42 }\n",
  )
  let env = command.plain(dir <> "/app")
  let added =
    cli.main(
      ["add", "library", "--path", "../library", "--dev"],
      pooka.version,
      env,
    )
  assert added.status == 0
  let assert Ok(before) = simplifile.read(dir <> "/app/pooka.toml")
  let assert Ok(lock) = simplifile.read(dir <> "/app/pooka.lock")
  assert string.contains(before, "# hello")
  assert string.contains(before, "[dev-dependencies]")
  assert cli.main(
      ["add", "missing", "--path", "../missing"],
      pooka.version,
      env,
    ).status
    == 1
  assert simplifile.read(dir <> "/app/pooka.toml") == Ok(before)
  assert simplifile.read(dir <> "/app/pooka.lock") == Ok(lock)
  assert cli.main(["remove", "library"], pooka.version, env).status == 0
  let assert Ok(after) = simplifile.read(dir <> "/app/pooka.toml")
  assert !string.contains(after, "../library")
  assert cli.main(["remove", "library"], pooka.version, env).status == 1
}

// Use an absolute sibling path: on Windows this includes a drive and must not
// be appended to the application's root. Spaces also survive the TOML edit.
pub fn adding_absolute_local_dependency_preserves_its_root_test() {
  use root <- support.with_directory("absolute_dependency")
  let library = root <> "/library with spaces"
  support.write(
    root <> "/app/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    library <> "/pooka.toml",
    "name = \"library\"\nversion = \"0.1.0\"\n",
  )
  let added =
    cli.main(
      ["add", "library", "--path", library],
      pooka.version,
      command.plain(root <> "/app"),
    )
  assert added.status == 0
  let assert Ok(config) = simplifile.read(root <> "/app/pooka.toml")
  assert string.contains(config, "library with spaces")
}
