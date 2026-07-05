//// Keep the workshop's short announcements consistent.
////
//// Render aligned activity labels and details using the CLI palette. Return
//// strings rather than printing so command outcomes still control their streams.
////
//// ```text
//// Compiling, Compiled and Checked use Lantern Orange
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/string
import utilities/colour.{type Output}

const width = 10

pub fn activity(label: String, detail: String, output: Output) -> String {
  line(label, colour.bold_lantern_orange, detail, output)
}

pub fn success(label: String, detail: String, output: Output) -> String {
  line(label, colour.bold_lantern_orange, detail, output)
}

pub fn failure(label: String, detail: String, output: Output) -> String {
  line(label, colour.bold_scarf, detail, output)
}

pub fn muted(text: String, output: Output) -> String {
  colour.paint(text, colour.muted, output)
}

fn line(
  label: String,
  style: String,
  detail: String,
  output: Output,
) -> String {
  colour.paint(string.pad_start(label, width, " "), style, output)
  <> " "
  <> detail
  <> "\n"
}
