# CLI reference

Everything Pooka does, it does through one command: `pooka`. This page lists every door in the corridor and what is behind it.

```text
pooka <command> [arguments]
```

Run `pooka <command> --help` at any time for a short reminder.

| Command | What it does |
| --- | --- |
| [`new`](#pooka-new) | Create a new project |
| [`run`](#pooka-run) | Build and run `main()` |
| [`test`](#pooka-test) | Build and run the tests |
| [`check`](#pooka-check) | Type-check without building |
| [`build`](#pooka-build) | Compile to BEAM |
| [`format`](#pooka-format) | Format source files |
| [`docs`](#pooka-docs) | Generate documentation |
| [`add`](#pooka-add) | Add a dependency |
| [`remove`](#pooka-remove) | Remove a dependency |
| [`deps`](#pooka-deps) | Download, update and inspect dependencies |
| [`export`](#pooka-export) | Export an escript, shipment or OTP release |
| [`publish`](#pooka-publish) | Publish a package to Hex |
| [`clean`](#pooka-clean) | Remove build files |
| [`version`](#pooka-version) | Print the compiler version |

## pooka new

```text
pooka new <name>
```

Creates a project folder with `pooka.toml`, `src/main.pooka`, a starter test, a README, a `.gitignore` and a GitHub workflow. It never overwrites a folder that already exists.

Names are lowercase letters, digits and underscores, start with a letter, and are at most 64 characters.

```sh
pooka new night_library
```

## pooka run

```text
pooka run [-- <arguments>...]
```

Builds the project and runs `main()` from `src/main.pooka`. Anything after `--` is passed to your program. Input and output go straight to your terminal, and the program's exit status becomes `pooka run`'s exit status.

```sh
pooka run
pooka run -- --name Finch
```

## pooka test

```text
pooka test [--verbose | --compact]
```

Builds the project and runs every `test` in `test/**/*.spec.pooka`. Skipped tests are still type-checked, but not run. See [Testing](pooka_testing.md).

| Option | Effect |
| --- | --- |
| `--verbose` | Also show timings, captured output and stack traces for failures |
| `--compact` | Show only failures and the totals |

## pooka check

```text
pooka check [--verbose] [--json] [--fix]
```

Reads and type-checks the whole project without producing any code. The quickest way to hear what the compiler thinks.

| Option | Effect |
| --- | --- |
| `--verbose` | Include more detail in diagnostics |
| `--json` | Print diagnostics as JSON, for editors and tools |
| `--fix` | Apply the automatic fixes the compiler knows about |

## pooka build

```text
pooka build [--target dev|prod]
```

Compiles the project and its dependencies to BEAM files.

| Target | What it builds | Where |
| --- | --- | --- |
| `dev` (default) | Everything, including tests | `build/dev/erlang` |
| `prod` | The project without tests or dev dependencies. Libraries do not need a `main()`. | `build/prod/erlang` |

Use `--target prod` when you want to hand your compiled code to Erlang, Elixir or Gleam. See [BEAM interop](beam_interop.md).

## pooka format

```text
pooka format [--check] [<file.pooka>...]
```

Formats every source file in the project, or only the files you name. `pooka fmt` is the same command.

| Option | Effect |
| --- | --- |
| `--check` | Report files that need formatting, without changing them. Exits with an error if any do. |

## pooka docs

```text
pooka docs
```

Generates HTML documentation from your `////` and `///` comments, plus any extra pages listed in [`pooka.toml`](pooka_toml.md#documentation-pages). The front page shows your README, and credits the [`authors`](pooka_toml.md#authors) from `pooka.toml`. Open `build/dev/docs/<package>/index.html` in a browser to read it.

## pooka add

```text
pooka add <package[@version]> [options]
```

Adds a dependency to `pooka.toml`, then resolves and downloads it. Without options, the package comes from [Hex](https://hex.pm).

| Option | Effect |
| --- | --- |
| `--dev` | Add it as a development dependency, used only by tests |
| `--path <path>` | Use a package from a local folder |
| `--git <url>` | Use a Git repository |
| `--branch <name>` | With `--git`: follow a branch |
| `--tag <tag>` | With `--git`: use a tag |
| `--rev <commit>` | With `--git`: pin an exact commit |

```sh
pooka add pooka_stdlib
pooka add helper --path ../helper
pooka add parser --git https://github.com/your-name/parser --tag v1.0.0
pooka add test_helpers --dev --path ../test_helpers
```

## pooka remove

```text
pooka remove <package>
```

Removes a dependency from `pooka.toml` and updates `pooka.lock`.

## pooka deps

```text
pooka deps <command>
```

| Command | Effect |
| --- | --- |
| `download` | Download dependencies, keeping the versions in `pooka.lock` |
| `update` | Look for newer versions that still fit `pooka.toml`, and update `pooka.lock` |
| `list` | List the locked packages, without downloading anything |
| `tree` | Show which package depends on which, without downloading anything |

`pooka.lock` records the exact versions you are using, so everyone who builds the project gets the same ones. Commit it to Git.

## pooka export

```text
pooka export <escript | shipment | release>
```

Builds a production version of your program to share or deploy. The project needs a `main()` in `src/main.pooka`.

| Command | What you get | Where |
| --- | --- | --- |
| `escript` | One executable file. The person running it needs Erlang. | `build/<package>` |
| `shipment` | A folder of compiled applications and a start script | `build/shipment` |
| `release` | A complete OTP release | `build/release` |

## pooka publish

```text
pooka publish [options]
```

Prepares your package and its documentation, shows you what will be uploaded, then publishes to Hex after you confirm. See [Publishing](publishing.md).

| Option | Effect |
| --- | --- |
| `--dry-run` | Build the archives and show the preview, without uploading |
| `--yes` | Publish without asking for confirmation |
| `--replace` | Replace a release you just published, within Hex's replacement window |
| `--docs-only` | Upload only the documentation, for a release that already exists |

Credentials come from `HEX_API_KEY` or `HEXPM_API_KEY`. If Hex asks for a two-factor code, set `HEX_OTP`.

## pooka clean

```text
pooka clean
```

Removes the project's `build` folder. Your source, `pooka.toml` and `pooka.lock` stay where they are. The next build starts from scratch.

## pooka version

```text
pooka version
pooka --version
pooka -V
```

Prints the compiler version, for example `pooka 0.1.0`.

## Colours

Pooka colours its output when it is talking to a terminal. Set `NO_COLOR=1` to turn colours off. Output sent to a file or another program is always plain.
