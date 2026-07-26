//// Count the binary shapes a pattern actually welcomes.
////
//// Reason about known prefixes and lengths for exhaustiveness checking. Empty and
//// non-byte-aligned values need seats of their own, not an assumption that every
//// binary is a string.
////
//// ```text
//// <<>> is not covered by a pattern requiring one byte
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/constant
import compiler/literal
import compiler/parser/ast
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Layout {
  Layout(bits: List(Option(Bool)), tail: Bool, impossible: Bool)
}

const max_bits = 256

/// Derive the supported finite prefix/length facts for a binary pattern. Return
/// no proof when the pattern exceeds the bounded reasoning supported here.
///
/// ```text
/// <<>> proves empty coverage; a one-byte prefix excludes empty input
/// ```
pub fn prove(
  segments: List(ast.BitArraySegment(ast.Pattern)),
) -> Result(Layout, Nil) {
  list.try_fold(segments, Layout([], False, False), fn(acc, segment) {
    use layout <- result.try(segment_layout(segment))
    case
      acc.tail || list.length(acc.bits) + list.length(layout.bits) > max_bits
    {
      True -> Error(Nil)
      False ->
        Ok(Layout(
          list.append(acc.bits, layout.bits),
          layout.tail,
          acc.impossible || layout.impossible,
        ))
    }
  })
}

fn segment_layout(
  segment: ast.BitArraySegment(ast.Pattern),
) -> Result(Layout, Nil) {
  let names =
    list.filter_map(segment.options, fn(option) {
      case option {
        ast.NamedOption(name, _) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  use Nil <- result.try(
    case
      list.all(names, fn(name) {
        list.contains(
          [
            "int",
            "float",
            "bits",
            "bytes",
            "utf8",
            "utf16",
            "utf32",
            "big",
            "little",
            "native",
            "signed",
            "unsigned",
          ],
          name,
        )
      })
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  let kind =
    list.find(names, fn(name) {
      list.contains(
        ["int", "float", "bits", "bytes", "utf8", "utf16", "utf32"],
        name,
      )
    })
    |> result.unwrap("int")
  let little = list.contains(names, "little")
  let native = list.contains(names, "native")
  let unit =
    list.find_map(segment.options, fn(option) {
      case option {
        ast.UnitOption(value, _) -> Ok(constant.integer(value))
        _ -> Error(Nil)
      }
    })
  use unit <- result.try(case unit {
    Ok(unit) -> unit
    Error(Nil) ->
      Ok(case kind {
        "bytes" -> 8
        _ -> 1
      })
  })
  let size =
    list.find_map(segment.options, fn(option) {
      case option {
        ast.SizeOption(value, _) -> Ok(constant.integer(value))
        _ -> Error(Nil)
      }
    })
  let wildcard = case segment.value {
    ast.VariablePattern(..) | ast.DiscardPattern(_) -> True
    _ -> False
  }
  use Nil <- result.try(case kind {
    "float" -> Error(Nil)
    _ -> Ok(Nil)
  })
  case segment.value, kind {
    ast.StringPattern(source, _), "utf8"
    | ast.StringPattern(source, _), "utf16"
    | ast.StringPattern(source, _), "utf32"
    -> {
      use text <- result.try(literal.decode_string(source))
      use Nil <- result.try(
        case string.byte_size(text) * 8 <= max_bits && !native {
          True -> Ok(Nil)
          False -> Error(Nil)
        },
      )
      let encoded = encode(text, kind, little)
      case bit_array.bit_size(encoded) <= max_bits {
        True -> Ok(Layout(binary_bits(encoded), False, False))
        False -> Error(Nil)
      }
    }
    _, "bits" if wildcard && unit == 1 ->
      case size {
        Error(Nil) -> Ok(Layout([], True, False))
        Ok(size) ->
          sized(segment.value, size, unit, kind, little, native, names)
      }
    _, _ -> {
      let size = case size {
        Ok(size) -> size
        Error(Nil) ->
          case kind {
            "int" -> Ok(8)
            _ -> Error(Nil)
          }
      }
      sized(segment.value, size, unit, kind, little, native, names)
    }
  }
}

fn sized(
  value: ast.Pattern,
  size: Result(Int, Nil),
  unit: Int,
  kind: String,
  little: Bool,
  native: Bool,
  names: List(String),
) -> Result(Layout, Nil) {
  use size <- result.try(size)
  let width = size * unit
  use Nil <- result.try(
    case
      width >= 0 && width <= max_bits && unit > 0 && { !native || width <= 8 }
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  case value {
    ast.VariablePattern(..) | ast.DiscardPattern(_) ->
      Ok(Layout(list.repeat(None, width), False, False))
    ast.IntPattern(source, _) if kind == "int" -> {
      use value <- result.try(literal.parse_int(source))
      let limit = int.bitwise_shift_left(1, width)
      let signed = list.contains(names, "signed")
      let fits = case signed && width > 0 {
        True -> {
          value >= -{ limit / 2 } && value < limit / 2
        }
        False -> value >= 0 && value < limit
      }
      case fits {
        False -> Ok(Layout([], False, True))
        True -> {
          let value = int.bitwise_and(value, limit - 1)
          Ok(Layout(
            binary_bits(case little {
              True -> <<value:size(width)-little>>
              False -> <<value:size(width)-big>>
            }),
            False,
            False,
          ))
        }
      }
    }
    _ -> Error(Nil)
  }
}

fn binary_bits(value: BitArray) -> List(Option(Bool)) {
  case value {
    <<bit:1, rest:bits>> -> [Some(bit == 1), ..binary_bits(rest)]
    _ -> []
  }
}

fn encode(text: String, kind: String, little: Bool) -> BitArray {
  list.fold(string.to_utf_codepoints(text), <<>>, fn(acc, point) {
    case kind, little {
      "utf8", _ -> <<acc:bits, point:utf8_codepoint>>
      "utf16", True -> <<acc:bits, point:utf16_codepoint-little>>
      "utf16", False -> <<acc:bits, point:utf16_codepoint-big>>
      _, True -> <<acc:bits, point:utf32_codepoint-little>>
      _, False -> <<acc:bits, point:utf32_codepoint-big>>
    }
  })
}
