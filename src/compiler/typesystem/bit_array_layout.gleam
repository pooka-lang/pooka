//// Measure the binary before promising that it fits.
////
//// Derive construction and pattern widths from normalized segment descriptions.
//// Unknown widths remain unknown; arithmetic on a size must not turn uncertainty
//// into a made-up byte count.
////
//// ```text
//// an 8-bit field followed by a 16-bit field has width 24
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/constant
import compiler/literal
import compiler/parser/ast
import compiler/typesystem/bit_array.{
  type Kind, type Options, Bits, Bytes, Codepoint, Float, Integer, Text,
}
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import utilities/location.{type Span}

/// Calculate the known bit layout and alignment constraints of a binary pattern.
///
/// ```text
/// one 8-bit field + one 16-bit field -> known width 24
/// ```
pub fn pattern_layout(
  segments: List(ast.BitArraySegment(ast.Pattern)),
  path: String,
) -> List(Diagnostic) {
  case segments {
    [] | [_] -> []
    [segment, ..rest] -> {
      let binary =
        list.any(segment.options, fn(option) {
          case option {
            ast.NamedOption("bits", _) | ast.NamedOption("bytes", _) -> True
            _ -> False
          }
        })
      let sized =
        list.any(segment.options, fn(option) {
          case option {
            ast.SizeOption(..) -> True
            _ -> False
          }
        })
      let errors = case binary && !sized {
        True -> [
          problem(
            "unsized_bit_array_pattern_segment",
            "unsized binary segment before the end of a pattern",
            segment.span,
            path,
            "this segment consumes the remaining input",
            "Give this segment an explicit size or place it last.",
          ),
        ]
        False -> []
      }
      list.append(errors, pattern_layout(rest, path))
    }
  }
}

/// Calculate construction widths while leaving genuinely dynamic segment sizes
/// unknown.
///
/// ```text
/// runtime-sized segment -> unknown width, not zero width
/// ```
pub fn construction_layout(
  value: ast.Expression,
  options: List(ast.BitArrayOption),
  analyzed: Options,
  span: Span,
  path: String,
) -> List(Diagnostic) {
  case analyzed.kind, diagnostic.has_errors(analyzed.diagnostics) {
    Bits, False | Bytes, False -> {
      let unit = segment_unit(options, analyzed.kind)
      let available = known_bits(value)
      let size = explicit_size(options)
      case available, unit, size {
        Ok(available), Ok(unit), None if unit > 0 ->
          case available % unit == 0 {
            True -> []
            False -> [
              problem(
                "unaligned_bit_array_segment",
                "unaligned bit-array segment",
                span,
                path,
                "the payload length is not divisible by this segment's unit",
                "Use a compatible unit or a bit segment for this payload.",
              ),
            ]
          }
        Ok(available), Ok(unit), Some(size) if unit > 0 ->
          case constant.integer(size) {
            Ok(size) if size >= 0 && size * unit > available -> [
              problem(
                "short_bit_array_segment",
                "bit-array payload is too short",
                span,
                path,
                "the requested segment is longer than the literal payload",
                "Reduce the segment size or provide a longer payload.",
              ),
            ]
            _ -> []
          }
        _, _, _ -> []
      }
    }
    _, _ -> []
  }
}

fn explicit_size(options: List(ast.BitArrayOption)) -> Option(ast.Expression) {
  list.find_map(options, fn(option) {
    case option {
      ast.SizeOption(value, _) -> Ok(value)
      _ -> Error(Nil)
    }
  })
  |> option_from_result
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn segment_unit(
  options: List(ast.BitArrayOption),
  kind: Kind,
) -> Result(Int, Nil) {
  case
    list.find_map(options, fn(option) {
      case option {
        ast.UnitOption(value, _) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  {
    Ok(value) -> constant.integer(value)
    Error(Nil) ->
      Ok(case kind {
        Bytes -> 8
        _ -> 1
      })
  }
}

fn known_bits(value: ast.Expression) -> Result(Int, Nil) {
  case value {
    ast.BitArrayExpression(segments, _) ->
      list.try_fold(segments, 0, fn(total, segment) {
        use options <- result.try(
          bit_array.analyze(segment.options, "")
          |> result.map_error(fn(_) { Nil }),
        )
        use Nil <- result.try(case diagnostic.has_errors(options.diagnostics) {
          True -> Error(Nil)
          False -> Ok(Nil)
        })
        use bits <- result.try(segment_bits(
          segment.value,
          segment.options,
          options.kind,
        ))
        Ok(total + bits)
      })
    _ -> Error(Nil)
  }
}

fn segment_bits(
  value: ast.Expression,
  options: List(ast.BitArrayOption),
  kind: Kind,
) -> Result(Int, Nil) {
  case kind {
    Codepoint(_) -> Error(Nil)
    Text(encoding) ->
      case value {
        ast.StringLiteral(text, _) -> {
          use text <- result.try(literal.decode_string(text))
          Ok(case encoding {
            "utf8" -> string.byte_size(text) * 8
            "utf16" ->
              list.fold(string.to_utf_codepoints(text), 0, fn(total, point) {
                total
                + case string.utf_codepoint_to_int(point) > 65_535 {
                  True -> 32
                  False -> 16
                }
              })
            _ -> list.length(string.to_utf_codepoints(text)) * 32
          })
        }
        _ -> Error(Nil)
      }
    Bits | Bytes -> {
      use unit <- result.try(segment_unit(options, kind))
      use Nil <- result.try(case unit > 0 {
        True -> Ok(Nil)
        False -> Error(Nil)
      })

      let available = known_bits(value)
      case explicit_size(options) {
        None -> {
          use bits <- result.try(available)
          case bits % unit == 0 {
            True -> Ok(bits)
            False -> Error(Nil)
          }
        }
        Some(size) -> {
          use size <- result.try(constant.integer(size))
          let bits = size * unit
          case size, available {
            size, _ if size < 0 -> Error(Nil)
            _, Ok(available) if bits > available -> Error(Nil)

            _, _ -> Ok(bits)
          }
        }
      }
    }
    _ -> {
      use unit <- result.try(segment_unit(options, kind))
      use Nil <- result.try(case unit > 0 {
        True -> Ok(Nil)
        False -> Error(Nil)
      })
      case explicit_size(options) {
        Some(value) -> {
          use size <- result.try(constant.integer(value))
          case size >= 0 {
            True -> Ok(size * unit)
            False -> Error(Nil)
          }
        }
        None ->
          case kind {
            Integer -> Ok(8 * unit)
            Float -> Ok(64 * unit)
            Bits | Bytes -> known_bits(value)
            Text(_) | Codepoint(_) -> Error(Nil)
          }
      }
    }
  }
}

fn problem(
  id: String,
  title: String,
  span: Span,
  path: String,
  label: String,
  reason: String,
) -> Diagnostic {
  diagnostic.error("type." <> id, title)
  |> diagnostic.primary(location.new(path, span), label)
  |> diagnostic.conclusion(reason)
}
