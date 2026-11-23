//// Adapt the compiler's project reports to an offline editor session.

// SPDX-License-Identifier: Apache-2.0

import builder/check
import builder/infer
import diagnostics/diagnostic
import diagnostics/json
import filepath
import gleam/dict
import gleam/result
import project/package
import project/project
import project/project_error

pub fn workspace(path: String) -> Result(String, Nil) {
  project.find_root(filepath.directory_name(path))
  |> result.map_error(fn(_) { Nil })
}

pub fn diagnostics(root: String, sources: List(#(String, String))) -> String {
  let report = {
    use loaded <- result.try(project.load(root))
    use graph <- result.try(package.resolve_offline(loaded))
    check.check_graph_with_overlays(graph, True, dict.from_list(sources))
  }
  let diagnostics = case report {
    Error(error) -> [project_error.to_diagnostic(error)]
    Ok(checked) ->
      case infer.preview_in_memory(checked) {
        Ok(report) -> report.diagnostics
        Error(infer.InvalidProgram(checked)) -> check.diagnostics(checked)
        Error(infer.UnsupportedSource(path, feature)) ->
          check.display_diagnostics(checked, [
            infer.unsupported_diagnostic(path, feature),
          ])
        Error(infer.ProjectFailed(error)) -> [
          project_error.to_diagnostic(error),
        ]
      }
  }
  json.render(diagnostics, diagnostic.Quiet)
}
