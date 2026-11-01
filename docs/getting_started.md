# Getting started

Tonight we are going to make a small project, run it, test it, tidy it, and teach it one new trick. It will take about ten minutes, which is roughly the time it takes for a cup of tea to go from *too hot* to *slightly forgotten*.

You will need Pooka installed. If `pooka --version` does not answer yet, the [installation guide](install.md) will get you there.

## 1. Create a project

```sh
pooka new lantern
cd lantern
```

Pooka makes a small house for you:

```text
lantern/
  pooka.toml                  the project's name, version and dependencies
  src/main.pooka              your program
  test/main.spec.pooka        your tests
  README.md
  .gitignore
  .github/workflows/test.yml  runs your tests on GitHub
```

Project names are lowercase, with underscores between words: `lantern`, `night_library`, `owl2`.

## 2. Run it

```sh
pooka run
```

```text
 Compiling pooka_stdlib
 Compiling lantern
  Compiled 23 modules in 0.49s
   Running lantern.main
src/main.pooka:4
"Hello from lantern!"
```

The first run downloads and compiles the standard library, so it takes a moment longer. After that, Pooka only rebuilds what changed.

Here is the program that ran, in `src/main.pooka`:

```pooka
module main

main() {
  echo "Hello from lantern!"
}
```

`echo` prints a value, along with the file and line it came from. It is the quickest way to see what your program is doing.

## 3. Test it

```sh
pooka test
```

```text
  Running tests...

  • test module: main_test

  ✓ one plus one is two

  1 test, 1 passed

  Finished in 94.23ms
```

The test lives in `test/main.spec.pooka`:

```pooka
module main_test

test "one plus one is two" {
  assert 1 + 1 == 2
}
```

Tests live in files ending in `.spec.pooka`, inside the `test` folder. [Testing](pooka_testing.md) has the whole story.

## 4. Format it

```sh
pooka format
```

The formatter rewrites your files in the house style: two spaces of indentation, tidy line breaks, nothing to argue about. To only check, without changing anything, use:

```sh
pooka format --check
```

That is what the GitHub workflow runs. If a file needs formatting, it tells you which one.

## 5. Teach it a new trick

Our lantern does not do much yet. Let us give it a module of its own. Create `src/lantern.pooka`:

```pooka
//// A small lantern for dark rooms.

module lantern

import pooka/int

/// Light a lantern in a room.
light(room: String) -> String {
  "A lantern glows in the " + room + "."
}

/// How many minutes a lantern burns, at 5 ml of oil per minute.
burn_time(oil: Int) -> Result(Float, String) {
  match oil > 0 {
    True -> Ok(oil / 5)
    False -> Error("The lantern needs oil, not " + int.to_string(oil) + " ml.")
  }
}
```

A few things to notice:

- The file is `src/lantern.pooka`, so the module is called `lantern`.
- `////` comments describe the whole module and come before `module`. `///` comments describe the function below them. `pooka docs` turns both into documentation.
- `burn_time` can fail, so it returns a `Result`: `Ok` with the minutes, or `Error` with a polite explanation.
- `/` always gives a `Float`, so the minutes are a `Float` too: 103 ml of oil burns for 20.6 minutes.

Now use it from `src/main.pooka`:

```pooka
module main

import lantern

main() {
  echo lantern.light("attic")
  echo lantern.burn_time(100)
}
```

## 6. Add a test

Create `test/lantern.spec.pooka`:

```pooka
module lantern_test

import lantern

test "a lantern lights the room it is in" {
  assert lantern.light("attic") == "A lantern glows in the attic."
}

test "oil becomes minutes" {
  assert lantern.burn_time(100) == Ok(20.0)
}

test "an empty lantern explains itself" {
  assert lantern.burn_time(0) == Error("The lantern needs oil, not 0 ml.")
}
```

## 7. Check, build, run and test again

First, ask the compiler to read everything through without building:

```sh
pooka check
```

```text
  Checking lantern
   Checked 24 files in 0.11s
```

If something is wrong, `check` points at the line and explains what it expected. It is the fastest way to hear the compiler's opinion.

Then build, run and test:

```sh
pooka build
pooka run
pooka test
```

```text
   Running lantern.main
src/main.pooka:6
"A lantern glows in the attic."
src/main.pooka:7
Ok(20.0)
```

```text
  Running tests...

  • test module: lantern_test

  ✓ a lantern lights the room it is in
  ✓ oil becomes minutes
  ✓ an empty lantern explains itself

  • test module: main_test

  ✓ one plus one is two

  4 tests, 4 passed
```

Four small lights, all on.

## Where to next

- [A tour of Pooka](pooka_tour.md) walks through the whole language, one room at a time.
- [Testing](pooka_testing.md) explains `test`, `test skip` and `assert`.
- [The CLI reference](cli_reference.md) lists every command, including `pooka docs` for documentation and `pooka export` for sharing your program.
- [pooka.toml](pooka_toml.md) explains the project file, and how to add dependencies with `pooka add`.

— Peregrine Finch
