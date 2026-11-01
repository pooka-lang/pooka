# pooka.toml

Every Pooka project keeps a small card by the door called `pooka.toml`. It says what the project is called, which version it is, and who it depends on. Pooka finds a project by looking for this file in the current folder, then in each parent folder.

Here is a complete one, with every section filled in:

```toml
name = "night_library"
version = "1.2.0"

description = "A catalogue for books read after midnight"
authors = ["Peregrine Finch"]
licences = ["Apache-2.0"]
repository = { type = "github", user = "your-name", repo = "night_library" }
links = [
  { title = "Website", href = "https://example.com" },
]

[dependencies]
pooka_stdlib = ">= 0.1.0 and < 1.0.0"
helper = { path = "../helper" }
parser = { git = "https://github.com/your-name/parser", tag = "v1.0.0" }

[dev-dependencies]
test_helpers = { path = "../test_helpers" }

[[documentation.pages]]
title = "Guide"
path = "guide.html"
source = "docs/guide.md"
```

Only `name` and `version` are required. Everything else is optional. `pooka new` writes a file with the optional parts commented out, so you can switch them on by removing the `#`.

## The package

| Key | Meaning |
| --- | --- |
| `name` | The package name. Lowercase letters, digits and underscores, starting with a letter. Required. |
| `version` | The version, as `major.minor.patch`, for example `1.2.0`. Required. |
| `description` | One line about the package, shown on Hex and in the documentation. Needed to publish. |
| `authors` | The people who made it. See below. |
| `licences` | A list of [SPDX licence identifiers](https://spdx.org/licenses/), such as `["Apache-2.0"]` or `["MIT"]`. Needed to publish. |
| `repository` | Where the source code lives. See below. |
| `links` | Extra links for Hex and the documentation sidebar. See below. |

### authors

```toml
authors = ["Peregrine Finch", "Ada <ada@example.org>"]
```

A list of names, one string each. Add an email or a handle if you like; the text is shown as written. The front page of the documentation credits them in this order: *By Peregrine Finch, Ada <ada@example.org>*.

It is always a list, even for one person: `authors = ["Peregrine Finch"]`. Every name deserves its own place in the queue.

### repository

```toml
repository = { type = "github", user = "your-name", repo = "night_library" }
```

`type` can be `github`, `gitlab`, `bitbucket`, `codeberg`, `sourcehut` or `tangled`, each with `user` and `repo`. For your own Gitea or Forgejo server, add `host`:

```toml
repository = { type = "forgejo", host = "https://git.example.com", user = "your-name", repo = "night_library" }
```

For anything else, use `custom` with a `url`:

```toml
repository = { type = "custom", url = "https://example.com/night_library" }
```

The repository appears as the first link in your documentation and on Hex.

### links

A list of titles and addresses:

```toml
links = [
  { title = "Website", href = "https://example.com" },
  { title = "Issues", href = "https://github.com/your-name/night_library/issues" },
]
```

Or, more briefly, a table from title to address:

```toml
[links]
Website = "https://example.com"
```

Every address must start with `http://` or `https://`.

## Dependencies

`[dependencies]` lists the packages your code uses. `[dev-dependencies]` lists packages only your tests use; they are left out of production builds. You can also spell it `[dev_dependencies]`, but not both in the same file.

The easiest way to add one is `pooka add`, which edits this file for you and keeps your comments. You can also write them by hand.

### From Hex

```toml
[dependencies]
pooka_stdlib = ">= 0.1.0 and < 1.0.0"
```

The text on the right is a version requirement:

| Requirement | Accepts |
| --- | --- |
| `"1.2.0"` or `"== 1.2.0"` | Exactly 1.2.0 |
| `">= 1.2.0"` | 1.2.0 or anything newer |
| `">= 1.2.0 and < 2.0.0"` | Anything from 1.2.0 up to, but not including, 2.0.0 |
| `"~> 1.2"` | 1.2 or newer, but below 2.0.0 |
| `"~> 1.2.0"` | 1.2.0 or newer, but below 1.3.0 |
| `"< 1.0.0 or >= 2.0.0"` | Either range |

A dependency can be marked optional:

```toml
fancy_colours = { version = "~> 1.0", optional = true }
```

### From a local folder

```toml
helper = { path = "../helper" }
```

Useful while you work on two packages side by side.

### From Git

```toml
parser = { git = "https://github.com/your-name/parser", tag = "v1.0.0" }
parser = { git = "https://github.com/your-name/parser", branch = "main" }
parser = { git = "https://github.com/your-name/parser", rev = "4f2a9c1" }
```

Choose one of `tag`, `branch` or `rev`. With none of them, Pooka uses the repository's default branch.

### pooka.lock

When dependencies are resolved, Pooka writes the exact versions into `pooka.lock`. Commit it, so everyone who builds the project gets the same versions. `pooka deps update` looks for newer versions that still fit your requirements.

Packages published on Hex can only depend on other Hex packages. Local and Git dependencies are for working at home.

## Documentation pages

`pooka docs` builds pages from your `///` comments. To add your own guides, list them under `[[documentation.pages]]`, one block per page:

```toml
[[documentation.pages]]
title = "Guide"
path = "guide.html"
source = "docs/guide.md"
```

| Key | Meaning |
| --- | --- |
| `title` | The page's name in the sidebar |
| `path` | The HTML file to create. A simple file name ending in `.html`. |
| `source` | The Markdown file to read, inside the project |

`path` cannot be `index.html`, `style.css` or `docs.js`, or start with `module-`; those names are already taken.

## Native components

A project can include native code, built by your own command and loaded as a [NIF](https://www.erlang.org/doc/system/nif.html):

```toml
[native.fast_math]
build = "zig build"
artifact = "zig-out/lib/fast_math.so"
```

The component lives in `native/fast_math/`. `build` is the command that builds it, run from that folder. The command can write the library to the path in `$POOKA_NATIVE_OUTPUT`, or you can set `artifact` to where it leaves the library, relative to that folder. In Pooka code, declare its functions with `external FastMath from native "fast_math" { ... }`.

Packages with native components cannot be published to Hex yet.

## Tools

The `[tools]` table is a quiet corner for other tools to keep their settings. Pooka itself ignores it.

```toml
[tools.my_linter]
strict = true
```

Each tool gets its own table, so their settings never get mixed up.
