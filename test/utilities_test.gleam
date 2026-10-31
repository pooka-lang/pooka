//// Even the small rulers need their markings checked.
////
//// Exercise source locations, Unicode boundaries, colour helpers, suggestions
//// and time formatting. Byte offsets, line endings and displayed characters
//// are different measures. Host-dependent checks use broad properties rather
//// than expecting one exact wall clock or terminal.

import gleam/option.{None, Some}
import gleam/order
import gleam/string
import utilities/colour
import utilities/location.{Position, Span}
import utilities/text
import utilities/timer

pub fn start_test() {
  assert location.start() == Position(line: 1, column: 1, byte_offset: 0)
}

pub fn locate_start_test() {
  assert location.locate("hello", 0)
    == Position(line: 1, column: 1, byte_offset: 0)
}

pub fn locate_same_line_test() {
  assert location.locate("hello", 2)
    == Position(line: 1, column: 3, byte_offset: 2)
}

pub fn locate_after_newline_test() {
  assert location.locate("ab\ncd", 4)
    == Position(line: 2, column: 2, byte_offset: 4)
}

pub fn locate_at_newline_test() {
  assert location.locate("ab\ncd", 3)
    == Position(line: 2, column: 1, byte_offset: 3)
}

pub fn locate_multibyte_char_test() {
  assert location.locate("é!", 2)
    == Position(line: 1, column: 2, byte_offset: 2)
}

pub fn locate_crlf_test() {
  assert location.locate("a\r\nb", 3)
    == Position(line: 2, column: 1, byte_offset: 3)
}

pub fn locate_cr_test() {
  assert location.locate("a\rb", 2)
    == Position(line: 2, column: 1, byte_offset: 2)
}

pub fn locate_end_of_input_test() {
  assert location.locate("hi", 2)
    == Position(line: 1, column: 3, byte_offset: 2)
}

pub fn span_test() {
  assert location.span("ab\ncd", 1, 4)
    == Span(
      start: Position(line: 1, column: 2, byte_offset: 1),
      end: Position(line: 2, column: 2, byte_offset: 4),
    )
}

pub fn between_test() {
  let s = location.start()
  let e = Position(line: 1, column: 5, byte_offset: 4)
  assert location.between(s, e) == Span(start: s, end: e)
}

pub fn locate_clamps_out_of_range_offsets_test() {
  assert location.locate("abc", -5) == Position(1, 1, 0)
  assert location.locate("abc", 100) == Position(1, 4, 3)
}

// An arbitrary byte offset may land inside a multibyte character. Snap to a
// valid boundary before deriving a location that other tools will slice.
pub fn locate_snaps_to_a_character_boundary_test() {
  assert location.locate("é!", 1) == Position(1, 1, 0)
}

pub fn span_swaps_reversed_offsets_test() {
  assert location.span("abcdef", 4, 1) == location.span("abcdef", 1, 4)
}

pub fn text_test() {
  let source = "let name = 1"
  assert location.text(source, location.span(source, 4, 8)) == "name"
  assert location.slice(source, 50, 60) == ""
}

pub fn lines_test() {
  assert location.lines("a\nb\r\nc\rd") == ["a", "b", "c", "d"]
  assert location.lines("a\n") == ["a", ""]
  assert location.line("one\ntwo", 2) == "two"
  assert location.line("one\ntwo", 3) == ""
  assert location.line("one\ntwo", 0) == ""
}

pub fn compare_spans_test() {
  let first = location.span("abcdef", 0, 2)
  let second = location.span("abcdef", 4, 6)
  assert location.compare(first, second) == order.Lt
  assert location.compare(second, first) == order.Gt
  assert location.compare(first, location.span("abcdef", 0, 3)) == order.Lt
}

pub fn label_test() {
  let span = Span(Position(3, 5, 20), Position(3, 9, 24))
  assert location.label(location.new("src/main.pooka", span))
    == "src/main.pooka:3:5"
}

pub fn point_test() {
  let position = Position(2, 3, 7)
  assert location.point(position) == Span(position, position)
  assert !location.is_multiline(location.point(position))
}

pub fn styles_are_escape_sequences_test() {
  assert colour.lantern_orange == "\u{001b}[38;2;255;137;31m"
  assert colour.bold_scarf == "\u{001b}[1;38;2;217;91;23m"
  assert colour.reset == "\u{001b}[0m"
}

pub fn diagnostic_frame_colours_test() {
  assert colour.diagnostic_gutter == colour.magic_violet
  assert colour.magic_violet == "\u{001b}[38;2;117;97;142m"
  assert colour.diagnostic_location == colour.amber_glow
  assert colour.amber_glow == "\u{001b}[38;2;255;182;75m"
}

pub fn paint_test() {
  assert colour.paint("hi", colour.lantern_orange, colour.Ansi)
    == colour.lantern_orange <> "hi" <> colour.reset
  assert colour.paint("hi", colour.lantern_orange, colour.PlainText) == "hi"
  assert colour.paint("", colour.lantern_orange, colour.Ansi) == ""
  assert colour.paint("hi", "", colour.Ansi) == "hi"
}

pub fn strip_test() {
  let painted =
    colour.paint("error", colour.diagnostic_error, colour.Ansi)
    <> ": "
    <> colour.paint("title", colour.bold, colour.Ansi)
  assert colour.strip(painted) == "error: title"
  assert colour.strip("plain") == "plain"
}

pub fn edit_distance_test() {
  assert text.edit_distance("", "") == 0
  assert text.edit_distance("abc", "abc") == 0
  assert text.edit_distance("kitten", "sitting") == 3
  assert text.edit_distance("", "abc") == 3
  assert text.edit_distance("pritn", "print") == 2
}

pub fn closest_test() {
  assert text.closest("chek", ["check", "build", "clean"]) == Some("check")
  assert text.closest("zzzz", ["check", "build"]) == None

  assert text.closest("cat", ["bat", "hat"]) == None
  assert text.closest("check", ["check"]) == None
}

pub fn counted_test() {
  assert text.counted(0, "error") == "0 errors"
  assert text.counted(1, "error") == "1 error"
  assert text.counted(2, "file") == "2 files"
}

pub fn code_test() {
  assert text.code("x") == "`x`"
  assert string.length(text.code("")) == 2
}

pub fn now_reads_the_current_time_in_microseconds_test() {
  let first = timer.now()
  assert first > 1_600_000_000_000_000
  assert timer.now() - first < 60_000_000
}

pub fn durations_switch_to_seconds_at_100ms_test() {
  assert timer.format(412) == "412µs"
  assert timer.format(12_500) == "12.50ms"
  assert timer.format(99_990) == "99.99ms"
  assert timer.format(100_000) == "0.10s"
  assert timer.format(756_670) == "0.75s"
  assert timer.format(2_310_000) == "2.31s"
}

@external(erlang, "echo_test_ffi", "detection")
fn detect_in_child(
  no_colour: String,
  force_colour: String,
  term: String,
) -> String

pub fn colour_detection_respects_overrides_and_redirected_streams_test() {
  assert detect_in_child("", "", "xterm-256color") == "{plain_text,plain_text}"
  assert detect_in_child("", "", "dumb") == "{plain_text,plain_text}"
  assert detect_in_child("", "1", "xterm-256color") == "{ansi,ansi}"
  assert detect_in_child("", "1", "dumb") == "{ansi,ansi}"
  assert detect_in_child("", "0", "xterm-256color") == "{ansi,ansi}"
  assert detect_in_child("1", "1", "xterm-256color")
    == "{plain_text,plain_text}"
  assert detect_in_child("✓", "1", "dumb") == "{plain_text,plain_text}"
}

// Combining marks, emoji and half of a CRLF pair stress different boundaries.
// Keep byte positions and line transitions consistent without normalizing
// source text.
pub fn locate_combining_characters_emoji_and_partial_crlf_test() {
  let source = "e\u{0301}😀\r\nz"
  assert location.locate(source, 1) == Position(1, 2, 1)
  assert location.locate(source, 2) == Position(1, 2, 1)
  assert location.locate(source, 3) == Position(1, 2, 3)
  assert location.locate(source, 6) == Position(1, 2, 3)
  assert location.locate(source, 7) == Position(1, 3, 7)
  assert location.locate(source, 8) == Position(2, 1, 8)
  assert location.locate(source, 9) == Position(2, 1, 9)
  assert location.locate(source, 10) == Position(2, 2, 10)
}

pub fn slices_preserve_utf8_boundary_and_clamping_behaviour_test() {
  assert location.slice("é😀", -10, 999) == "é😀"
  assert location.slice("é😀", 1, 2) == ""
  assert location.slice("é😀", 2, 6) == "😀"
  assert location.slice("é😀", 5, 2) == ""
}
