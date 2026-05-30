//// Some readers are editors rather than people.
////
//// Serialize diagnostics and source locations as structured JSON. Preserve
//// severity, identifiers and edit data instead of flattening everything into
//// terminal prose.
////
//// ```text
//// Diagnostic -> machine-readable JSON object
//// ```

// SPDX-License-Identifier: Apache-2.0

import diagnostics/diagnostic.{type Diagnostic}
import gleam/json
import utilities/location.{type Location, type Position}

pub fn render(
  diagnostics: List(Diagnostic),
  verbosity: diagnostic.Verbosity,
) -> String {
  let visible = diagnostics |> diagnostic.visible(verbosity) |> diagnostic.sort
  json.object([
    #("version", json.int(1)),
    #("diagnostics", json.array(visible, encode)),
    #(
      "summary",
      json.object([
        #(
          "errors",
          json.int(diagnostic.count(visible, diagnostic.ErrorSeverity)),
        ),
        #(
          "warnings",
          json.int(diagnostic.count(visible, diagnostic.WarningSeverity)),
        ),
        #(
          "notices",
          json.int(diagnostic.count(visible, diagnostic.NoticeSeverity)),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

fn encode(value: Diagnostic) -> json.Json {
  json.object([
    #("id", json.string(value.id)),
    #("severity", json.string(diagnostic.severity_name(value.severity))),
    #("title", json.string(value.title)),
    #(
      "labels",
      json.array(value.labels, fn(label) {
        json.object([
          #("location", encode_location(label.location)),
          #("message", json.string(label.message)),
          #(
            "importance",
            json.string(case label.importance {
              diagnostic.Primary -> "primary"
              diagnostic.Secondary -> "secondary"
            }),
          ),
        ])
      }),
    ),
    #("conclusion", json.string(value.conclusion)),
    #("notes", json.array(value.notes, json.string)),
    #("suggestions", json.array(value.suggestions, json.string)),
    #(
      "fixes",
      json.array(value.fixes, fn(fix) {
        json.object([
          #("location", encode_location(fix.location)),
          #("replacement", json.string(fix.replacement)),
          #("description", json.string(fix.description)),
          #(
            "applicability",
            json.string(case fix.applicability {
              diagnostic.Automatic -> "automatic"
              diagnostic.Suggested -> "suggested"
              diagnostic.Uncertain -> "uncertain"
            }),
          ),
        ])
      }),
    ),
  ])
}

fn encode_location(value: Location) -> json.Json {
  json.object([
    #("path", json.string(value.path)),
    #("start", encode_position(value.span.start)),
    #("end", encode_position(value.span.end)),
  ])
}

fn encode_position(value: Position) -> json.Json {
  json.object([
    #("line", json.int(value.line)),
    #("column", json.int(value.column)),
    #("byte_offset", json.int(value.byte_offset)),
  ])
}
