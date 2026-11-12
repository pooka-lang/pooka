# Respect explicit binding annotations

Planned work for #1. Implementation has not started.

Preserve the declared wider type of an annotated binding during generic inference.

- Apply the annotation before checking generic calls.
- Cover direct bindings and annotations nested in tuples and lists.
- Preserve errors for incompatible initializers.
