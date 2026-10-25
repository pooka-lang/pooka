//// Announce the opening before the actors start speaking.
////
//// Use real CLI subprocesses to check activity ordering and terminal palette
//// sequences. Compiling and checking share the configured activity colour;
//// echo locations stay muted. Program output must not appear before the
//// Running announcement because capture and logging were stitched together
//// late.

import cli/cli
import cli/command
import gleam/string
import pooka
import support
import utilities/colour

@external(erlang, "shipment_test_ffi", "run_cli")
fn execute(arguments: List(String), directory: String) -> #(Int, String)

fn project(directory: String) {
  support.write(
    directory <> "/pooka.toml",
    "name = \"app\"\nversion = \"0.1.0\"\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nmain() { echo \"program output\"\necho 42 }\n",
  )
}

// Use a real child VM to observe the order of writes. Combining separately
// captured buffers afterward can make a program appear to speak before
// Running.
pub fn activity_precedes_program_output_in_the_actual_cli_test() {
  use directory <- support.with_directory("run_logging_order")
  project(directory)
  let #(status, output) = execute(["run"], directory)
  assert status == 0
  let assert Ok(#(build_log, program_output)) =
    string.split_once(output, "Running app.main\n")
  assert string.contains(build_log, "Compiling app\n")
  assert string.contains(build_log, "Compiled 1 module in ")
  assert program_output
    == "src/main.pooka:2\n\"program output\"\nsrc/main.pooka:3\n42\n"
}

pub fn compiled_uses_the_same_orange_as_other_activity_test() {
  use directory <- support.with_directory("run_logging_colour")
  project(directory)
  let env = command.plain(directory)
  let report =
    support.cli_main(["run"], command.Environment(..env, stderr: colour.Ansi))
  assert report.status == 0
  assert report.stdout == "\"program output\"\n42\n"
  assert string.contains(
    report.stderr,
    colour.bold_lantern_orange <> " Compiling",
  )
  assert string.contains(
    report.stderr,
    colour.bold_lantern_orange <> "  Compiled",
  )
  assert string.contains(
    report.stderr,
    colour.bold_lantern_orange <> "   Running",
  )
  assert !string.contains(report.stderr, colour.bold_amber_glow)
}

pub fn checked_activity_uses_the_same_amber_as_compilation_test() {
  use directory <- support.with_directory("check_logging_colour")
  project(directory)
  let env = command.plain(directory)
  let report =
    support.cli_main(["check"], command.Environment(..env, stderr: colour.Ansi))
  assert report.status == 0
  assert string.contains(
    report.stderr,
    colour.bold_lantern_orange <> "   Checked",
  )
  assert !string.contains(report.stderr, colour.bold_amber_glow <> "   Checked")
}

pub fn echo_locations_use_the_muted_grey_when_colour_is_on_test() {
  use directory <- support.with_directory("run_echo_colour")
  project(directory)
  let env = command.plain(directory)
  let coloured =
    cli.main(
      ["run"],
      pooka.version,
      command.Environment(..env, stderr: colour.Ansi),
    )
  assert string.contains(
    coloured.stdout,
    colour.muted <> "src/main.pooka:2" <> colour.reset <> "\n",
  )
  let plain = cli.main(["run"], pooka.version, env)
  assert string.contains(plain.stdout, "src/main.pooka:2\n")
  assert !string.contains(plain.stdout, "\u{001b}")
}

pub fn formatted_uses_the_same_orange_as_other_activity_test() {
  use directory <- support.with_directory("format_logging_colour")
  project(directory)
  let env = command.plain(directory)
  let report =
    support.cli_main(
      ["format"],
      command.Environment(..env, stderr: colour.Ansi),
    )
  assert report.status == 0
  assert string.contains(
    report.stderr,
    colour.bold_lantern_orange <> " Formatted",
  )
  assert !string.contains(report.stderr, colour.bold_amber_glow)
}

pub fn cleaned_uses_the_same_orange_as_other_activity_test() {
  use directory <- support.with_directory("clean_logging_colour")
  project(directory)
  let env = command.plain(directory)
  let report =
    support.cli_main(["clean"], command.Environment(..env, stdout: colour.Ansi))
  assert report.status == 0
  assert string.contains(report.stdout, colour.bold_lantern_orange <> "Cleaned")
  assert !string.contains(report.stdout, colour.bold_amber_glow)
}

pub fn new_create_lines_use_the_same_orange_as_other_activity_test() {
  use directory <- support.with_directory("new_logging_colour")
  let env = command.plain(directory)
  let report =
    support.cli_main(
      ["new", "demo"],
      command.Environment(..env, stdout: colour.Ansi),
    )
  assert report.status == 0
  assert string.contains(report.stdout, colour.bold_lantern_orange <> "create")
  assert !string.contains(report.stdout, colour.bold_amber_glow)
}
