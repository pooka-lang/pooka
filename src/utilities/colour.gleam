//// Choose the lantern's colour without repainting the message.
////
//// Centralize banner colours and terminal detection. Plain output and NO_COLOR
//// keep the same text while omitting escape sequences.
////
//// ```text
//// paint("Ready", style, PlainText) -> "Ready"
//// ```

// SPDX-License-Identifier: Apache-2.0

import envoy
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/string

pub type Output {

  Ansi

  PlainText
}

pub type Stream {
  Stdout
  Stderr
}

pub const reset = "\u{001b}[0m"

pub const bold = "\u{001b}[1m"

pub const lantern_orange = "\u{001b}[38;2;255;137;31m"

pub const amber_glow = "\u{001b}[38;2;255;182;75m"

pub const magic_violet = "\u{001b}[38;2;117;97;142m"

pub const bold_lantern_orange = "\u{001b}[1;38;2;255;137;31m"

pub const bold_success_green = "\u{001b}[1;38;2;97;175;111m"

pub const bold_amber_glow = "\u{001b}[1;38;2;255;182;75m"

pub const bold_scarf = "\u{001b}[1;38;2;217;91;23m"

pub const bold_magic_violet = "\u{001b}[1;38;2;117;97;142m"

pub const muted = "\u{001b}[38;2;139;148;168m"

pub const diagnostic_error = bold_scarf

pub const diagnostic_warning = bold_amber_glow

pub const diagnostic_notice = bold_magic_violet

pub const diagnostic_secondary = magic_violet

pub const diagnostic_note = bold_magic_violet

pub const diagnostic_help = bold_amber_glow

pub const diagnostic_title = bold

pub const diagnostic_gutter = magic_violet

pub const diagnostic_location = amber_glow

/// Apply a style only for ANSI output and nonempty text. Plain output retains
/// exactly the same message.
///
/// ```gleam
/// paint("Ready", lantern_orange, PlainText) == "Ready"
/// ```
pub fn paint(text: String, style: String, output: Output) -> String {
  case output, style, text {
    PlainText, _, _ -> text
    Ansi, "", _ -> text
    Ansi, _, "" -> text
    Ansi, _, _ -> style <> text <> reset
  }
}

pub fn strip(text: String) -> String {
  strip_loop(string.to_graphemes(text), [])
}

fn strip_loop(graphemes: List(String), kept: List(String)) -> String {
  case graphemes {
    [] -> kept |> list.reverse |> string.concat
    ["\u{001b}", "[", ..rest] -> strip_loop(skip_parameters(rest), kept)
    [grapheme, ..rest] -> strip_loop(rest, [grapheme, ..kept])
  }
}

fn skip_parameters(graphemes: List(String)) -> List(String) {
  case graphemes {
    [] -> []
    [grapheme, ..rest] ->
      case string.contains("0123456789;:", grapheme) {
        True -> skip_parameters(rest)
        False -> rest
      }
  }
}

/// Respect NO_COLOR, FORCE_COLOR, dumb terminals and descriptor capabilities in
/// the established precedence order.
///
/// ```text
/// NO_COLOR set -> PlainText even when FORCE_COLOR is also set
/// ```
pub fn detect(stream: Stream) -> Output {
  case is_set("NO_COLOR"), is_set("FORCE_COLOR"), envoy.get("TERM") {
    True, _, _ -> PlainText
    False, True, _ -> Ansi
    False, False, Ok("dumb") -> PlainText
    False, False, _ ->
      case is_terminal(stream) {
        True -> Ansi
        False -> PlainText
      }
  }
}

fn is_set(name: String) -> Bool {
  case envoy.get(name) {
    Ok("") | Error(Nil) -> False
    Ok(_) -> True
  }
}

fn is_terminal(stream: Stream) -> Bool {
  case decode.run(terminal_options(User), decode.list(decode.dynamic)) {
    Error(_) -> False
    Ok(options) ->
      case has_option(stream, options) {
        True -> terminal_flag(stream, options)

        False ->
          case
            terminal_columns(case stream {
              Stdout -> StandardIo
              Stderr -> StandardError
            })
          {
            Ok(_) -> True
            Error(_) -> False
          }
      }
  }
}

type IoDevice {
  User
  StandardIo
  StandardError
}

type GeometryError

@external(erlang, "io", "getopts")
fn terminal_options(device: IoDevice) -> Dynamic

@external(erlang, "proplists", "is_defined")
fn has_option(stream: Stream, options: List(Dynamic)) -> Bool

@external(erlang, "proplists", "get_bool")
fn terminal_flag(stream: Stream, options: List(Dynamic)) -> Bool

@external(erlang, "io", "columns")
fn terminal_columns(device: IoDevice) -> Result(Int, GeometryError)
