//// Report the work that actually happened.
////
//// Exercise progress callbacks around dependency operations. The reported
//// completion must carry the real success or failure, rather than optimistic
//// text printed before the operation has answered.

import tools/progress

@external(erlang, "pooka_progress_ffi", "run")
fn download(name: String, run: fn() -> a) -> a

// The progress event must carry the operation's actual result. A failing
// callback should not be dressed in a successful completion report.
pub fn progress_reports_each_operation_and_its_real_result_test() {
  let #(result, events) =
    progress.record(fn() {
      let one = download("one (git)", fn() { Ok(42) })
      let two = download("two-1.0.0.tar", fn() { Error("offline") })
      #(one, two)
    })
  assert result == #(Ok(42), Error("offline"))
  assert events
    == [
      "Downloading one (git)",
      "Downloaded one (git)",
      "Downloading two-1.0.0.tar",
      "Failed two-1.0.0.tar",
    ]
}
