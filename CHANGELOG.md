# Changelog

## Unreleased

### Performance

- Compile independent generated BEAM modules and native Erlang sources with bounded workers, retaining source-ordered diagnostics and isolated native compiler state (#27).

- Batch native Erlang sources to avoid starting a compiler VM for every module, preserving first-file order, options and source diagnostics (#24).

### Bug fixes

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
