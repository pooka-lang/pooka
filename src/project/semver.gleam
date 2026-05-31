//// Versions need an ordering more careful than alphabetizing their coats.
////
//// Parse semantic versions and requirements, compare releases and test
//// constraints. Keep prerelease identifiers separate from the three numeric
//// release components.
////
//// ```text
//// 1.10.0 sorts after 1.2.0
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

pub type Version {
  Version(major: Int, minor: Int, patch: Int, pre: Option(String))
}

pub fn parse(s: String) -> Result(Version, Nil) {
  use plain <- result.try(case string.split_once(string.trim(s), "+") {
    Ok(#(version, metadata)) ->
      case identifiers(metadata, False) {
        True -> Ok(version)
        False -> Error(Nil)
      }
    Error(_) -> Ok(string.trim(s))
  })
  use #(core, pre) <- result.try(case string.split_once(plain, "-") {
    Ok(#(core, pre)) ->
      case identifiers(pre, True) {
        True -> Ok(#(core, Some(pre)))
        False -> Error(Nil)
      }
    Error(_) -> Ok(#(plain, None))
  })
  case string.split(core, ".") {
    [major, minor, patch] -> {
      use major <- result.try(number(major))
      use minor <- result.try(number(minor))
      use patch <- result.try(number(patch))
      Ok(Version(major, minor, patch, pre))
    }
    [major, minor] -> {
      use major <- result.try(number(major))
      use minor <- result.try(number(minor))
      Ok(Version(major, minor, 0, pre))
    }
    _ -> Error(Nil)
  }
}

fn digits(value: String) -> Bool {
  value != ""
  && list.all(string.to_graphemes(value), fn(c) {
    string.contains("0123456789", c)
  })
}

fn number(value: String) -> Result(Int, Nil) {
  case digits(value) && { value == "0" || !string.starts_with(value, "0") } {
    True -> int.parse(value)
    False -> Error(Nil)
  }
}

fn identifiers(value: String, numeric: Bool) -> Bool {
  list.all(string.split(value, "."), fn(part) {
    part != ""
    && list.all(string.to_graphemes(part), fn(c) {
      string.contains(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-",
        c,
      )
    })
    && { !numeric || !digits(part) || result.is_ok(number(part)) }
  })
}

pub fn compare(a: Version, b: Version) -> order.Order {
  case int.compare(a.major, b.major) {
    order.Eq ->
      case int.compare(a.minor, b.minor) {
        order.Eq ->
          case int.compare(a.patch, b.patch) {
            order.Eq -> compare_pre(a.pre, b.pre)
            o -> o
          }
        o -> o
      }
    o -> o
  }
}

pub fn to_string(v: Version) -> String {
  let core =
    int.to_string(v.major)
    <> "."
    <> int.to_string(v.minor)
    <> "."
    <> int.to_string(v.patch)
  case v.pre {
    Some(pre) -> core <> "-" <> pre
    None -> core
  }
}

/// Test a parsed version against the supported requirement expression rather than
/// comparing version strings lexically.
///
/// ```text
/// 1.10.0 is later than 1.2.0 under semantic version ordering
/// ```
pub fn satisfies(version: Version, requirement: String) -> Bool {
  requirement
  |> string.split(" or ")
  |> list.any(fn(alt) {
    alt
    |> string.split(" and ")
    |> list.all(fn(clause) { satisfies_clause(version, string.trim(clause)) })
  })
}

fn satisfies_clause(version: Version, clause: String) -> Bool {
  case clause {
    "*" -> True
    "" -> False
    "~>" <> rest ->
      case parse(rest) {
        Error(_) -> False
        Ok(min) -> {
          let core =
            rest |> string.split("+") |> list.first |> result.unwrap(rest)
          let core =
            core |> string.split("-") |> list.first |> result.unwrap(core)
          let max = case list.length(string.split(core, ".")) {
            2 -> Version(min.major + 1, 0, 0, None)
            _ -> Version(min.major, min.minor + 1, 0, None)
          }
          compare(version, min) != order.Lt && compare(version, max) == order.Lt
        }
      }
    ">=" <> rest ->
      case parse(rest) {
        Error(_) -> False
        Ok(v) -> compare(version, v) != order.Lt
      }
    ">" <> rest ->
      case parse(rest) {
        Error(_) -> False
        Ok(v) -> compare(version, v) == order.Gt
      }
    "<=" <> rest ->
      case parse(rest) {
        Error(_) -> False
        Ok(v) -> compare(version, v) != order.Gt
      }
    "<" <> rest ->
      case parse(rest) {
        Error(_) -> False
        Ok(v) -> compare(version, v) == order.Lt
      }
    "==" <> rest ->
      case parse(rest) {
        Error(_) -> False
        Ok(v) -> compare(version, v) == order.Eq
      }
    "!=" <> rest ->
      case parse(rest) {
        Error(_) -> False
        Ok(v) -> compare(version, v) != order.Eq
      }

    _ ->
      case parse(clause) {
        Error(_) -> False
        Ok(v) -> compare(version, v) == order.Eq
      }
  }
}

fn compare_pre(a: Option(String), b: Option(String)) -> order.Order {
  case a, b {
    None, None -> order.Eq
    None, Some(_) -> order.Gt
    Some(_), None -> order.Lt
    Some(left), Some(right) ->
      compare_identifiers(string.split(left, "."), string.split(right, "."))
  }
}

fn compare_identifiers(a: List(String), b: List(String)) -> order.Order {
  case a, b {
    [], [] -> order.Eq
    [], _ -> order.Lt
    _, [] -> order.Gt
    [x, ..xs], [y, ..ys] -> {
      let order = case digits(x), digits(y) {
        True, True -> {
          let assert Ok(x) = int.parse(x)
          let assert Ok(y) = int.parse(y)
          int.compare(x, y)
        }
        True, False -> order.Lt
        False, True -> order.Gt
        False, False -> string.compare(x, y)
      }
      case order {
        order.Eq -> compare_identifiers(xs, ys)
        _ -> order
      }
    }
  }
}

pub fn valid_requirement(requirement: String) -> Bool {
  requirement
  |> string.split(" or ")
  |> list.all(fn(alt) {
    alt
    |> string.split(" and ")
    |> list.all(fn(clause) {
      let clause = string.trim(clause)
      let version = case clause {
        "~>" <> rest
        | ">=" <> rest
        | "<=" <> rest
        | "==" <> rest
        | "!=" <> rest
        | ">" <> rest
        | "<" <> rest -> rest
        _ -> clause
      }
      clause == "*" || result.is_ok(parse(version))
    })
  })
}
