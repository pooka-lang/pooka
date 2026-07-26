//// A binary segment carries several small instructions on its label.
////
//// Validate representation, signedness, endianness, size and unit options. Keep
//// the normalized descriptor with diagnostics so layout and generation interpret
//// the same segment rules.
////
//// ```pooka
//// <<value:int, tail:bits>>
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/constant
import compiler/parser/ast
import compiler/typesystem/monotype.{type Type}
import diagnostics/diagnostic.{type Diagnostic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import utilities/location.{type Span}

pub type Kind {
  Integer
  Float
  Bits
  Bytes
  Text(encoding: String)
  Codepoint(encoding: String)
}

pub type Options {
  Options(
    kind: Kind,
    value_type: Type,
    sizes: List(ast.BitArrayOption),
    diagnostics: List(Diagnostic),
  )
}

pub type UnsupportedOption {
  UnsupportedOption(span: Span, feature: String)
}

type Progress {
  Progress(
    kind: Option(Kind),
    sizes: List(ast.BitArrayOption),
    diagnostics: List(Diagnostic),
  )
}

/// Normalize and validate a segment's options once, retaining diagnostics beside
/// the selected representation.
///
/// ```text
/// size, unit, signedness and encoding -> one normalized segment description
/// ```
pub fn analyze(
  options: List(ast.BitArrayOption),
  path: String,
) -> Result(Options, UnsupportedOption) {
  use progress <- result.try(
    list.try_fold(options, Progress(None, [], []), fn(progress, option) {
      case option {
        ast.SizeOption(_, _) | ast.UnitOption(_, _) ->
          Ok(Progress(..progress, sizes: [option, ..progress.sizes]))
        ast.NamedOption(name, span) ->
          case name {
            "int" -> Ok(select(progress, Integer, span, path))
            "float" -> Ok(select(progress, Float, span, path))
            "bits" -> Ok(select(progress, Bits, span, path))
            "bytes" -> Ok(select(progress, Bytes, span, path))
            "utf8" | "utf16" | "utf32" ->
              Ok(select(progress, Text(name), span, path))
            "big" | "little" | "native" | "signed" | "unsigned" -> Ok(progress)
            "utf8_codepoint" ->
              Ok(select(progress, Codepoint("utf8"), span, path))
            "utf16_codepoint" ->
              Ok(select(progress, Codepoint("utf16"), span, path))
            "utf32_codepoint" ->
              Ok(select(progress, Codepoint("utf32"), span, path))
            _ ->
              Ok(
                Progress(..progress, diagnostics: [
                  diagnostic.error(
                    "type.unknown_bit_array_option",
                    "unknown bit-array segment option",
                  )
                    |> diagnostic.primary(
                      location.new(path, span),
                      "`" <> name <> "` is not a segment option",
                    )
                    |> diagnostic.conclusion(
                      "Use a supported segment representation, size, unit, signedness or endianness option.",
                    ),
                  ..progress.diagnostics
                ]),
              )
          }
      }
    }),
  )
  let kind = case progress.kind {
    Some(kind) -> kind
    None -> Integer
  }
  let progress =
    Progress(
      ..progress,
      diagnostics: list.append(
        progress.diagnostics,
        validate(options, kind, path),
      ),
    )
  let value_type = case diagnostic.has_errors(progress.diagnostics) {
    True -> monotype.ErrorType
    False ->
      case kind {
        Integer -> monotype.IntType
        Float -> monotype.FloatType
        Bits | Bytes -> monotype.BitArrayType
        Text(_) -> monotype.StringType
        Codepoint(_) -> codepoint_type()
      }
  }
  Ok(Options(
    kind,
    value_type,
    list.reverse(progress.sizes),
    list.reverse(progress.diagnostics),
  ))
}

fn select(
  progress: Progress,
  kind: Kind,
  span: Span,
  path: String,
) -> Progress {
  case progress.kind {
    None -> Progress(..progress, kind: Some(kind))
    Some(previous) if previous == kind -> progress
    Some(_) ->
      Progress(..progress, diagnostics: [
        diagnostic.error(
          "type.conflicting_bit_array_options",
          "conflicting bit-array segment representations",
        )
          |> diagnostic.primary(
            location.new(path, span),
            "this segment already has a different representation",
          )
          |> diagnostic.conclusion(
            "Select one representation for each bit-array segment.",
          ),
        ..progress.diagnostics
      ])
  }
}

fn validate(
  options: List(ast.BitArrayOption),
  kind: Kind,
  path: String,
) -> List(Diagnostic) {
  let #(_, diagnostics) =
    list.fold(options, #([], []), fn(acc, option) {
      let #(seen, diagnostics) = acc
      let #(category, span) = case option {
        ast.SizeOption(_, span) -> #("size", span)
        ast.UnitOption(_, span) -> #("unit", span)
        ast.NamedOption(name, span) -> #(
          case name {
            "big" | "little" | "native" -> "endianness"
            "signed" | "unsigned" -> "signedness"
            _ -> ""
          },
          span,
        )
      }
      let repeated = case category != "" && list.contains(seen, category) {
        True -> [
          problem(
            "duplicate_bit_array_option",
            "duplicate bit-array option",
            span,
            path,
            "this segment already specifies " <> category,
            "Specify each size, unit, signedness and endianness once.",
          ),
        ]
        False -> []
      }
      let invalid = case option {
        ast.SizeOption(value, span) ->
          case kind {
            Text(_) | Codepoint(_) -> [
              incompatible(span, path, "UTF segments determine their own size."),
            ]
            _ ->
              case constant.integer(value) {
                Ok(size) if size < 0 -> [
                  problem(
                    "invalid_bit_array_size",
                    "negative bit-array segment size",
                    span,
                    path,
                    "a segment size cannot be negative",
                    "Use a non-negative number of units.",
                  ),
                ]
                _ -> []
              }
          }
        ast.UnitOption(value, span) ->
          case kind {
            Text(_) | Codepoint(_) -> [
              incompatible(
                span,
                path,
                "UTF segments do not accept a unit option.",
              ),
            ]
            _ ->
              case constant.integer(value) {
                Ok(unit) if unit < 1 || unit > 256 -> [
                  problem(
                    "invalid_bit_array_unit",
                    "invalid bit-array segment unit",
                    span,
                    path,
                    "a unit must be between 1 and 256 bits",
                    "Use a unit in the inclusive range 1–256.",
                  ),
                ]
                _ -> []
              }
          }
        ast.NamedOption(name, span) ->
          case name, kind {
            "signed", Integer | "unsigned", Integer -> []
            "signed", _ | "unsigned", _ -> [
              incompatible(
                span,
                path,
                "Signedness applies only to integer segments.",
              ),
            ]
            "big", Integer
            | "little", Integer
            | "native", Integer
            | "big", Float
            | "little", Float
            | "native", Float
            | "big", Codepoint("utf16")
            | "little", Codepoint("utf16")
            | "native", Codepoint("utf16")
            | "big", Codepoint("utf32")
            | "little", Codepoint("utf32")
            | "native", Codepoint("utf32")
            | "big", Text("utf16")
            | "little", Text("utf16")
            | "native", Text("utf16")
            | "big", Text("utf32")
            | "little", Text("utf32")
            | "native", Text("utf32")
            -> []
            "big", _ | "little", _ | "native", _ -> [
              incompatible(
                span,
                path,
                "Endianness applies to integers, floats, UTF-16 and UTF-32.",
              ),
            ]
            _, _ -> []
          }
      }
      #([category, ..seen], list.flatten([diagnostics, repeated, invalid]))
    })

  case diagnostic.has_errors(diagnostics) {
    True -> diagnostics
    False -> list.append(diagnostics, float_width(options, kind, path))
  }
}

fn incompatible(span: Span, path: String, reason: String) -> Diagnostic {
  problem(
    "incompatible_bit_array_option",
    "incompatible bit-array option",
    span,
    path,
    "this option does not apply to the segment representation",
    reason,
  )
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

fn float_width(
  options: List(ast.BitArrayOption),
  kind: Kind,
  path: String,
) -> List(Diagnostic) {
  case kind {
    Float -> {
      let #(size, unit, span) =
        list.fold(options, #(Ok(64), Ok(1), None), fn(acc, option) {
          case option {
            ast.SizeOption(value, span) -> #(
              constant.integer(value),
              acc.1,
              Some(span),
            )
            ast.UnitOption(value, span) -> #(
              acc.0,
              constant.integer(value),
              Some(span),
            )
            _ -> acc
          }
        })
      case size, unit, span {
        Ok(size), Ok(unit), Some(span)
          if size >= 0 && unit >= 1 && unit <= 256
        -> {
          let bits = size * unit
          case bits == 16 || bits == 32 || bits == 64 {
            True -> []
            False -> [
              problem(
                "invalid_float_segment_size",
                "invalid float segment size",
                span,
                path,
                "size multiplied by unit must be 16, 32 or 64 bits",
                "BEAM float segments use 16, 32 or 64 bits.",
              ),
            ]
          }
        }
        _, _, _ -> []
      }
    }
    _ -> []
  }
}

/// Require a supported compile-time integer unit where the binary representation
/// needs one.
///
/// ```text
/// a runtime variable cannot stand in for a required constant unit
/// ```
pub fn constant_unit(
  value: ast.Expression,
  span: Span,
  path: String,
) -> List(Diagnostic) {
  case constant.integer(value) {
    Ok(_) -> []
    Error(_) -> [
      problem(
        "non_constant_bit_array_unit",
        "bit-array segment unit must be constant",
        span,
        path,
        "this unit cannot be evaluated at compile time",
        "Use constant integer arithmetic for the unit; use size(...) for a runtime segment width.",
      ),
    ]
  }
}

/// Return the language type used by Unicode code-point segments.
///
/// ```text
/// UTF code-point segment -> Int value
/// ```
pub fn codepoint_type() -> Type {
  monotype.Nominal("$core", "UtfCodepoint", monotype.ClassKind, [])
}
