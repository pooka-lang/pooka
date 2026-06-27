//// A class's suitcase has a fixed arrangement of compartments.
////
//// Describe tuple tags, inherited extension paths and immutable field updates.
//// Read, write and pattern construction must agree on the same layout, even when
//// a field belongs to an ancestor.
////
//// ```text
//// field path [2,3] -> element(3, element(2, Object))
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/codegen/forms as f
import compiler/typesystem/nominal
import compiler/typesystem/unify
import gleam/list

/// List the hierarchy from its root to this class so every layout operation walks
/// the same ancestry order.
///
/// ```text
/// Child is Parent -> [Parent, Child]
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
pub fn chain(state: unify.State, class: nominal.Class) -> List(nominal.Class) {
  unify.ancestors(state, nominal.identity(class))
  |> list.reverse
  |> list.filter_map(unify.class(state, _))
}

/// Count fields declared by this class, excluding inherited fields.
///
/// ```text
/// one inherited field + two own fields -> own_count 2
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn own_count(class: nominal.Class) -> Int {
  list.length(nominal.own_fields(class))
}

/// Locate the child-extension slot after the tag and this level's own fields.
///
/// ```text
/// one own field -> extension index 3
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn extension_index(class: nominal.Class) -> Int {
  own_count(class) + 2
}

/// Map an owned field to its sequence of one-based tuple indexes. Inherited
/// extension tuples require more than a flat field offset.
///
/// ```text
/// [2, 3] -> element(3, element(2, Object))
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
pub fn field_path(state: unify.State, field: nominal.Field) -> List(Int) {
  case unify.class(state, field.owner) {
    Error(Nil) -> [field.index]
    Ok(owner) ->
      case unify.in_hierarchy(state, owner) {
        False -> [field.index]
        True -> {
          let levels = chain(state, owner)
          let through =
            levels
            |> list.take(list.length(levels) - 1)
            |> list.map(extension_index)
          let position =
            list.index_fold(nominal.own_fields(owner), 0, fn(found, own, index) {
              case own.name.name == field.name.name {
                True -> index + 2
                False -> found
              }
            })
          list.append(through, [position])
        }
      }
  }
}

/// Follow the field's tuple path using element/2 calls. Reading an ancestor field
/// uses the ancestor's checked ownership information.
///
/// ```text
/// Object field -> nested erlang:element calls
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
pub fn read(
  state: unify.State,
  field: nominal.Field,
  value: f.Term,
  line: Int,
) -> f.Term {
  list.fold(field_path(state, field), value, fn(value, index) {
    element(index, value, line)
  })
}

/// Replace a field along its path and return the rebuilt object value.
///
/// ```text
/// new object = setelement(Slot, old object, replacement)
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
pub fn write(
  state: unify.State,
  field: nominal.Field,
  value: f.Term,
  replacement: f.Term,
  line: Int,
) -> f.Term {
  write_path(field_path(state, field), value, replacement, line)
}

/// Rebuild each tuple on the path outward after replacing the innermost value. No
/// existing tuple is mutated.
///
/// ```text
/// path [2,3] -> rebuild inner tuple, then outer tuple
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn write_path(
  path: List(Int),
  value: f.Term,
  replacement: f.Term,
  line: Int,
) -> f.Term {
  case path {
    [] -> replacement
    [index, ..rest] ->
      f.remote(
        "erlang",
        "setelement",
        [
          integer(index, line),
          value,
          write_path(rest, element(index, value, line), replacement, line),
        ],
        line,
      )
  }
}

/// Build a tagged object with uninitialized field markers and the hierarchy's
/// extension layout. Construction fills those slots later.
///
/// ```text
/// standalone class -> {ClassTag, '$uninitialized', ...}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
pub fn skeleton(state: unify.State, class: nominal.Class, line: Int) -> f.Term {
  let uninitialized = fn(count) {
    list.repeat(f.atom("$uninitialized", line), count)
  }
  case unify.in_hierarchy(state, class) {
    False ->
      tuple(
        [tag(class, line), ..uninitialized(list.length(class.fields))],
        line,
      )
    True ->
      chain(state, class)
      |> list.reverse
      |> list.fold(f.atom("nil", line), fn(inner, level) {
        tuple(
          list.flatten([
            [tag(level, line)],
            uninitialized(own_count(level)),
            [inner],
          ]),
          line,
        )
      })
  }
}

/// Build a class pattern that admits the appropriate descendant extension layout.
///
/// ```text
/// parent class pattern -> tuple pattern with an open descendant slot
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
pub fn pattern(
  state: unify.State,
  class: nominal.Class,
  elements: List(f.Term),
  line: Int,
) -> f.Term {
  class_pattern(state, class, elements, f.variable("_", line), line)
}

/// Build a class pattern restricted to its exact layout rather than a descendant
/// extension.
///
/// ```text
/// concrete class -> exact tagged tuple pattern
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
pub fn exact_pattern(
  state: unify.State,
  class: nominal.Class,
  elements: List(f.Term),
  line: Int,
) -> f.Term {
  class_pattern(state, class, elements, f.atom("nil", line), line)
}

/// Assemble the class levels and field patterns under the selected exactness
/// policy.
///
/// ```text
/// class tag + ordered field patterns -> tuple pattern
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn class_pattern(
  state: unify.State,
  class: nominal.Class,
  elements: List(f.Term),
  tail: f.Term,
  line: Int,
) -> f.Term {
  case unify.in_hierarchy(state, class) {
    False -> tuple([tag(class, line), ..elements], line)
    True -> {
      let levels = chain(state, class)

      let #(groups, _) =
        list.fold(levels, #([], elements), fn(acc, level) {
          let #(groups, remaining) = acc
          let count = own_count(level)
          #(
            [list.take(remaining, count), ..groups],
            list.drop(remaining, count),
          )
        })
      list.zip(levels, list.reverse(groups))
      |> list.reverse
      |> list.fold(tail, fn(inner, pair) {
        let #(level, own) = pair
        tuple(list.flatten([[tag(level, line)], own, [inner]]), line)
      })
    }
  }
}

/// Select or describe the extension position used when another class level
/// continues the object layout.
///
/// ```text
/// parent tuple -> extension slot -> child tuple
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
pub fn extension(
  state: unify.State,
  class: nominal.Class,
  value: f.Term,
  line: Int,
) -> f.Term {
  chain(state, class)
  |> list.map(extension_index)
  |> list.fold(value, fn(value, index) { element(index, value, line) })
}

/// Emit the qualified class tag as an atom expression.
///
/// ```erlang
/// {atom,1,'pooka@class@module@Class'}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#atomic-literals.
pub fn tag(class: nominal.Class, line: Int) -> f.Term {
  f.atom(nominal.tag(class.runtime_module, class.source.name.name), line)
}

/// Build an abstract tuple expression or tuple pattern from lowered elements.
///
/// ```erlang
/// {tuple,1,[{atom,1,box},{integer,1,42}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
fn tuple(elements: List(f.Term), line: Int) -> f.Term {
  f.node("tuple", line, [f.Sequence(elements)])
}

/// Build a one-based erlang:element/2 call for an object slot.
///
/// ```text
/// element(2, Object) -> remote call abstract node
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
fn element(index: Int, value: f.Term, line: Int) -> f.Term {
  f.remote("erlang", "element", [integer(index, line), value], line)
}

/// Wrap a tuple slot number in an integer-expression node.
///
/// ```erlang
/// {integer,1,2}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#atomic-literals.
fn integer(value: Int, line: Int) -> f.Term {
  f.node("integer", line, [f.Integer(value)])
}
