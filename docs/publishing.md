# Publishing to Hex

Sooner or later, a package you made for yourself starts to look useful to someone else. That is the moment to put it on [Hex](https://hex.pm), the package registry the whole BEAM shares.

Publishing is a small act of hospitality. You are leaving a lantern by the road for a stranger. This page helps you check that the lantern is lit, labelled, and not about to set the hedge on fire.

## What gets published

`pooka publish` uploads two things:

1. **The package.** Your Pooka source, plus the Erlang code the compiler generates from it, an `.app.src` file and a `rebar.config`. Because the compiled Erlang is included, the package builds with rebar3, Mix and Gleam too, even on machines without Pooka. Each package carries its own small private runtime, so you never need to publish anything else alongside it.
2. **The documentation.** The same pages `pooka docs` builds, published to HexDocs.

Tests, the `build` folder and hidden files stay at home.

## Before you publish

Hex asks for a few things, and Pooka checks them before anything leaves your machine.

**Describe the package** in `pooka.toml`:

```toml
name = "night_library"
version = "1.0.0"
description = "A catalogue for books read after midnight"
authors = ["Peregrine Finch"]
licences = ["Apache-2.0"]
repository = { type = "github", user = "your-name", repo = "night_library" }
```

- `version` must have three parts, like `1.0.0` or `0.3.1`.
- `description` must not be empty.
- `licences` must use [SPDX identifiers](https://spdx.org/licenses/), such as `Apache-2.0` or `MIT`.
- `authors` is optional. The names are credited on the front page of your documentation on HexDocs.
- `repository` is optional, but it helps people find their way back to you.

**Write a README.** Add a `README.md` that explains what the package does. The one `pooka new` writes is a starting point, and Pooka will not publish it unchanged. A README with nothing in it is not accepted either.

**Use only Hex dependencies.** A published package can depend only on other packages from Hex. Replace any `path` or `git` dependencies before publishing. Development dependencies do not count, because they stay at home.

**No native components, yet.** Packages with `[native.*]` components cannot be published, because their code is built on one particular machine.

The [pooka.toml guide](pooka_toml.md) explains every field.

## Look before you leap

A dry run builds everything and shows you what would be uploaded, without sending anything:

```sh
pooka publish --dry-run
```

```text
Files:
  CHANGELOG.md
  LICENSE
  README.md
  pooka.toml
  rebar.config
  src/night_library.app.src
  src/night_library.pooka
  src/pooka@night_library@night_library.erl
  ...

Package: night_library
Version: 1.0.0
Dependencies:
  pooka_stdlib >= 0.1.0 and < 1.0.0

Prepared build/publish/night_library/night_library-1.0.0.tar
Prepared build/publish/night_library/night_library-1.0.0-docs.tar.gz
```

Read the file list. If something there should not be, it will be public forever. If something is missing, it will be missing for everyone. Versions starting with `0.` get a small note reminding readers that the API may still change.

## Credentials

You need a Hex account and an API key.

1. Create an account at [hex.pm](https://hex.pm/signup).
2. In your account settings on hex.pm, create a key with permission to publish packages.
3. Give the key to Pooka through an environment variable:

```sh
export HEX_API_KEY="your key"
```

`HEXPM_API_KEY` works too. If your account uses two-factor authentication, and Hex asks for a code, set `HEX_OTP` to the current code as well.

Keep the key out of your project files and out of Git. In CI, store it as a secret.

## Publishing

```sh
pooka publish
```

Pooka shows the same preview as a dry run, then asks before it uploads. Say yes, and one command uploads both the package and its documentation. If Hex publishes them directly, Pooka prints where to find them.

New public packages require approval by default. With a publishing key, Hex can stage the package instead of making it public straight away. Pooka still uploads the documentation, so Hex can attach both archives to the same pending release. Pooka prints the approval link; open it, verify with your authenticator, compare the checksums and approve. You do not need to run a second documentation command. A staged upload is accepted, but is not public until approved. See [Hex staged publishing](https://hex.pm/docs/publish#staged-publishing).

If Hex refuses, Pooka shows Hex's own explanation: a name that is already taken, a version that already exists, a key without the right permission.

| Option | When to use it |
| --- | --- |
| `--dry-run` | Build and preview, without uploading |
| `--yes` | Publish without the question, for scripts and CI |
| `--replace` | Replace a version you have just published. Hex only allows this for a short time after publishing. |
| `--docs-only` | Upload the documentation again, without publishing the package. Useful if the documentation upload failed, or if you fixed a typo. |

## After publishing

People can now add your package to their projects:

```sh
pooka add night_library
```

From Erlang, Elixir and Gleam projects, they add it the usual way for their build tool. To call Pooka code from those languages, see [BEAM interop](beam_interop.md).

When you are ready for the next version, change `version` in `pooka.toml` and publish again. A version, once published, belongs to everyone who depends on it. Fix mistakes with a new version, not by rewriting an old one.

— Peregrine Finch
