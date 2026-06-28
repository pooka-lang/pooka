//// A small luggage label for an OTP application.
////
//// Render the application resource from the package and its dependencies. Keep
//// module and application names separate: OTP starts applications, while BEAM
//// loads modules.
////
//// ```text
//// package app -> {application, app, Properties}.
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/codegen/beam
import compiler/codegen/forms as f
import gleam/list
import gleam/string
import project/config

pub fn render(name: String, version: String, modules: List(String)) -> String {
  render_with_dependencies(name, version, modules, [])
}

pub fn render_with_dependencies(
  name: String,
  version: String,
  modules: List(String),
  dependencies: List(String),
) -> String {
  render_with_metadata(name, version, modules, dependencies, config.defaults())
}

/// Carry manifest metadata into the OTP application label. An omitted description
/// keeps the conventional fallback; configured text is escaped as an Erlang term.
///
/// ```text
/// description = "A small library" -> {description, "A small library"}
/// ```
pub fn render_with_metadata(
  name: String,
  version: String,
  modules: List(String),
  dependencies: List(String),
  metadata: config.Config,
) -> String {
  let description = case metadata.description {
    "" -> "A Pooka application"
    value -> value
  }
  let modules = modules |> list.unique |> list.sort(string.compare)
  f.Tuple([
    f.Atom("application"),
    f.Atom(name),
    f.Sequence([
      f.Tuple([f.Atom("vsn"), f.Characters(version)]),
      f.Tuple([f.Atom("description"), f.Characters(description)]),
      f.Tuple([f.Atom("modules"), f.Sequence(list.map(modules, f.Atom))]),
      f.Tuple([f.Atom("registered"), f.Sequence([])]),
      f.Tuple([
        f.Atom("applications"),
        f.Sequence(
          list.append(["kernel", "stdlib"], dependencies)
          |> list.unique
          |> list.map(f.Atom),
        ),
      ]),
      ..case metadata.licences {
        [] -> []
        values -> [
          f.Tuple([
            f.Atom("licenses"),
            f.Sequence(list.map(values, f.Characters)),
          ]),
        ]
      }
    ]),
  ])
  |> beam.resource
}
