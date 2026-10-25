//// A release should remember how to start after moving house.
////
//// Boot exported OTP releases after relocating them and removing the original
//// project. Production modules and resources must remain, source artifacts
//// must not, and an optional bundled ERTS must work. Failed re-exports leave
//// the previous boot files intact.

import builder/release
import gleam/list
import gleam/string
import simplifile
import support

@external(erlang, "shipment_test_ffi", "run")
fn execute(
  script: String,
  arguments: List(String),
  directory: String,
) -> #(Int, String)

// Launching after deletion of the original project exposes hidden path
// dependencies. Inspect the moved tree too, so a runnable export cannot
// smuggle development sources along.
pub fn release_boots_after_relocation_and_excludes_build_sources_test() {
  use dir <- support.with_directory("release_relocation")
  let original = dir <> "/original"
  support.write(
    original <> "/pooka.toml",
    "name = \"app\"\nversion = \"1.2.3\"\n",
  )
  support.write(
    original <> "/src/main.pooka",
    "module main\nexternal VM from erlang \"erlang\" { halt() -> Nil }\nmain() { echo 42\nVM.halt() }\n",
  )
  support.write(original <> "/test/bad.spec.pooka", "broken")
  support.write(original <> "/priv/message.txt", "resource")
  let assert Ok(report) = release.export(original, False)
  let moved = dir <> "/moved release Δ"
  let assert Ok(Nil) = simplifile.copy_directory(report.directory, moved)
  let assert Ok(Nil) = simplifile.delete(original)
  let #(code, output) = execute(moved <> "/bin/app", ["run"], dir)
  assert code == 0
  assert string.contains(output, "42")
  assert simplifile.read(moved <> "/lib/app-1.2.3/priv/message.txt")
    == Ok("resource")
  assert simplifile.is_file(moved <> "/releases/1.2.3/app.boot") == Ok(True)
  let assert Ok(files) = simplifile.get_files(moved)
  assert list.all(files, fn(p) {
    !string.ends_with(p, ".erl")
    && !string.ends_with(p, ".abstr")
    && !string.ends_with(p, ".pooka")
  })
}

pub fn release_can_bundle_erts_and_preserves_previous_export_on_failure_test() {
  use dir <- support.with_directory("release_erts")
  support.write(dir <> "/pooka.toml", "name = \"app\"\nversion = \"1.0.0\"\n")
  support.write(
    dir <> "/src/main.pooka",
    "module main\nexternal VM from erlang \"erlang\" { halt() -> Nil }\nmain() { VM.halt() }\n",
  )
  let assert Ok(report) = release.export(dir, True)
  assert execute(report.directory <> "/bin/app", ["run"], dir).0 == 0
  let boot = report.directory <> "/releases/1.0.0/app.boot"
  let assert Ok(original) = simplifile.read_bits(boot)
  support.write(dir <> "/src/main.pooka", "broken")
  let assert Error(_) = release.export(dir, True)
  assert simplifile.read_bits(boot) == Ok(original)
}
