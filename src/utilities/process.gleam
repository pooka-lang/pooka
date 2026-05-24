//// The last door closes only at the executable boundary.
////
//// Expose process exit through a narrow Erlang call. Library and command code
//// should return an outcome before this operation ends the VM.
////
//// ```text
//// process.exit(1) -> unsuccessful command status
//// ```

// SPDX-License-Identifier: Apache-2.0

@external(erlang, "erlang", "halt")
pub fn exit(status: Int) -> a
