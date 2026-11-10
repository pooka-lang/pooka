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

@external(erlang, "pooka_package_ffi", "download_name")
fn download_name(url: String) -> String

pub fn hex_downloads_use_package_names_instead_of_archive_names_test() {
  assert download_name("https://repo.hex.pm/tarballs/pooka_stdlib-0.1.0.tar")
    == "pooka_stdlib"
  assert download_name(
      "https://repo.hex.pm/tarballs/my_long_package-1.2.3-rc.1.tar",
    )
    == "my_long_package"
  let #(_, events) =
    progress.record(fn() {
      download(
        download_name("https://repo.hex.pm/tarballs/pooka_stdlib-0.1.0.tar"),
        fn() { Ok(Nil) },
      )
    })
  assert events == ["Downloading pooka_stdlib", "Downloaded pooka_stdlib"]
}
