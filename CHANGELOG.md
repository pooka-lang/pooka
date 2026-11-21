# Changelog

## Unreleased

### Fixed

- Resolve Markdown links from the README and guides to their configured HTML pages, including heading fragments (#64).

- Keep the earlier argument constraint in generic call errors, so conflicting keys and factories point to both arguments (#61). Thanks [Ridderby](https://github.com/Ridderby) for catching this!

- Check immutable container literals against their expected interface types, allowing different implementing classes and actors in annotated lists, nested containers, arguments, and returns (#60).

## 0.3.3 - 2026-11-20

### Fixed

- Let root Git and local dependencies satisfy transitive Hex requirements for the same package, checking every version constraint and retaining the selected source in the lockfile (#58).

- Lower safe match guards as native Erlang clause guards while retaining ordered evaluation for calls, division, string concatenation, and floating-point arithmetic (#55).

- Emit direct calls for unshadowed local functions so Erlang can reuse binary match contexts in recursive scans (#54).

- Compile ordinary unguarded match arms as native Erlang case clauses, avoiding per-arm fallback closures while preserving ordered guarded and alternative matches (#52).

- Build only the dependencies when `pooka run -m` selects a dependency's entry point, by package name or as `package:module`. A development tool such as a code generator now runs while the project it serves does not compile, and no longer waits for that project to compile first. The root project's output is left untouched, and the partial build is never cached.

## 0.3.2

### Fixed

- Forward arguments after `pooka run -m <target>` without requiring `--`, including tool-owned help and option names. Preserve explicit separators and the default program's argument rules.
- Keep generated runtime metadata portable and remove private runtime frames from actor and supervisor crash reports while preserving foreign source frames (#49).
- Report dependency runtime locations using package-qualified source names instead of internal `$package` paths, including exported programs and structured failure terms (#48).

## 0.3.1

### Fixed

- Resolve `pooka run -m <package>` to the package entry point, ignoring modules without a zero-argument `main()` and preserving explicit module selectors.
- Compile Elixir Hex dependencies with Mix using Pooka's resolved dependency graph, and explain when Elixir is missing (#45).
- Preserve native private resources through cached builds and exports, including Elixir runtime applications declared in package metadata.
- Compile root-project foreign test helpers from `test/ffi` during development builds, keeping them out of dependency builds and production exports.
- Keep variables from evaluated bindings monomorphic so one allocated mailbox or storage capability cannot be used with incompatible types; retain polymorphism for syntactic values and fresh factories.

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
