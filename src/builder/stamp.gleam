//// Remember what entered the oven, not merely when it arrived.
////
//// Fingerprint source and build inputs for incremental compilation. Separate
//// package and foreign-tool keys so changing one input invalidates the work that
//// actually depends on it.
////
//// ```text
//// same inputs -> same key; changed source -> a different key
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/dict
import gleam/result
import project/package.{type Graph}

pub type Snapshot {
  Snapshot(
    key: BitArray,
    packages: List(#(String, BitArray)),
    foreign: List(#(String, BitArray)),
  )
}

/// Fingerprint the build inputs needed for a reusable package stamp.
///
/// ```text
/// source bytes + manifest + toolchain inputs -> build snapshot
/// ```
@external(erlang, "pooka_incremental_ffi", "snapshot")
pub fn snapshot(graph: Graph, mode: String) -> Result(Snapshot, Nil)

pub fn package_key(snapshot: Result(Snapshot, Nil), name: String) -> BitArray {
  snapshot
  |> result.try(fn(value) { dict.get(dict.from_list(value.packages), name) })
  |> result.unwrap(<<>>)
}

@external(erlang, "pooka_incremental_ffi", "digest")
pub fn digest(bits: BitArray) -> BitArray

pub fn foreign_key(snapshot: Result(Snapshot, Nil), name: String) -> BitArray {
  snapshot
  |> result.try(fn(value) { dict.get(dict.from_list(value.foreign), name) })
  |> result.unwrap(<<>>)
}
