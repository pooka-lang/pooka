//// Put a modest clock beside the workshop bench.
////
//// Read monotonic time for elapsed work and format durations for people. Elapsed
//// measurements do not need wall-clock dates or timezone arithmetic.
////
//// ```text
//// elapsed microseconds -> a readable duration
//// ```

// SPDX-License-Identifier: Apache-2.0

import gleam/int
import gleam/time/timestamp

pub fn now() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1_000_000 + nanoseconds / 1000
}

/// Render elapsed time using units appropriate to the measured size.
///
/// ```text
/// elapsed microseconds -> a readable duration, not a wall-clock timestamp
/// ```
pub fn format(microseconds: Int) -> String {
  let microseconds = int.max(0, microseconds)
  case microseconds < 1000, microseconds < 100_000 {
    True, _ -> int.to_string(microseconds) <> "µs"
    False, True -> decimal(microseconds, 1000) <> "ms"
    False, False -> decimal(microseconds, 1_000_000) <> "s"
  }
}

fn decimal(value: Int, unit: Int) -> String {
  let hundredths = value * 100 / unit
  let whole = hundredths / 100
  let fraction = hundredths % 100
  int.to_string(whole)
  <> "."
  <> case fraction < 10 {
    True -> "0" <> int.to_string(fraction)
    False -> int.to_string(fraction)
  }
}
