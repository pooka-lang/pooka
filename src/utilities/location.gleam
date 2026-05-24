//// Leave a bookmark that can find the same place again.
////
//// Carry source positions and byte spans for every compiler stage. Slice original
//// text by offsets and keep path information attached when a location crosses
//// subsystem boundaries.
////
//// ```text
//// source bytes [start,end) -> one labelled source span
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/result
import gleam/string

pub type Position {
  Position(line: Int, column: Int, byte_offset: Int)
}

pub type Span {
  Span(start: Position, end: Position)
}

pub type Location {
  Location(path: String, span: Span)
}

pub fn start() -> Position {
  Position(1, 1, 0)
}

pub fn between(start start: Position, end end: Position) -> Span {
  Span(start, end)
}

pub fn point(position: Position) -> Span {
  Span(position, position)
}

pub fn locate(source: String, offset: Int) -> Position {
  let offset =
    snap(
      bit_array.from_string(source),
      int.clamp(offset, 0, string.byte_size(source)),
    )

  let #(number, last) =
    list.fold(lines(slice(source, 0, offset)), #(0, ""), fn(acc, line) {
      #(acc.0 + 1, line)
    })
  Position(number, string.length(last) + 1, offset)
}

/// Locate a half-open byte interval in the original source and retain its display
/// positions.
///
/// ```text
/// [start,end) includes start and excludes end
/// ```
pub fn span(source: String, start: Int, end: Int) -> Span {
  Span(locate(source, int.min(start, end)), locate(source, int.max(start, end)))
}

pub fn is_multiline(span: Span) -> Bool {
  span.start.line != span.end.line
}

pub fn compare(first: Span, second: Span) -> Order {
  case int.compare(first.start.byte_offset, second.start.byte_offset) {
    order.Eq -> int.compare(first.end.byte_offset, second.end.byte_offset)
    other -> other
  }
}

pub fn new(path: String, span: Span) -> Location {
  Location(path, span)
}

pub fn label(location: Location) -> String {
  location.path
  <> ":"
  <> int.to_string(location.span.start.line)
  <> ":"
  <> int.to_string(location.span.start.column)
}

pub fn slice(source: String, start: Int, end: Int) -> String {
  let start = int.clamp(start, 0, string.byte_size(source))
  let end = int.clamp(end, start, string.byte_size(source))
  bit_array.from_string(source)
  |> bit_array.slice(start, end - start)
  |> result.try(bit_array.to_string)
  |> result.unwrap("")
}

/// Read the original source bytes covered by a span. Display-column counts are
/// not string-slicing offsets.
///
/// ```text
/// a UTF-8 span still selects the original byte sequence
/// ```
pub fn text(source: String, span: Span) -> String {
  slice(source, span.start.byte_offset, span.end.byte_offset)
}

pub fn lines(source: String) -> List(String) {
  source
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
}

pub fn line(source: String, number: Int) -> String {
  case list.drop(lines(source), number - 1) {
    [found, ..] if number >= 1 -> found
    _ -> ""
  }
}

fn snap(bits: BitArray, offset: Int) -> Int {
  case bits {
    <<_:size(offset)-bytes, byte, _:bits>> if byte >= 128 && byte < 192 ->
      snap(bits, offset - 1)
    _ -> offset
  }
}
