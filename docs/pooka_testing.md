# Testing

Pooka does not come with a testing framework.

This is on purpose. It is not that we forgot to pack one. We left the room empty so you could furnish it yourself.

What the compiler does give you is small and sturdy: a way to declare a test, a way to skip one, and `assert`. Inside a test you can write any Pooka you like, which means a testing library is just an ordinary package. Use a tiny one, a large one, or the one you wrote last Tuesday because none of the others felt right.

> A test is a promise written down while you still remember why you made it.

## Where tests live

Tests live in files ending in `.spec.pooka`, inside the `test` folder:

```text
test/
  main.spec.pooka
  lantern.spec.pooka
  library/shelf.spec.pooka
```

`pooka test` finds them all. Production builds, `pooka export` and published packages leave them out.

A `test` declaration in an ordinary `.pooka` file is an error, even if the test is skipped. This keeps tests from slipping quietly into the code you ship.

## Writing a test

```pooka
module lantern_test

import lantern

test "a lantern lights the room it is in" {
  assert lantern.light("attic") == "A lantern glows in the attic."
}

test "oil becomes minutes" {
  let minutes = lantern.burn_time(100)
  assert minutes == Ok(20.0) as "100 ml should last twenty minutes"
}
```

- `test` is followed by a name, as a string, and a block.
- A spec file is an ordinary module. Import what you need, and write helper functions or classes next to your tests if they make things clearer.
- `assert` checks that something is `True`. Add `as "..."` to say what you expected, in your own words.

A test passes if its block finishes. It fails if anything inside it stops the program: a failing `assert`, a `let assert` that does not match, a `panic`, or a `todo`.

## Skipping a test

```pooka
test skip "speaks Welsh" {
  assert lantern.light("atig") == "Mae llusern yn tywynnu yn yr atig."
}
```

`test skip` keeps the test, but does not run it. It is still type-checked, so it cannot quietly rot while it waits. Use it for work in progress, or for a test that is waiting for something else to be fixed.

## Running tests

```sh
pooka test
```

```text
  Running tests...

  • test module: lantern_test

  ✓ a lantern lights the room it is in
  ✗ oil becomes minutes
      assertion failed: 100 ml should last twenty minutes
      expected Ok(20.0)
      got Ok(19.5)
      test/lantern.spec.pooka:11

  - speaks Welsh (skipped)

  3 tests, 1 passed, 1 failed, 1 skipped

  Finished in 0.39s
```

When an `assert` compares two values with `==`, the failure shows both sides, so you can see what went wrong without adding `echo` everywhere.

| Command | What you see |
| --- | --- |
| `pooka test` | Every test, grouped by module |
| `pooka test --verbose` | Also timings, anything the tests printed, and stack traces |
| `pooka test --compact` | Only the failures and the totals |

`pooka test` exits with status `1` if any test fails, so CI notices too. Projects made with `pooka new` already run it on GitHub, in `.github/workflows/test.yml`.

## Bring your own library

Because a test is ordinary code, a testing library is an ordinary package. Here is a very small one, called `expect`:

```pooka
//// Small, friendly assertions for Pooka tests.

module expect

import pooka/string

/// Fail the test unless `found` equals `expected`.
equal(found: a, expected: a) -> Nil {
  match found == expected {
    True -> Nil
    False -> panic as "the values are not equal"
  }
}

/// Fail the test unless `text` contains `part`.
contains(text: String, part: String) -> Nil {
  match string.contains(text, part) {
    True -> Nil
    False -> panic as "\"" + text + "\" does not contain \"" + part + "\""
  }
}
```

Add it as a development dependency, so it is used by your tests and left out of everything else:

```sh
pooka add expect --dev --path ../expect
```

Then use it in your tests, in whatever style you like:

```pooka
module style_test

import expect
import lantern

test "the attic is mentioned" {
  lantern.light("attic") |> expect.contains("attic")
}

test "the cellar is not" {
  lantern.light("attic") |> expect.contains("cellar")
}
```

```text
  ✓ the attic is mentioned
  ✗ the cellar is not
      panic: "A lantern glows in the attic." does not contain "cellar"
      test/style.spec.pooka:11
```

Whatever the library does, the rule stays the same: if the test block finishes, the test passes. If something stops it, the test fails, and the message is shown. A library can offer pipes, matchers, snapshots, property tests, or something nobody has thought of yet. Pooka will run it all the same.

Publish your library on Hex if you think someone else might like it. The next person to test something at midnight will be grateful.
