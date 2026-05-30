//// Draw a small map around the place the program stumbled.
////
//// Render labelled source excerpts, notes and fixes for terminal readers. Colour
//// is an output choice; the diagnostic and its source spans remain unchanged.
////
//// ```text
//// primary label at line 4 -> source gutter + underline + explanation
//// ```

// SPDX-License-Identifier: Apache-2.0

import diagnostics/diagnostic.{
  type Diagnostic, type Importance, type Label, type Severity, type Verbosity,
  Primary, Secondary,
}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import utilities/colour.{type Output}
import utilities/location

pub type Sources =
  Dict(String, String)

const tab_width = 4

const max_continuation_lines = 3

pub fn render(
  diagnostic: Diagnostic,
  sources: Sources,
  output: Output,
) -> String {
  let blocks = group_by_file(diagnostic.labels)
  let width = gutter_width(blocks)
  let evidence = case
    list.map(blocks, render_block(_, width, sources, diagnostic, output))
  {
    [] -> ""
    [only] -> "\n" <> only
    many -> "\n\n" <> string.join(many, "\n\n")
  }
  let conclusion = case diagnostic.conclusion {
    "" -> ""
    conclusion -> "\n\n" <> conclusion
  }
  let notes =
    diagnostic.notes
    |> list.map(fn(note) {
      "\n\n"
      <> colour.paint("note:", colour.diagnostic_note, output)
      <> " "
      <> note
    })
    |> string.concat
  let suggestions =
    diagnostic.suggestions
    |> list.map(fn(suggestion) {
      "\n\n"
      <> colour.paint("help:", colour.diagnostic_help, output)
      <> " "
      <> suggestion
    })
    |> string.concat

  title(diagnostic, output)
  <> evidence
  <> conclusion
  <> notes
  <> suggestions
  <> "\n"
}

/// Render a group of diagnostics using their source map and chosen output style.
///
/// ```text
/// same diagnostics -> ANSI terminal text or equivalent plain text
/// ```
pub fn render_all(
  diagnostics: List(Diagnostic),
  sources: Sources,
  output: Output,
  verbosity: Verbosity,
) -> String {
  let shown =
    diagnostics
    |> diagnostic.visible(verbosity)
    |> diagnostic.sort
  case shown {
    [] -> ""
    _ -> {
      let body =
        shown
        |> list.map(render(_, sources, output))
        |> string.join("\n")
      case diagnostic.summary(shown) {
        "" -> body
        summary ->
          body
          <> "\n"
          <> colour.paint(summary, colour.diagnostic_title, output)
          <> "\n"
      }
    }
  }
}

pub fn render_in(
  diagnostic: Diagnostic,
  path: String,
  source: String,
  output: Output,
) -> String {
  render(diagnostic, dict.from_list([#(path, source)]), output)
}

fn title(diagnostic: Diagnostic, output: Output) -> String {
  colour.paint(
    diagnostic.severity_name(diagnostic.severity),
    severity_style(diagnostic.severity),
    output,
  )
  <> colour.paint(": " <> diagnostic.title, colour.diagnostic_title, output)
}

fn severity_style(severity: Severity) -> String {
  case severity {
    diagnostic.ErrorSeverity -> colour.diagnostic_error
    diagnostic.WarningSeverity -> colour.diagnostic_warning
    diagnostic.NoticeSeverity -> colour.diagnostic_notice
  }
}

fn label_style(severity: Severity, importance: Importance) -> String {
  case importance {
    Primary -> severity_style(severity)
    Secondary -> colour.diagnostic_secondary
  }
}

type Block {
  Block(path: String, labels: List(Label))
}

fn group_by_file(labels: List(Label)) -> List(Block) {
  let first_path =
    labels
    |> list.find(fn(label) { label.importance == Primary })
    |> fn(found) {
      case found {
        Ok(label) -> Ok(label)
        Error(Nil) -> list.first(labels)
      }
    }
    |> option.from_result
    |> option.map(fn(label) { label.location.path })
  labels
  |> list.map(fn(label) { label.location.path })
  |> list.unique
  |> move_to_front(first_path)
  |> list.map(fn(path) {
    let in_file =
      labels
      |> list.filter(fn(label) { label.location.path == path })
      |> list.sort(fn(first, second) {
        location.compare(first.location.span, second.location.span)
      })
    Block(path:, labels: in_file)
  })
}

fn move_to_front(paths: List(String), first: Option(String)) -> List(String) {
  case first {
    None -> paths
    Some(path) -> [path, ..list.filter(paths, fn(other) { other != path })]
  }
}

type Segment {
  Segment(line: Int, start: Int, width: Int, message: String, style: String)
}

fn gutter_width(blocks: List(Block)) -> Int {
  let largest =
    blocks
    |> list.flat_map(fn(block) { block.labels })
    |> list.fold(1, fn(largest, label) {
      int.max(largest, label.location.span.end.line)
    })
  string.length(int.to_string(largest)) + 1
}

fn render_block(
  block: Block,
  width: Int,
  sources: Sources,
  diagnostic: Diagnostic,
  output: Output,
) -> String {
  let pad = string.repeat(" ", width)
  let frame = fn(text) { colour.paint(text, colour.diagnostic_gutter, output) }
  let file = fn(text) { colour.paint(text, colour.diagnostic_location, output) }

  let header_label = case
    list.find(block.labels, fn(label) { label.importance == Primary })
  {
    Ok(label) -> Ok(label)
    Error(Nil) -> list.first(block.labels)
  }
  let header = case header_label {
    Ok(label) ->
      pad <> frame("╭─") <> " " <> file(location.label(label.location))
    Error(Nil) -> pad <> frame("╭─") <> " " <> file(block.path)
  }
  case dict.get(sources, block.path) {
    Error(Nil) -> header
    Ok(source) ->
      string.join(
        [
          header,
          pad <> frame("│"),
          render_lines(block, source, width, diagnostic.severity, output),
          pad <> frame("╰─"),
        ],
        "\n",
      )
  }
}

fn render_lines(
  block: Block,
  source: String,
  width: Int,
  severity: Severity,
  output: Output,
) -> String {
  let segments = list.flat_map(block.labels, segments_for(_, source, severity))
  let frame = fn(text) { colour.paint(text, colour.diagnostic_gutter, output) }
  let pad = string.repeat(" ", width)
  let shown = lines_to_show(block.labels)

  shown
  |> list.zip([0, ..shown])
  |> list.flat_map(fn(pair) {
    let #(number, previous) = pair
    let gap = case previous != 0 && number - previous > 1 {
      True -> [pad <> frame("·")]
      False -> []
    }
    let text = expand_tabs(location.line(source, number))
    let number_cell = pad_right(int.to_string(number), width)

    let source_row = case text {
      "" -> frame(number_cell <> "│")
      _ -> frame(number_cell <> "│") <> " " <> text
    }
    let marker_rows =
      segments
      |> list.filter(fn(segment) { segment.line == number })
      |> list.sort(fn(first, second) { int.compare(first.start, second.start) })
      |> clamp_overlaps
      |> marker_rows(output)
      |> list.map(fn(row) { pad <> frame("│") <> " " <> row })
    list.flatten([gap, [source_row], marker_rows])
  })
  |> string.join("\n")
}

fn lines_to_show(labels: List(Label)) -> List(Int) {
  labels
  |> list.flat_map(fn(label) {
    let first = label.location.span.start.line
    let last = label.location.span.end.line
    let leading_end = int.min(last, first + max_continuation_lines - 1)
    let leading = ascending(first, leading_end)
    case last > leading_end {
      True -> list.append(leading, [last])
      False -> leading
    }
  })
  |> list.unique
  |> list.sort(int.compare)
  |> fill_single_line_gaps
}

fn fill_single_line_gaps(lines: List(Int)) -> List(Int) {
  case lines {
    [first, second, ..rest] if second - first == 2 -> [
      first,
      first + 1,
      ..fill_single_line_gaps([second, ..rest])
    ]
    [first, ..rest] -> [first, ..fill_single_line_gaps(rest)]
    [] -> []
  }
}

fn segments_for(
  label: Label,
  source: String,
  severity: Severity,
) -> List(Segment) {
  let span = label.location.span
  let style = label_style(severity, label.importance)
  let first_text = location.line(source, span.start.line)
  let start = display_column(first_text, span.start.column)
  case location.is_multiline(span) {
    False -> {
      let end = display_column(first_text, span.end.column)
      [
        Segment(
          span.start.line,
          start,
          int.max(1, end - start),
          label.message,
          style,
        ),
      ]
    }
    True -> {
      let first_end = display_column(first_text, string.length(first_text) + 1)
      let last_text = location.line(source, span.end.line)
      let last_start = leading_indent(last_text)
      let last_end = display_column(last_text, span.end.column)
      [
        Segment(
          span.start.line,
          start,
          int.max(1, first_end - start),
          label.message,
          style,
        ),
        Segment(
          span.end.line,
          last_start,
          int.max(1, last_end - last_start),
          "",
          style,
        ),
      ]
    }
  }
}

fn clamp_overlaps(segments: List(Segment)) -> List(Segment) {
  clamp_loop(segments, 0, [])
}

fn clamp_loop(
  segments: List(Segment),
  cursor: Int,
  done: List(Segment),
) -> List(Segment) {
  case segments {
    [] -> list.reverse(done)
    [segment, ..rest] -> {
      let start = int.max(segment.start, cursor)
      let end = int.max(segment.start + segment.width, start + 1)
      let clamped = Segment(..segment, start:, width: end - start)
      clamp_loop(rest, end, [clamped, ..done])
    }
  }
}

fn marker_rows(segments: List(Segment), output: Output) -> List(String) {
  case segments {
    [] -> []
    [_, ..] -> {
      let with_messages =
        list.filter(segments, fn(segment) { segment.message != "" })
      let message_rows =
        with_messages
        |> list.reverse
        |> list.map(message_row(with_messages, _, output))
      [underline_row(segments, output), ..message_rows]
    }
  }
}

fn underline_row(segments: List(Segment), output: Output) -> String {
  let #(row, _) =
    list.fold(segments, #("", 0), fn(state, segment) {
      let #(row, cursor) = state
      let bar = case segment.message {
        "" -> string.repeat("─", segment.width)
        _ -> {
          let middle = segment.width / 2
          string.repeat("─", middle)
          <> "┬"
          <> string.repeat("─", segment.width - middle - 1)
        }
      }
      #(
        row
          <> string.repeat(" ", segment.start - cursor)
          <> colour.paint(bar, segment.style, output),
        segment.start + segment.width,
      )
    })
  row
}

fn message_row(
  segments: List(Segment),
  target: Segment,
  output: Output,
) -> String {
  let #(row, _) =
    list.fold(segments, #("", 0), fn(state, segment) {
      let #(row, cursor) = state
      let column = segment.start + segment.width / 2
      case segment.start < target.start, segment == target {
        True, _ -> #(
          row
            <> string.repeat(" ", column - cursor)
            <> colour.paint("│", segment.style, output),
          column + 1,
        )
        False, True -> #(
          row
            <> string.repeat(" ", column - cursor)
            <> colour.paint("╰─ " <> segment.message, segment.style, output),
          column + 3,
        )
        False, False -> #(row, cursor)
      }
    })
  row
}

fn expand_tabs(text: String) -> String {
  string.replace(text, each: "\t", with: string.repeat(" ", tab_width))
}

fn display_column(text: String, column: Int) -> Int {
  let graphemes = string.to_graphemes(text)
  let before = list.take(graphemes, int.max(0, column - 1))
  let missing = int.max(0, column - 1 - list.length(graphemes))
  list.fold(before, missing, fn(total, grapheme) {
    case grapheme {
      "\t" -> total + tab_width
      _ -> total + 1
    }
  })
}

fn leading_indent(text: String) -> Int {
  let indent = string.length(text) - string.length(string.trim_start(text))
  display_column(text, indent + 1)
}

fn pad_right(text: String, width: Int) -> String {
  text <> string.repeat(" ", int.max(1, width - string.length(text)))
}

fn ascending(first: Int, last: Int) -> List(Int) {
  case first > last {
    True -> []
    False -> [first, ..ascending(first + 1, last)]
  }
}
