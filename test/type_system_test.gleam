//// A type variable is a promise with a notebook of reasons.
////
//// Exercise unification, substitution and polymorphic schemes directly,
//// without the parser between us and the constraints. Occurs checks prevent
//// infinite types; rigid variables preserve universal annotations. Conflicts
//// retain earlier provenance, while failed constraints leave their input state
//// unchanged.
////
//// ```text
//// a = List(b), b = Int -> a = List(Int)
//// a = List(a)          -> an infinite type, rejected
//// ```

import birdie
import compiler/typesystem/monotype as types
import compiler/typesystem/scheme
import compiler/typesystem/unify
import diagnostics/diagnostic
import diagnostics/render
import gleam/dict
import gleam/list
import gleam/set
import utilities/colour
import utilities/location

/// Give synthetic constraints two source addresses and a reason. The fixed
/// source lets provenance tests distinguish the earlier definition from the
/// later conflicting use.
fn origin(offset: Int, reason: String) -> unify.Origin {
  let source = "let x = 1\nuse(x)\n"
  unify.Origin(
    location.new("src/main.pooka", location.span(source, 8, 9)),
    location.new("src/main.pooka", location.span(source, offset, offset + 1)),
    reason,
  )
}

pub fn primitive_types_are_distinct_test() {
  let state = unify.new()
  let all = [
    types.IntType,
    types.FloatType,
    types.StringType,
    types.BoolType,
    types.NilType,
    types.BitArrayType,
    types.PidType,
  ]
  list.each(all, fn(expected) {
    list.each(all, fn(found) {
      case expected == found {
        True -> {
          let assert Ok(_) =
            unify.unify(expected, found, origin(1, "same type"), state)
        }
        False -> {
          let assert Error(_) =
            unify.unify(expected, found, origin(1, "different types"), state)
        }
      }
    })
  })
}

pub fn fresh_variables_and_transitive_substitutions_test() {
  let #(a, state) = unify.fresh(unify.new())
  let #(b, state) = unify.fresh(state)
  assert a != b
  let assert Ok(state) = unify.unify(a, b, origin(1, "equal"), state)
  let assert Ok(state) =
    unify.unify(b, types.IntType, origin(2, "integer"), state)
  assert unify.apply(a, state) == types.IntType
  assert unify.apply(types.ListType(b), state) == types.ListType(types.IntType)
}

pub fn self_unification_is_safe_test() {
  let #(a, state) = unify.fresh(unify.new())
  let assert Ok(state) = unify.unify(a, a, origin(1, "same variable"), state)
  assert unify.apply(a, state) == a
}

pub fn occurs_check_rejects_recursive_types_test() {
  let #(a, state) = unify.fresh(unify.new())
  let assert Error(error) =
    unify.unify(a, types.ListType(a), origin(1, "recursive"), state)
  assert error.problem == unify.InfiniteType(0)
  let assert Error(_) =
    unify.unify(
      a,
      types.FunctionType([types.IntType], a),
      origin(1, "recursive function"),
      state,
    )
}

// Follow existing substitutions before looking for a recursive occurrence. A
// cycle hidden behind another variable is still an infinite type.
pub fn occurs_check_follows_indirect_bindings_test() {
  let #(a, state) = unify.fresh(unify.new())
  let #(b, state) = unify.fresh(state)
  let assert Ok(state) =
    unify.unify(a, types.ListType(b), origin(1, "list"), state)
  let assert Error(error) = unify.unify(b, a, origin(2, "recursive"), state)
  assert error.problem == unify.InfiniteType(1)
}

pub fn compound_types_share_variable_constraints_test() {
  let #(a, state) = unify.fresh(unify.new())
  let expected =
    types.FunctionType(
      [types.ListType(a)],
      types.ResultType(a, types.StringType),
    )
  let found =
    types.FunctionType(
      [types.ListType(types.IntType)],
      types.ResultType(types.IntType, types.StringType),
    )
  let assert Ok(state) =
    unify.unify(expected, found, origin(1, "function types agree"), state)
  assert unify.apply(expected, state) == found
  let assert Error(_) =
    unify.unify(
      types.TupleType([a, a]),
      types.TupleType([types.IntType, types.StringType]),
      origin(2, "tuple"),
      state,
    )
}

pub fn arity_mismatches_are_explicit_test() {
  let assert Error(error) =
    unify.unify(
      types.TupleType([types.IntType]),
      types.TupleType([]),
      origin(1, "tuple arity"),
      unify.new(),
    )
  assert error.problem == unify.ArityMismatch(1, 0)
  let assert Error(error) =
    unify.unify(
      types.FunctionType([], types.IntType),
      types.FunctionType([types.IntType], types.IntType),
      origin(1, "function arity"),
      unify.new(),
    )
  assert error.problem == unify.ArityMismatch(0, 1)
}

pub fn nominal_identity_includes_module_and_kind_test() {
  let a = types.Nominal("account", "User", types.ClassKind, [])
  let b = types.Nominal("admin", "User", types.ClassKind, [])
  let c = types.Nominal("account", "User", types.ActorKind, [])
  let assert Error(_) =
    unify.unify(a, b, origin(1, "nominal modules"), unify.new())
  let assert Error(_) =
    unify.unify(a, c, origin(1, "nominal kinds"), unify.new())
  let assert Ok(_) =
    unify.unify(a, a, origin(1, "same nominal type"), unify.new())
}

pub fn nominal_type_arguments_are_unified_test() {
  let #(a, state) = unify.fresh(unify.new())
  let expected = types.Nominal("box", "Box", types.ClassKind, [a])
  let found = types.Nominal("box", "Box", types.ClassKind, [types.StringType])
  let assert Ok(state) =
    unify.unify(expected, found, origin(1, "generic class"), state)
  assert unify.apply(a, state) == types.StringType
}

// A unification attempt can discover a conflict after solving an earlier
// tuple item. The caller's original state must remain available without that
// partial update.
pub fn failed_constraints_do_not_mutate_the_input_state_test() {
  let #(a, state) = unify.fresh(unify.new())
  let assert Error(_) =
    unify.unify(
      types.TupleType([a, types.StringType]),
      types.TupleType([types.IntType, types.BoolType]),
      origin(1, "tuple"),
      state,
    )
  assert unify.apply(a, state) == a
}

pub fn poison_suppresses_followup_type_errors_test() {
  let #(a, state) = unify.fresh(unify.new())
  let assert Ok(state) =
    unify.unify(a, types.ErrorType, origin(1, "already reported"), state)
  assert unify.apply(a, state) == a
  let assert Ok(_) =
    unify.unify(
      types.ListType(types.ErrorType),
      types.ListType(types.IntType),
      origin(1, "cascade"),
      state,
    )
}

// The later use explains where the disagreement appeared; the earlier binding
// explains why the value already had its type. Keep both addresses for the
// diagnostic.
pub fn earlier_constraints_are_preserved_in_conflicts_test() {
  let #(a, state) = unify.fresh(unify.new())
  let first = origin(8, "the binding is initialized with an Int")
  let later = origin(14, "this argument requires a String")
  let assert Ok(state) = unify.unify(a, types.IntType, first, state)
  let assert Error(error) = unify.unify(types.StringType, a, later, state)
  assert error.origin == later
  assert list.contains(error.related, first)
}

pub fn nested_binding_provenance_is_preserved_test() {
  let #(a, state) = unify.fresh(unify.new())
  let #(b, state) = unify.fresh(state)
  let first = origin(8, "element is Int")
  let assert Ok(state) = unify.unify(b, types.IntType, first, state)
  let assert Ok(state) =
    unify.unify(
      a,
      types.ListType(b),
      origin(9, "list contains the element"),
      state,
    )
  let assert Error(error) =
    unify.unify(
      a,
      types.ListType(types.StringType),
      origin(14, "String list expected"),
      state,
    )
  assert list.contains(error.related, first)
}

// Each use receives fresh variables, while the input and result within that
// one use still share a variable. These are two instances, not one value whose
// type changes halfway through checking.
//
// ```text
// identity : forall a. fn(a) -> a
// first use  : fn(Int) -> Int
// second use : fn(String) -> String
// ```
pub fn polymorphic_identity_instantiates_freshly_test() {
  let #(a, state) = unify.fresh(unify.new())
  let identity = scheme.generalize(types.FunctionType([a], a), [], state)
  let #(first, state) = scheme.instantiate(identity, state)
  let #(second, state) = scheme.instantiate(identity, state)
  let assert Ok(state) =
    unify.unify(
      first,
      types.FunctionType([types.IntType], types.IntType),
      origin(1, "integer identity"),
      state,
    )
  let assert Ok(state) =
    unify.unify(
      second,
      types.FunctionType([types.StringType], types.StringType),
      origin(2, "string identity"),
      state,
    )
  assert unify.apply(first, state) != unify.apply(second, state)
}

// Only variables free of the captured environment may become fresh at use
// sites. The result here still names the one captured value shared by both
// instances.
pub fn captured_variables_are_not_generalized_test() {
  let #(captured, state) = unify.fresh(unify.new())
  let #(parameter, state) = unify.fresh(state)
  let value =
    scheme.generalize(
      types.FunctionType([parameter], captured),
      [scheme.monomorphic(captured)],
      state,
    )
  let #(first, state) = scheme.instantiate(value, state)
  let #(second, state) = scheme.instantiate(value, state)
  let assert types.FunctionType([a], result_a) = first
  let assert types.FunctionType([b], result_b) = second
  assert a != b
  assert result_a == captured
  assert result_b == captured
  assert scheme.free_variables(value, state) == set.from_list([0])
}

pub fn generalization_observes_environment_substitutions_test() {
  let #(a, state) = unify.fresh(unify.new())
  let #(b, state) = unify.fresh(state)
  let assert Ok(state) =
    unify.unify(a, types.ListType(b), origin(1, "captured list"), state)
  let generalized = scheme.generalize(b, [scheme.monomorphic(a)], state)
  let #(instance, _) = scheme.instantiate(generalized, state)
  assert instance == b
}

pub fn source_style_type_names_are_stable_test() {
  assert types.to_string(types.FunctionType(
      [types.Variable(99), types.ListType(types.Variable(4))],
      types.Variable(99),
    ))
    == "fn(a, List(b)) -> a"
  assert types.to_string(
      types.TupleType([
        types.OptionType(types.IntType),
        types.ResultType(types.StringType, types.BoolType),
      ]),
    )
    == "#(Option(Int), Result(String, Bool))"
  let variables =
    list.repeat(Nil, 28)
    |> list.index_map(fn(_, index) { types.Variable(index) })
  assert types.to_string(types.TupleType(variables))
    == "#(a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, aa, ab)"
}

pub fn constraint_provenance_snapshot_test() {
  let source = "let x = 1\nuse(x)\n"
  let library = "use(x: String) { Nil }\n"
  let #(a, state) = unify.fresh(unify.new())
  let assert Ok(state) =
    unify.unify(
      a,
      types.IntType,
      origin(8, "the binding is initialized with an Int"),
      state,
    )
  let later =
    unify.Origin(
      location.new("src/library.pooka", location.span(library, 7, 13)),
      location.new("src/main.pooka", location.span(source, 14, 15)),
      "This argument must have type String.",
    )
  let assert Error(error) = unify.unify(types.StringType, a, later, state)
  [unify.to_diagnostic(error)]
  |> render.render_all(
    dict.from_list([
      #("src/main.pooka", source),
      #("src/library.pooka", library),
    ]),
    colour.PlainText,
    diagnostic.Quiet,
  )
  |> birdie.snap(title: "types: constraint provenance")
}

pub fn ordered_constraint_solving_test() {
  let #(a, state) = unify.fresh(unify.new())
  let #(b, state) = unify.fresh(state)
  let constraints = [
    unify.Equal(a, types.ListType(b), origin(1, "list")),
    unify.Equal(b, types.IntType, origin(2, "integer")),
  ]
  let assert Ok(solved) = unify.solve(constraints, state)
  assert unify.apply(a, solved) == types.ListType(types.IntType)
  let assert Error(error) =
    unify.solve(
      list.append(constraints, [
        unify.Equal(a, types.StringType, origin(3, "string")),
      ]),
      state,
    )
  assert error.origin == origin(3, "string")
  assert unify.apply(a, state) == a
}

pub fn free_variables_exclude_quantified_environment_bindings_test() {
  let #(a, state) = unify.fresh(unify.new())
  let polymorphic = scheme.generalize(a, [], state)
  assert scheme.free_variables(polymorphic, state) == set.new()
  let #(b, state) = unify.fresh(state)
  let next = scheme.generalize(b, [polymorphic], state)
  assert scheme.free_variables(next, state) == set.new()
}

pub fn comparison_formatting_preserves_distinct_variables_test() {
  assert types.format_pair(types.Variable(10), types.Variable(20))
    == #("a", "b")
  assert types.format_pair(
      types.ListType(types.Variable(10)),
      types.Variable(10),
    )
    == #("List(a)", "a")
}

// A written universal parameter is not an ordinary hole waiting for Int. It
// can be referred to, but its promise cannot be narrowed by one use.
pub fn rigid_variables_cannot_be_specialized_test() {
  let #(_, rigid, state) = unify.fresh_rigid("a", unify.new())
  let #(variable, state) = unify.fresh(state)
  let assert Error(_) =
    unify.unify(rigid, types.IntType, origin(1, "universal"), state)
  let assert Ok(state) =
    unify.unify(variable, rigid, origin(1, "same universal"), state)
  assert unify.apply(variable, state) == rigid
  assert types.variables(rigid) == set.new()
  assert set.size(types.rigids(rigid)) == 1
}

pub fn raw_pid_is_distinct_from_typed_actor_references_test() {
  assert types.to_string(types.PidType) == "Pid"
  let actor = types.Nominal("actors", "Counter", types.ActorKind, [])
  let assert Error(_) =
    unify.unify(
      types.PidType,
      actor,
      origin(1, "raw process identifiers are not actor protocols"),
      unify.new(),
    )
}

// An unresolved numeric domain remains pending until later constraints settle
// it. Treating it as either an error or a free polymorphic variable too early
// would lose information.
pub fn primitive_constraints_remain_pending_until_finalization_test() {
  let #(value, state) = unify.fresh(unify.new())
  let state =
    unify.require_primitive(state, value, unify.Numeric, origin(1, "numeric"))
  let #(state, diagnostics) = unify.settle_primitives(state, set.new())
  assert diagnostics == []
  assert unify.pending_variables(state) == set.from_list([0])
  let assert Ok(state) =
    unify.unify(value, types.IntType, origin(2, "integer annotation"), state)
  let #(state, diagnostics) = unify.settle_primitives(state, set.new())
  assert diagnostics == []
  assert unify.pending_variables(state) == set.new()
}

pub fn incompatible_primitive_domains_are_not_silently_accepted_test() {
  let #(value, state) = unify.fresh(unify.new())
  let state =
    unify.require_primitive(state, value, unify.Numeric, origin(1, "numeric"))
  let assert Ok(state) =
    unify.unify(value, types.StringType, origin(2, "string annotation"), state)
  let #(_, diagnostics) = unify.settle_primitives(state, set.new())
  let assert [value] = diagnostics
  assert value.id == "type.invalid_operator"
}

pub fn module_variable_namespaces_preserve_utf8_prefix_encoding_test() {
  let width = 18_446_744_073_709_551_616
  list.each(
    [#("", 1), #("a", 353), #("a\u{0000}", 90_368), #("é", 115_625)],
    fn(entry) {
      let #(first, state) = unify.fresh(unify.module_state(entry.0, []))
      let #(second, _) = unify.fresh(state)
      assert first == types.Variable(entry.1 * width)
      assert second == types.Variable(entry.1 * width + 1)
    },
  )
}
