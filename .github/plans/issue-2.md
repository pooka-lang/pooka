# Preserve signatures while reporting body errors

Planned work for #2. Implementation has not started.

Keep usable declared function signatures when a function body contains an error.

- Avoid derivative member-access errors at correct call sites.
- Keep independent errors visible.
- Cover text and JSON diagnostic output.
