//// A package name has to travel through several toolchains.
////
//// Validate names against lexical and reserved-name rules, and suggest a nearby
//// usable spelling when possible. A valid directory name alone is not enough for
//// a package identity.
////
//// ```text
//// lowercase letters, digits and underscores form ordinary package names
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/lexer/token
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const max_length = 64

const reserved = ["pooka", "erlang", "elixir", "gleam", "stdlib", "otp"]

pub type NameProblem {
  EmptyName

  BadFirstCharacter(character: String)

  BadCharacter(character: String, index: Int)
  TooLong(length: Int)

  Reserved(word: String)
}

pub fn validate(name: String) -> Result(Nil, NameProblem) {
  case string.to_graphemes(name) {
    [] -> Error(EmptyName)
    [first, ..rest] ->
      case is_lowercase_letter(first), first_bad_character(rest, 1) {
        False, _ -> Error(BadFirstCharacter(first))
        True, Some(#(character, index)) -> Error(BadCharacter(character, index))
        True, None -> check_length_and_reserved(name)
      }
  }
}

fn check_length_and_reserved(name: String) -> Result(Nil, NameProblem) {
  let length = string.length(name)
  case length > max_length, is_reserved(name) {
    True, _ -> Error(TooLong(length))
    False, True -> Error(Reserved(name))
    False, False -> Ok(Nil)
  }
}

pub fn is_reserved(word: String) -> Bool {
  list.contains(token.keywords, word) || list.contains(reserved, word)
}

fn first_bad_character(
  characters: List(String),
  index: Int,
) -> Option(#(String, Int)) {
  case characters {
    [] -> None
    [character, ..rest] ->
      case is_name_character(character) {
        True -> first_bad_character(rest, index + 1)
        False -> Some(#(character, index))
      }
  }
}

pub fn suggest(name: String) -> Option(String) {
  let cleaned =
    name
    |> string.lowercase
    |> string.to_graphemes
    |> list.filter_map(fn(character) {
      case character {
        "-" | " " | "." -> Ok("_")
        _ ->
          case is_name_character(character) {
            True -> Ok(character)
            False -> Error(Nil)
          }
      }
    })
    |> string.concat
    |> collapse_underscores
    |> trim_underscores
  case cleaned == name, validate(cleaned) {
    False, Ok(Nil) -> Some(cleaned)
    _, _ -> None
  }
}

fn collapse_underscores(text: String) -> String {
  case string.contains(text, "__") {
    True -> collapse_underscores(string.replace(text, "__", "_"))
    False -> text
  }
}

fn trim_underscores(text: String) -> String {
  case string.starts_with(text, "_"), string.ends_with(text, "_") {
    True, _ -> trim_underscores(string.drop_start(text, 1))
    False, True -> trim_underscores(string.drop_end(text, 1))
    False, False -> text
  }
}

fn is_lowercase_letter(character: String) -> Bool {
  string.length(character) == 1
  && string.contains("abcdefghijklmnopqrstuvwxyz", character)
}

fn is_name_character(character: String) -> Bool {
  is_lowercase_letter(character)
  || string.length(character) == 1
  && string.contains("0123456789_", character)
}
