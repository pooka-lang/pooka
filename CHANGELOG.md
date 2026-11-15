# Changelog

## Unreleased

### Documentation

- Use pooka.run for documentation and installation links; remove the repository documentation directory and the README language example.

## 0.3.0

### Added

- Evaluate rebar configuration scripts in an isolated VM and ignore dependency development-only plugins and hooks, while rejecting unsupported compilation hooks and native build steps (#19).
- Allow package-private main modules in dependencies and select project or dependency entry points with `pooka run -m`, preserving forwarded arguments and diagnosing ambiguous or missing targets (#32).
- Warn when non-final expression statements discard a Result, while keeping explicit discards and returned values quiet (#15).
- Warn before publishing production code that uses the echo builtin, including cached builds and non-interactive publication, without rejecting intentional debug output (#21).
- Allow module functions named `new`, including local calls, imports and function references, while preserving class and actor constructors (#16).
- Guide interactive Hex publication with hidden, per-invocation API keys, bounded authentication retries and explicit verification prompts, preserving completed upload stages and non-interactive CI behaviour (#33).

### Performance

- Ignore unrelated shell variables in ordinary build fingerprints while retaining compiler flags, executable resolution and conservative environment tracking for custom native commands and rebar scripts (#23).
- Compile independent generated BEAM modules and native Erlang sources with bounded workers, retaining source-ordered diagnostics and isolated native compiler state (#27).
- Batch native Erlang sources to avoid starting a compiler VM for every module, preserving first-file order, options and source diagnostics (#24).

### Bug fixes

- Infer shared generic call arguments from their nearest compatible base before checking callback bodies, preserving invariant class arguments, function inputs and captured variables (#12).
- Preserve panic and todo source locations through tail calls, expose them in crash and test reports, and hide compiler-private runtime frames (#29).
- Inspect class hierarchies using checked layouts, displaying the most-derived class and inherited fields without extension padding in echo and test failures (#14).
- Generate API documentation only for the current package, keeping dependency modules and internal `$package` paths out of its pages and navigation.
- Read published native application resources when no `.app.src` exists, preserving metadata and diagnosing invalid resources clearly (#17).
- Reject classes, actors, interfaces and enums that reuse built-in type names, pointing to the declaration before misleading type errors appear (#13).
- Align command activity labels with dependency downloads and format download durations using the same readable units as build times.
- Reuse unchanged native dependencies after application edits by validating staged headers through relocatable cache paths; keep external resource filenames intact (#22).
- Keep incremental snapshots usable when dependency headers are not yet available through compiled application paths, while tracking transitive includes and falling back safely for uncertain inputs (#18).

## 0.2.0

### Added

- Share match arms with pattern alternatives such as `[] | ["--help"] | ["-h"] -> help()`, including guards and compatible bindings (#6).

- Construct lists with spread tails such as `[first, second, ..rest]`, lowered directly to cons cells (#3).

- Read tuple elements with zero-based projections such as `pair.0`, including chained projections and compile-time bounds checks (#4).

### Bug fixes

- Respect explicit local binding annotations during generic inference, including nested containers and destructured patterns (#1).

- Fix misleading “unknown module” diagnostics when an imported module fails to parse (#5).
- Keep declared function signatures available after body errors, avoiding misleading follow-on diagnostics at correct call sites (#2).

## 0.1.0

- Initial release of the Pooka compiler and CLI.
- Licensed under the Apache License, Version 2.0.
