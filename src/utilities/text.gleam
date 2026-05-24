//// Small wording tools help the compiler speak clearly.
////
//// Provide edit distance, close-name suggestions and count-aware phrases. Keep
//// these helpers independent of source parsing and terminal styling.
////
//// ```text
//// a misspelled identifier -> nearby candidate names
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn edit_distance(from: String, to: String) -> Int {
  let target = string.to_graphemes(to)

  let first_row =
    list.index_map(list.repeat(0, list.length(target) + 1), fn(_, index) {
      index
    })
  let last_row =
    string.to_graphemes(from)
    |> list.index_fold(first_row, fn(previous, grapheme, index) {
      next_row(previous, grapheme, target, index + 1)
    })
  case list.last(last_row) {
    Ok(distance) -> distance
    Error(Nil) -> 0
  }
}

fn next_row(
  previous: List(Int),
  grapheme: String,
  target: List(String),
  row_start: Int,
) -> List(Int) {
  let #(row, _) =
    list.zip(target, list.zip(previous, list.drop(previous, 1)))
    |> list.fold(#([row_start], row_start), fn(state, cell) {
      let #(row, left) = state
      let #(target_grapheme, #(diagonal, above)) = cell
      let substitution = case grapheme == target_grapheme {
        True -> diagonal
        False -> diagonal + 1
      }
      let value = int.min(int.min(left + 1, above + 1), substitution)
      #([value, ..row], value)
    })
  list.reverse(row)
}

pub fn closest(word: String, candidates: List(String)) -> Option(String) {
  let allowed = case string.length(word) <= 3 {
    True -> 1
    False -> 2
  }
  let scored =
    candidates
    |> list.filter(fn(candidate) { candidate != word })
    |> list.map(fn(candidate) { #(candidate, edit_distance(word, candidate)) })
    |> list.filter(fn(scored) {
      scored.1 <= allowed && scored.1 < string.length(word)
    })
    |> list.sort(fn(first, second) { int.compare(first.1, second.1) })
  case scored {
    [] -> None
    [#(best, distance), ..rest] ->
      case list.any(rest, fn(other) { other.1 == distance }) {
        True -> None
        False -> Some(best)
      }
  }
}

pub fn counted(count: Int, noun: String) -> String {
  case count {
    1 -> "1 " <> noun
    _ -> int.to_string(count) <> " " <> noun <> "s"
  }
}

pub fn code(text: String) -> String {
  "`" <> text <> "`"
}
