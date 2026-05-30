//// A diagnostic is a concerned note with a precise address.
////
//// Store severity, labels, explanatory text and suggested fixes without choosing
//// a renderer. Builders can add context while keeping the diagnostic identifier
//// stable.
////
//// ```text
//// error + primary span + secondary span + help -> Diagnostic
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/list
import gleam/order
import gleam/string
import utilities/location.{type Location}
import utilities/text

pub type Severity {

  ErrorSeverity

  WarningSeverity

  NoticeSeverity
}

pub type Importance {

  Primary

  Secondary
}

pub type Label {
  Label(location: Location, message: String, importance: Importance)
}

pub type Applicability {

  Automatic

  Suggested

  Uncertain
}

pub type Fix {
  Fix(
    location: Location,
    replacement: String,
    description: String,
    applicability: Applicability,
  )
}

pub type Diagnostic {
  Diagnostic(
    id: String,
    severity: Severity,
    title: String,
    labels: List(Label),
    conclusion: String,
    notes: List(String),
    suggestions: List(String),
    fixes: List(Fix),
  )
}

pub fn new(id: String, severity: Severity, title: String) -> Diagnostic {
  Diagnostic(
    id: id,
    severity: severity,
    title: title,
    labels: [],
    conclusion: "",
    notes: [],
    suggestions: [],
    fixes: [],
  )
}

/// Start an error diagnostic with a stable machine-readable identifier and a
/// human-readable title.
///
/// ```text
/// error("type.unification", "type mismatch") -> an unlabelled diagnostic
/// ```
pub fn error(id: String, title: String) -> Diagnostic {
  new(id, ErrorSeverity, title)
}

pub fn warning(id: String, title: String) -> Diagnostic {
  new(id, WarningSeverity, title)
}

pub fn notice(id: String, title: String) -> Diagnostic {
  new(id, NoticeSeverity, title)
}

pub fn label(
  diagnostic: Diagnostic,
  location: Location,
  message: String,
  importance: Importance,
) -> Diagnostic {
  let label = Label(location:, message:, importance:)
  Diagnostic(..diagnostic, labels: list.append(diagnostic.labels, [label]))
}

/// Attach the principal source location and explanation to a diagnostic value.
///
/// ```text
/// mismatch diagnostic + expression span -> primary underline
/// ```
pub fn primary(
  diagnostic: Diagnostic,
  location: Location,
  message: String,
) -> Diagnostic {
  label(diagnostic, location, message, Primary)
}

/// Add supporting evidence without replacing the primary failure location.
///
/// ```text
/// earlier annotation span -> explanation of the expected type
/// ```
pub fn secondary(
  diagnostic: Diagnostic,
  location: Location,
  message: String,
) -> Diagnostic {
  label(diagnostic, location, message, Secondary)
}

pub fn conclusion(diagnostic: Diagnostic, conclusion: String) -> Diagnostic {
  Diagnostic(..diagnostic, conclusion:)
}

pub fn note(diagnostic: Diagnostic, note: String) -> Diagnostic {
  Diagnostic(..diagnostic, notes: list.append(diagnostic.notes, [note]))
}

pub fn help(diagnostic: Diagnostic, suggestion: String) -> Diagnostic {
  Diagnostic(
    ..diagnostic,
    suggestions: list.append(diagnostic.suggestions, [suggestion]),
  )
}

pub fn fix(
  diagnostic: Diagnostic,
  location: Location,
  replacement: String,
  description: String,
  applicability: Applicability,
) -> Diagnostic {
  let fix = Fix(location:, replacement:, description:, applicability:)
  Diagnostic(..diagnostic, fixes: list.append(diagnostic.fixes, [fix]))
}

pub fn primary_label(diagnostic: Diagnostic) -> Result(Label, Nil) {
  case list.find(diagnostic.labels, fn(label) { label.importance == Primary }) {
    Ok(label) -> Ok(label)
    Error(Nil) -> list.first(diagnostic.labels)
  }
}

pub fn primary_location(diagnostic: Diagnostic) -> Result(Location, Nil) {
  case primary_label(diagnostic) {
    Ok(label) -> Ok(label.location)
    Error(Nil) -> Error(Nil)
  }
}

pub fn has_errors(diagnostics: List(Diagnostic)) -> Bool {
  list.any(diagnostics, fn(diagnostic) { diagnostic.severity == ErrorSeverity })
}

pub fn severity_name(severity: Severity) -> String {
  case severity {
    ErrorSeverity -> "error"
    WarningSeverity -> "warning"
    NoticeSeverity -> "notice"
  }
}

pub fn count(diagnostics: List(Diagnostic), severity: Severity) -> Int {
  list.count(diagnostics, fn(diagnostic) { diagnostic.severity == severity })
}

pub fn sort(diagnostics: List(Diagnostic)) -> List(Diagnostic) {
  list.sort(diagnostics, fn(first, second) {
    case primary_location(first), primary_location(second) {
      Error(Nil), Error(Nil) -> order.Eq
      Error(Nil), Ok(_) -> order.Lt
      Ok(_), Error(Nil) -> order.Gt
      Ok(first), Ok(second) ->
        case string.compare(first.path, second.path) {
          order.Eq -> location.compare(first.span, second.span)
          order.Lt -> order.Lt
          order.Gt -> order.Gt
        }
    }
  })
}

pub type Verbosity {

  Quiet

  Verbose
}

pub fn visible(
  diagnostics: List(Diagnostic),
  verbosity: Verbosity,
) -> List(Diagnostic) {
  case verbosity {
    Verbose -> diagnostics
    Quiet ->
      list.filter(diagnostics, fn(diagnostic) {
        diagnostic.severity != NoticeSeverity
      })
  }
}

pub fn summary(diagnostics: List(Diagnostic)) -> String {
  let errors = count(diagnostics, ErrorSeverity)
  let warnings = count(diagnostics, WarningSeverity)
  case errors, warnings {
    0, 0 -> ""
    _, 0 -> "Found " <> text.counted(errors, "error") <> "."
    0, _ -> "Found " <> text.counted(warnings, "warning") <> "."
    _, _ ->
      "Found "
      <> text.counted(errors, "error")
      <> " and "
      <> text.counted(warnings, "warning")
      <> "."
  }
}
