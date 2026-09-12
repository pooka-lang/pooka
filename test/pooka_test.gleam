//// Open the test-room door.
////
//// This is the Gleam test entry point. Gleeunit discovers and runs the
//// compiler's test modules; individual fixtures and their explanations live in
//// the neighbouring files.
////
//// ```sh
//// gleam test
//// ```

import gleeunit

// Let gleeunit discover the suite; this entry point carries no separate
// fixture state.
pub fn main() -> Nil {
  gleeunit.main()
}
