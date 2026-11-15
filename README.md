<p align="center">
  <img src="assets/noxy.png" alt="Pooka mascot" width="280" />
</p>

# Pooka

[![Tests](https://img.shields.io/github/actions/workflow/status/pooka-lang/pooka/test.yml?style=for-the-badge&label=tests)](https://github.com/pooka-lang/pooka/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/pooka-lang/pooka?style=for-the-badge&include_prereleases&color=75618E)](https://github.com/pooka-lang/pooka/releases)
[![Licence](https://img.shields.io/badge/licence-Apache--2.0-blue?style=for-the-badge)](LICENSE)

Pooka is a small, statically typed language for the BEAM. It has immutable classes, interfaces, enums, pattern matching, actors and `Result`-based errors, and it gets along well with its neighbours: Erlang, Elixir and Gleam.

## Install

Pooka is one file, `pooka`, and needs Erlang/OTP 29. The [installation guide](https://pooka.run/docs/install/) covers macOS, Linux, Windows and CI.

To build from source, with Gleam installed:

```sh
./install.sh
```

## Quick start

```sh
pooka new lantern
cd lantern
pooka run
pooka test
```

## Documentation

Visit [pooka.run](https://pooka.run/) for the [documentation](https://pooka.run/docs/), [language tour](https://pooka.run/tour/) and [cookbook](https://pooka.run/cookbook/).

The [standard library](https://github.com/pooka-lang/pooka_stdlib) lives in its own repository, with its [API documentation on HexDocs](https://pooka-stdlib.hexdocs.pm/).

## Development

The compiler is written in Gleam.

```sh
gleam test                      # run the compiler's tests
gleam format --check src test   # check formatting
gleam run -- --help             # run the compiler from source
```

Bug reports and ideas are welcome in the [issues](https://github.com/pooka-lang/pooka/issues).

## Licence

Pooka is licensed under the [Apache License, Version 2.0](LICENSE).
