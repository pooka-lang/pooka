# Frequently asked questions

Questions people ask at the door, usually while taking their boots off.

## What is Pooka?

A statically typed programming language for the BEAM, the virtual machine that runs Erlang, Elixir and Gleam. It has immutable classes, interfaces, enums, pattern matching, actors and `Result`-based errors. The compiler is written in Gleam and produces ordinary BEAM modules.

## Why is it called Pooka?

In Irish folklore, a pooka is a shape-shifter: a horse at midnight, a goat by the river, never quite one thing. Pooka values change shape too. A `Fox` can travel as a `Creature`, and a `Moon` can stand in for anything `Glowing`. The compiler keeps track of what each one really is.

## Is Pooka object-oriented or functional?

A little of both, in a BEAM-shaped way. Classes, inheritance and interfaces give things names and families. But objects never change once made, functions are values, and most code is pattern matching and small functions passing results along. The only things that change are actors, and they change only on the inside.

## Can I change a variable?

No. A name, once given, keeps its value. You can make a new name with the same spelling (`let cups = cups + 1`), but the old value stays as it was. For state that really changes over time, such as a counter or a connection, use an [actor](pooka_tour.md#chapter-6-actors-the-ones-with-mailboxes). Inside an actor, `var` fields can change.

## Where is `if`?

Pooka has no `if` expression. Use `match` on a `Bool`:

```pooka
match cups > 0 {
  True -> "pour"
  False -> "boil the kettle"
}
```

`if` does appear in one place: as a guard in a `match` branch, like `n if n < 0 -> ...`.

## Can several patterns share a match branch?

Yes. Write `#(True, _) | #(_, True) -> True` to give them one doorway. Every alternative must bind the same names with compatible types. A guard runs once after the first matching alternative; if it says `False`, Pooka moves to the next branch.

## Why does `1 + 2.0` fail?

Pooka does not guess which kind of number you meant. Convert one side yourself, with `int.to_float` or `float.round`. Division is the one exception: `/` accepts any mix of numbers.

## Why is `4 / 2` equal to `2.0`?

As in Python 3, `/` always gives a `Float`, so `7 / 2` is `3.5`. The compiler has to know the type of an answer before the program runs, before it knows whether the numbers divide evenly, so it cannot be an `Int` some days and a `Float` on others. For whole-number division, use `int.divide(7, 2)`, which gives `Ok(3)`.

## Is there `null`?

No. A value that might be missing is an `Option`: `Some(value)` or `None`. The compiler makes sure you handle both.

## Are there exceptions?

Things that can fail return a `Result`, `Ok(value)` or `Error(reason)`, and `?` passes errors up to the caller. For problems that should never happen, `panic`, `let assert` and `assert` stop the program with a message. See [When things go wrong](pooka_tour.md#chapter-7-when-things-go-wrong).

## Is there a testing framework?

Not built in, on purpose. The compiler provides `test`, `test skip` and `assert`, and you can use any library you like inside a test. See [Testing](pooka_testing.md).

## Can I use Erlang, Elixir or Gleam code from Pooka?

Yes. Declare the functions with `external`, and Pooka will call them. You can also keep your own `.erl`, `.ex`, `.gleam` or `.lfe` files in the project's `ffi/` folder. See [BEAM interop](beam_interop.md).

## Can Erlang, Elixir or Gleam use Pooka code?

Yes. Pooka compiles to ordinary BEAM modules with predictable names, and published packages include their generated Erlang, so rebar3, Mix and Gleam can build them without Pooka installed. See [BEAM interop](beam_interop.md).

## How does Pooka compare to Gleam?

They are neighbours, and Pooka is built with Gleam. Both are statically typed, both run on the BEAM, and their `Result` and `Option` values are the same on the inside. Pooka adds classes with inheritance, interfaces, enums and actors as part of the language, and uses `+` for joining strings. Gleam keeps to custom types and functions, and has a larger, more mature ecosystem. Use whichever feels like home. They can call each other.

## What does Pooka compile to?

BEAM bytecode. The compiler builds Erlang abstract forms and compiles them directly, without writing Erlang source files first. When you publish a package, it also writes the generated Erlang source, so other build tools can use it.

## Which platforms does it run on?

Anywhere Erlang/OTP 29 runs. The compiler is a single escript, and each release is checked on Linux, macOS and Windows, and on several more architectures in containers, including 32-bit and big-endian systems.

## Is there editor support?

A Tree-sitter grammar and a Zed extension are in progress, and a language server is planned. Until then, `pooka check --json` gives editors and tools machine-readable diagnostics.

## Is Pooka ready for production?

Pooka is at version 0.1.0. It is young. The compiler is well tested, but the language and the standard library may still change between versions. Try it, build things with it, and tell us what breaks.

## Where do I report a bug or ask a question?

Open an issue on [GitHub](https://github.com/pooka-lang/pooka/issues). A small piece of code that shows the problem is the most helpful gift you can bring.

## What licence does Pooka use?

The compiler and the standard library are licensed under [Apache 2.0](https://github.com/pooka-lang/pooka/blob/main/LICENSE).
