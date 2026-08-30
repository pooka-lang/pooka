//// Let long errands report that they are still walking.
////
//// Expose scoped dependency-download progress and a deterministic event recorder.
//// The Erlang side owns spinner lifetime and restores the previous reporting
//// scope.
////
//// ```text
//// Downloading helper -> Downloaded helper
//// ```

// SPDX-License-Identifier: Apache-2.0

@external(erlang, "pooka_progress_ffi", "with_reporting")
pub fn with_reporting(coloured: Bool, run: fn() -> a) -> a

@external(erlang, "pooka_progress_ffi", "record")
pub fn record(run: fn() -> a) -> #(a, List(String))
