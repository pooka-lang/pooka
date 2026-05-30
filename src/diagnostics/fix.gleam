//// A repair must fit the page it promises to mend.
////
//// Choose automatic edits, reject overlaps and apply source replacements in a
//// safe order. Byte ranges refer to the original source, not text already shifted
//// by an earlier edit.
////
//// ```text
//// replace [5,6) and [10,11) using the original offsets
//// ```

// SPDX-License-Identifier: Apache-2.0

import diagnostics/diagnostic.{type Diagnostic, type Fix}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import utilities/location

pub type FixError {
  InvalidSpan
  ConflictingEdits
}

pub fn automatic(diagnostics: List(Diagnostic), path: String) -> List(Fix) {
  diagnostics
  |> list.flat_map(fn(value) { value.fixes })
  |> list.filter(fn(edit) {
    edit.applicability == diagnostic.Automatic && edit.location.path == path
  })
}

/// Apply validated, nonoverlapping byte-range replacements against the original
/// source.
///
/// ```text
/// later edits cannot shift the coordinates of earlier source ranges
/// ```
pub fn apply(source: String, edits: List(Fix)) -> Result(String, FixError) {
  let edits =
    edits
    |> list.fold([], fn(found, edit) {
      case list.any(found, by_edit_identity(_, edit)) {
        True -> found
        False -> [edit, ..found]
      }
    })
  use edits <- result.try(validate_and_sort(source, edits))
  Ok(copy_chunks(source, edits, 0, []))
}

fn by_edit_identity(first: Fix, second: Fix) -> Bool {
  first.location == second.location && first.replacement == second.replacement
}

fn validate_and_sort(
  source: String,
  edits: List(Fix),
) -> Result(List(Fix), FixError) {
  use Nil <- result.try(
    list.try_each(edits, fn(edit) {
      let start = edit.location.span.start.byte_offset
      let end = edit.location.span.end.byte_offset

      case start >= 0 && end >= start && end <= string.byte_size(source) {
        False -> Error(InvalidSpan)
        True -> {
          use _ <- result.try(slice(source, 0, start))
          use _ <- result.try(slice(source, start, end - start))
          Ok(Nil)
        }
      }
    }),
  )
  let sorted =
    list.sort(edits, fn(first, second) {
      case
        int.compare(
          first.location.span.start.byte_offset,
          second.location.span.start.byte_offset,
        )
      {
        order.Eq ->
          int.compare(
            first.location.span.end.byte_offset,
            second.location.span.end.byte_offset,
          )
        other -> other
      }
    })
  use Nil <- result.try(check_conflicts(sorted))
  Ok(sorted)
}

fn check_conflicts(edits: List(Fix)) -> Result(Nil, FixError) {
  case edits {
    [first, second, ..rest] -> {
      let a = first.location.span
      let b = second.location.span
      case
        a.start.byte_offset == b.start.byte_offset
        || a.end.byte_offset > b.start.byte_offset
      {
        True -> Error(ConflictingEdits)
        False -> check_conflicts([second, ..rest])
      }
    }
    [_] | [] -> Ok(Nil)
  }
}

fn slice(source: String, start: Int, length: Int) -> Result(String, FixError) {
  use bits <- result.try(
    bit_array.slice(bit_array.from_string(source), start, length)
    |> result.map_error(fn(_) { InvalidSpan }),
  )
  bit_array.to_string(bits) |> result.map_error(fn(_) { InvalidSpan })
}

fn copy_chunks(
  source: String,
  edits: List(Fix),
  offset: Int,
  chunks: List(String),
) -> String {
  case edits {
    [] ->
      [location.slice(source, offset, string.byte_size(source)), ..chunks]
      |> list.reverse
      |> string.concat
    [edit, ..rest] -> {
      let span = edit.location.span
      let untouched = location.slice(source, offset, span.start.byte_offset)
      copy_chunks(source, rest, span.end.byte_offset, [
        edit.replacement,
        untouched,
        ..chunks
      ])
    }
  }
}
