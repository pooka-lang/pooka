//// The type checker keeps a notebook of promises that now agree.
////
//// Solve exact equality constraints, directional compatibility and primitive
//// operator requirements. Built-in immutable containers may widen to a base type;
//// nominal generic arguments and function parameters remain invariant.
////
//// ```text
//// subsume(List(Ref), List(Tmp)) succeeds when Tmp extends Ref
//// ```
////
//// Three operations answer three different questions:
////
//// ```text
//// unify(A, B)    : must the two structures be exactly equal?
//// subsume(A, B)  : may a B value be used where A is expected?
//// join([A, B])  : what compatible view can their surrounding expression share?
//// ```
////
//// Flexible variables can gain substitutions after an occurs check. Rigid
//// variables represent universal promises and cannot be solved as concrete types.
//// Constraint origins remain attached so the eventual error can explain which
//// earlier annotation made a later operation impossible.
////
//// Nominal registries and remembered expression types live in the same state.
//// They are infrastructure for inference and lowering, not additional coercions.
//// Primitive requirements are delayed until their operand variables have had a
//// chance to be constrained; unresolved arithmetic is diagnosed, not defaulted.

// SPDX-License-Identifier: Apache-2.0

import compiler/typesystem/monotype.{type Type}
import compiler/typesystem/nominal
import diagnostics/diagnostic.{type Diagnostic}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/set
import gleam/string
import utilities/location.{type Location, type Span}

pub type Origin {
  Origin(expected_at: Location, found_at: Location, reason: String)
}

pub type Constraint {
  Equal(expected: Type, found: Type, origin: Origin)
}

type Binding {
  Binding(value: Type, origin: Origin)
}

pub opaque type State {
  State(
    next_id: Int,
    bindings: Dict(Int, Binding),
    primitives: List(PrimitiveRequirement),
    expressions: Dict(#(String, Int, Int), Type),
    classes: Dict(nominal.Identity, nominal.Class),
    interfaces: Dict(nominal.Identity, nominal.Interface),
    enums: Dict(nominal.Identity, nominal.Enum),
    type_names: Dict(#(String, String, String), nominal.Identity),
    owner: Option(nominal.Identity),
    loop_breaks: Dict(Int, List(#(Type, Span))),
  )
}

pub type Problem {
  IncompatibleTypes
  ArityMismatch(expected: Int, found: Int)
  InfiniteType(variable: Int)
}

pub type UnifyError {
  UnifyError(
    expected: Type,
    found: Type,
    problem: Problem,
    origin: Origin,
    related: List(Origin),
  )
}

/// Start an empty inference notebook with fresh-ID allocation and nominal
/// registries ready for this checking context.
///
/// ```text
/// new state -> no substitutions and no pending operator requirements
/// ```
pub fn new() -> State {
  State(
    0,
    dict.new(),
    [],
    dict.new(),
    dict.new(),
    dict.new(),
    dict.new(),
    dict.new(),
    None,
    dict.new(),
  )
}

/// Allocate a flexible variable that later constraints may solve. Every
/// allocation advances the shared ID supply.
///
/// ```text
/// fresh, fresh -> Variable(0), Variable(1)
/// ```
pub fn fresh(state: State) -> #(Type, State) {
  #(
    monotype.Variable(state.next_id),
    State(..state, next_id: state.next_id + 1),
  )
}

/// Follow substitutions through the entire type, not merely its outer
/// constructor.
///
/// ```text
/// a := Int; apply(List(a)) -> List(Int)
/// ```
pub fn apply(value: Type, state: State) -> Type {
  case value {
    monotype.Variable(id) ->
      case dict.get(state.bindings, id) {
        Ok(binding) -> apply(binding.value, state)
        Error(Nil) -> value
      }
    monotype.ListType(value) -> monotype.ListType(apply(value, state))
    monotype.OptionType(value) -> monotype.OptionType(apply(value, state))
    monotype.ResultType(value, error) ->
      monotype.ResultType(apply(value, state), apply(error, state))
    monotype.TupleType(elements) ->
      monotype.TupleType(list.map(elements, apply(_, state)))
    monotype.FunctionType(parameters, result) ->
      monotype.FunctionType(
        list.map(parameters, apply(_, state)),
        apply(result, state),
      )
    monotype.Nominal(module, name, kind, arguments) ->
      monotype.Nominal(module, name, kind, list.map(arguments, apply(_, state)))
    monotype.RigidVariable(..)
    | monotype.IntType
    | monotype.FloatType
    | monotype.StringType
    | monotype.BoolType
    | monotype.NilType
    | monotype.BitArrayType
    | monotype.PidType
    | monotype.ErrorType -> value
  }
}

/// Solve equality constraints in order, carrying substitutions from one
/// constraint into the next.
///
/// ```text
/// a = b; b = Int -> both a and b resolve to Int
/// ```
pub fn solve(
  constraints: List(Constraint),
  state: State,
) -> Result(State, UnifyError) {
  list.try_fold(constraints, state, fn(state, constraint) {
    unify(constraint.expected, constraint.found, constraint.origin, state)
  })
}

/// Require exact structural equality and record variable bindings with their
/// origin. This operation deliberately does not upcast classes.
///
/// ```text
/// unify(List(Ref), List(Tmp)) fails even when Tmp extends Ref
/// ```
pub fn unify(
  expected: Type,
  found: Type,
  origin: Origin,
  state: State,
) -> Result(State, UnifyError) {
  equal(expected, found, origin, [], state)
}

/// Check whether found can be used where expected is required. Immutable built-in
/// containers recurse covariantly, while nominal arguments and function
/// parameters stay invariant.
///
/// ```text
/// expected List(Ref), found List(Tmp) -> accepted when Tmp is Ref
/// ```
pub fn subsume(
  expected: Type,
  found: Type,
  origin: Origin,
  state: State,
) -> Result(State, UnifyError) {
  subsume_with(expected, found, origin, [], state)
}

/// Carry related constraint origins while recursively checking compatibility.
/// Evidence should survive a descent into nested container elements.
///
/// ```text
/// List(Option(Ref)) accepts List(Option(Tmp)); a failing inner type retains its labels
/// ```
fn subsume_with(
  expected: Type,
  found: Type,
  origin: Origin,
  related: List(Origin),
  state: State,
) -> Result(State, UnifyError) {
  let #(target, first) = dereference(expected, state)
  let #(source, second) = dereference(found, state)
  let related = list.flatten([related, first, second]) |> list.unique
  case target, source {
    monotype.ListType(a), monotype.ListType(b)
    | monotype.OptionType(a), monotype.OptionType(b)
    -> subsume_with(a, b, origin, related, state)
    monotype.ResultType(a, e), monotype.ResultType(b, f) ->
      subsume_pairs([a, e], [b, f], origin, related, state)
    monotype.TupleType(a), monotype.TupleType(b) ->
      subsume_pairs(a, b, origin, related, state)
    monotype.FunctionType(a, result_a), monotype.FunctionType(b, result_b) -> {
      use state <- result.try(pairs(a, b, origin, related, state))
      subsume_with(result_a, result_b, origin, related, state)
    }
    monotype.Nominal(module, name, monotype.ClassKind, _),
      monotype.Nominal(_, _, monotype.ClassKind, _)
    ->
      case upcast(state, apply(source, state), #(module, name)) {
        Ok(view) -> equal(target, view, origin, related, state)
        Error(Nil) -> equal(target, source, origin, related, state)
      }
    monotype.Nominal(module, name, monotype.InterfaceKind, _),
      monotype.Nominal(_, _, _, _)
    ->
      case interface_view(state, source, #(module, name)) {
        Ok(view) -> equal(target, view, origin, related, state)
        Error(Nil) -> equal(target, source, origin, related, state)
      }
    _, _ -> equal(target, source, origin, related, state)
  }
}

/// Check equally sized product components with directional compatibility. A
/// product with the wrong arity still uses the ordinary arity diagnostic.
///
/// ```text
/// #(Ref, Int) accepts #(Tmp, Int), not #(Tmp)
/// ```
fn subsume_pairs(
  expected: List(Type),
  found: List(Type),
  origin: Origin,
  related: List(Origin),
  state: State,
) -> Result(State, UnifyError) {
  case list.length(expected) == list.length(found) {
    False -> pairs(expected, found, origin, related, state)
    True ->
      list.zip(expected, found)
      |> list.try_fold(state, fn(state, pair) {
        subsume_with(pair.0, pair.1, origin, related, state)
      })
  }
}

/// Walk superclass metadata and substitute generic arguments at each parent edge.
/// A parent view changes the static type, not the runtime object.
///
/// ```text
/// Child(Int) is Parent(List(Int)) -> parent view Parent(List(Int))
/// ```
pub fn upcast(
  state: State,
  value: Type,
  target: nominal.Identity,
) -> Result(Type, Nil) {
  case value {
    monotype.Nominal(module, name, monotype.ClassKind, arguments) ->
      case #(module, name) == target {
        True -> Ok(value)
        False -> {
          use class <- result.try(class(state, #(module, name)))
          case class.superclass {
            None -> Error(Nil)
            option.Some(parent) -> {
              let arguments_of_parent =
                list.map(parent.arguments, fn(argument) {
                  nominal.instantiate(apply(argument, state), class, arguments)
                })
              upcast(
                state,
                monotype.Nominal(
                  parent.identity.0,
                  parent.identity.1,
                  monotype.ClassKind,
                  arguments_of_parent,
                ),
                target,
              )
            }
          }
        }
      }
    _ -> Error(Nil)
  }
}

/// Find a shared compatible type for known values, including nested built-in
/// containers. Later constraints still validate every participating value.
///
/// ```text
/// Option(Tmp) joined with Option(Con) -> Option(Ref)
/// ```
pub fn join(state: State, types: List(Type)) -> Result(Type, Nil) {
  case list.map(types, apply(_, state)) {
    [] -> Error(Nil)
    [first, ..rest] ->
      list.try_fold(rest, first, fn(first, next) {
        join_types(state, first, next)
      })
  }
}

/// Join two structural types without changing function parameter variance or
/// nominal generic arguments.
///
/// ```text
/// List(Tmp) + List(Con) -> List(Ref); Box(Tmp) is not automatically Box(Ref)
/// ```
fn join_types(state: State, first: Type, second: Type) -> Result(Type, Nil) {
  case first, second {
    _, _ if first == second -> Ok(first)
    monotype.Variable(_), _ | monotype.ErrorType, _ -> Ok(second)
    _, monotype.Variable(_) | _, monotype.ErrorType -> Ok(first)
    monotype.ListType(a), monotype.ListType(b) ->
      join_types(state, a, b) |> result.map(monotype.ListType)
    monotype.OptionType(a), monotype.OptionType(b) ->
      join_types(state, a, b) |> result.map(monotype.OptionType)
    monotype.ResultType(a, e), monotype.ResultType(b, f) -> {
      use value <- result.try(join_types(state, a, b))
      use error <- result.try(join_types(state, e, f))
      Ok(monotype.ResultType(value, error))
    }
    monotype.TupleType(a), monotype.TupleType(b) ->
      join_elements(state, a, b) |> result.map(monotype.TupleType)
    monotype.FunctionType(a, result_a), monotype.FunctionType(b, result_b)
      if a == b
    ->
      join_types(state, result_a, result_b)
      |> result.map(monotype.FunctionType(a, _))
    _, _ -> join_classes(state, [first, second])
  }
}

/// Join tuple positions independently, requiring equal tuple lengths.
///
/// ```text
/// #(Tmp, Int) + #(Con, Int) -> #(Ref, Int)
/// ```
fn join_elements(
  state: State,
  a: List(Type),
  b: List(Type),
) -> Result(List(Type), Nil) {
  case list.length(a) == list.length(b) {
    False -> Error(Nil)
    True ->
      list.try_map(list.zip(a, b), fn(pair) {
        join_types(state, pair.0, pair.1)
      })
  }
}

/// Try common ancestors from the first class outward until the other classes can
/// be viewed through one. Argument equality is checked by later constraints.
///
/// ```text
/// Dog + Cat -> their nearest common Animal ancestor
/// ```
fn join_classes(state: State, types: List(Type)) -> Result(Type, Nil) {
  let types = list.map(types, apply(_, state))
  case types {
    [] -> Error(Nil)
    [first, ..rest] -> {
      use chain <- result.try(ancestry(state, first))
      list.find_map(chain, fn(candidate) {
        case
          list.all(rest, fn(other) {
            result.is_ok(upcast(state, other, candidate))
          })
        {
          True -> upcast(state, first, candidate)
          False -> Error(Nil)
        }
      })
    }
  }
}

fn ancestry(state: State, value: Type) -> Result(List(nominal.Identity), Nil) {
  case value {
    monotype.Nominal(module, name, monotype.ClassKind, _) ->
      Ok(ancestors(state, #(module, name)))
    _ -> Error(Nil)
  }
}

/// List a class before its successive parents. Callers that build object layouts
/// reverse this to root-first order.
///
/// ```text
/// Puppy -> [Puppy, Dog, Animal]
/// ```
pub fn ancestors(
  state: State,
  identity: nominal.Identity,
) -> List(nominal.Identity) {
  case class(state, identity) {
    Ok(nominal.Class(superclass: option.Some(parent), ..)) -> [
      identity,
      ..ancestors(state, parent.identity)
    ]
    _ -> [identity]
  }
}

/// Find direct subclass descriptors in a stable order. This is one generation,
/// not the full family tree.
///
/// ```text
/// Animal -> its immediate Dog and Cat children
/// ```
pub fn children(
  state: State,
  identity: nominal.Identity,
) -> List(nominal.Class) {
  dict.values(state.classes)
  |> list.filter(fn(class) {
    case class.superclass {
      option.Some(parent) -> parent.identity == identity
      None -> False
    }
  })
  |> list.sort(fn(first, second) {
    string.compare(first.source.name.name, second.source.name.name)
  })
}

/// Collect the class family below one identity for closed-hierarchy reasoning.
///
/// ```text
/// Animal subtree includes Animal and its descendants
/// ```
pub fn subtree(
  state: State,
  identity: nominal.Identity,
) -> List(nominal.Class) {
  case class(state, identity) {
    Error(Nil) -> []
    Ok(root) -> [
      root,
      ..list.flat_map(children(state, identity), fn(child) {
        subtree(state, nominal.identity(child))
      })
    ]
  }
}

/// Ask whether this class has a usable constructor under the family's
/// construction rule.
///
/// ```text
/// an abstract family root with no new is not constructible
/// ```
pub fn constructible(state: State, class: nominal.Class) -> Bool {
  nominal.has_constructor(class)
  || children(state, nominal.identity(class)) == []
}

/// Ask whether the descriptor participates in an inheritance layout rather than a
/// standalone class layout.
///
/// ```text
/// a parent or child uses hierarchy-aware tuple access
/// ```
pub fn in_hierarchy(state: State, class: nominal.Class) -> Bool {
  class.superclass != None || children(state, nominal.identity(class)) != []
}

/// Follow flexible-variable bindings while retaining their constraint origins for
/// diagnostics.
///
/// ```text
/// a -> b -> Int carries the origins that introduced those links
/// ```
fn dereference(value: Type, state: State) -> #(Type, List(Origin)) {
  case value {
    monotype.Variable(id) ->
      case dict.get(state.bindings, id) {
        Error(Nil) -> #(value, [])
        Ok(binding) -> {
          let #(resolved, origins) = dereference(binding.value, state)
          #(resolved, [binding.origin, ..origins])
        }
      }
    _ -> #(value, [])
  }
}

/// Implement structural equality after dereferencing. Variable binding, occurs
/// checks and container recursion all meet at this gate.
///
/// ```text
/// a = List(a) fails; a = List(Int) may bind a
/// ```
fn equal(
  expected: Type,
  found: Type,
  origin: Origin,
  related: List(Origin),
  state: State,
) -> Result(State, UnifyError) {
  let #(expected, first) = dereference(expected, state)
  let #(found, second) = dereference(found, state)
  let related = list.flatten([related, first, second]) |> list.unique
  case expected, found {
    monotype.ErrorType, _ | _, monotype.ErrorType -> Ok(state)
    _, _ if expected == found -> Ok(state)
    monotype.Variable(id), value -> bind(id, value, origin, related, state)
    value, monotype.Variable(id) -> bind(id, value, origin, related, state)
    monotype.ListType(a), monotype.ListType(b)
    | monotype.OptionType(a), monotype.OptionType(b)
    -> equal(a, b, origin, related, state)
    monotype.ResultType(a, e), monotype.ResultType(b, f) ->
      pairs([a, e], [b, f], origin, related, state)
    monotype.TupleType(a), monotype.TupleType(b) ->
      pairs(a, b, origin, related, state)
    monotype.FunctionType(a, result_a), monotype.FunctionType(b, result_b) -> {
      use state <- result.try(pairs(a, b, origin, related, state))
      equal(result_a, result_b, origin, related, state)
    }
    monotype.Nominal(module_a, name_a, kind_a, args_a),
      monotype.Nominal(module_b, name_b, kind_b, args_b)
      if module_a == module_b && name_a == name_b && kind_a == kind_b
    -> pairs(args_a, args_b, origin, related, state)
    _, _ ->
      Error(UnifyError(
        apply(expected, state),
        apply(found, state),
        IncompatibleTypes,
        origin,
        related,
      ))
  }
}

/// Install a variable substitution only after the occurs check. An infinitely
/// self-containing type is not a useful jar for a value.
///
/// ```text
/// bind a to List(a) -> InfiniteType(a)
/// ```
fn bind(
  id: Int,
  value: Type,
  origin: Origin,
  related: List(Origin),
  state: State,
) -> Result(State, UnifyError) {
  let resolved = apply(value, state)
  case set.contains(monotype.variables(resolved), id) {
    True ->
      Error(UnifyError(
        monotype.Variable(id),
        resolved,
        InfiniteType(id),
        origin,
        related,
      ))
    False ->
      Ok(
        State(
          ..state,
          bindings: dict.insert(state.bindings, id, Binding(value, origin)),
        ),
      )
  }
}

/// Unify same-length component lists position by position, preserving the
/// original constraint reason.
///
/// ```text
/// [a, String] = [Int, String] -> a := Int
/// ```
fn pairs(
  expected: List(Type),
  found: List(Type),
  origin: Origin,
  related: List(Origin),
  state: State,
) -> Result(State, UnifyError) {
  case list.length(expected) == list.length(found) {
    False ->
      Error(UnifyError(
        monotype.TupleType(list.map(expected, apply(_, state))),
        monotype.TupleType(list.map(found, apply(_, state))),
        ArityMismatch(list.length(expected), list.length(found)),
        origin,
        related,
      ))
    True ->
      list.zip(expected, found)
      |> list.try_fold(state, fn(state, pair) {
        equal(pair.0, pair.1, origin, related, state)
      })
  }
}

/// Turn a failed constraint and its remembered origins into a source-labelled
/// diagnostic.
///
/// ```text
/// expected Int, found String -> primary mismatch plus relevant earlier constraints
/// ```
pub fn to_diagnostic(error: UnifyError) -> Diagnostic {
  let #(expected, found) = monotype.format_pair(error.expected, error.found)
  let title = case error.problem {
    IncompatibleTypes -> "type mismatch"
    ArityMismatch(..) -> "type arity mismatch"
    InfiniteType(_) -> "infinite type"
  }
  let base =
    diagnostic.error("type.unification", title)
    |> diagnostic.primary(error.origin.found_at, "found " <> found)
    |> diagnostic.secondary(error.origin.expected_at, "expected " <> expected)
    |> diagnostic.conclusion(error.origin.reason)
  let base = case error.problem {
    InfiniteType(_) ->
      diagnostic.help(
        base,
        "This constraint would require a type to contain itself. Check for a value being applied to itself or nested into its own type.",
      )
    IncompatibleTypes | ArityMismatch(..) -> base
  }
  error.related
  |> list.filter(fn(origin) { origin != error.origin })
  |> list.fold(base, fn(value, origin) {
    diagnostic.secondary(
      value,
      origin.found_at,
      "earlier constraint: " <> origin.reason,
    )
  })
}

/// Allocate a universal variable that ordinary unification cannot choose to be a
/// convenient concrete type.
///
/// ```text
/// fn(value: a) -> a { 1 } cannot solve rigid a as Int
/// ```
pub fn fresh_rigid(name: String, state: State) -> #(Int, Type, State) {
  #(
    state.next_id,
    monotype.RigidVariable(state.next_id, name),
    State(..state, next_id: state.next_id + 1),
  )
}

pub type PrimitiveKind {
  Numeric
  Addable
}

type PrimitiveRequirement {
  PrimitiveRequirement(value: Type, kind: PrimitiveKind, origin: Origin)
}

/// Record a Numeric or Addable obligation while operand types may still be
/// unresolved.
///
/// ```text
/// x + y records an Addable requirement, not immediate string-or-number defaulting
/// ```
pub fn require_primitive(
  state: State,
  value: Type,
  kind: PrimitiveKind,
  origin: Origin,
) -> State {
  State(..state, primitives: [
    PrimitiveRequirement(value, kind, origin),
    ..state.primitives
  ])
}

/// Find flexible variables occurring in unresolved primitive requirements.
///
/// ```text
/// an untyped numeric operand remains pending until its group is finalized
/// ```
pub fn pending_variables(state: State) -> set.Set(Int) {
  list.fold(state.primitives, set.new(), fn(found, requirement) {
    set.union(found, monotype.variables(apply(requirement.value, state)))
  })
}

/// Discharge known primitive domains and report unresolved finalized operands.
/// Never choose Int merely to make an ambiguous operator go away.
///
/// ```text
/// subtract(a,b) with no useful constraints -> ambiguous operator diagnostic
/// ```
pub fn settle_primitives(
  state: State,
  finalized: set.Set(Int),
) -> #(State, List(Diagnostic)) {
  let domains =
    list.fold(state.primitives, dict.new(), fn(found, requirement) {
      case apply(requirement.value, state) {
        monotype.Variable(id) -> {
          let kind = case dict.get(found, id), requirement.kind {
            Ok(Numeric), _ | _, Numeric -> Numeric
            _, Addable -> Addable
          }
          dict.insert(found, id, kind)
        }
        _ -> found
      }
    })
  let #(kept, diagnostics, _) =
    list.fold(
      list.reverse(state.primitives),
      #([], [], set.new()),
      fn(acc, requirement) {
        let #(kept, diagnostics, reported) = acc
        let value = apply(requirement.value, state)
        case value {
          monotype.ErrorType -> acc
          monotype.IntType | monotype.FloatType -> acc
          monotype.StringType if requirement.kind == Addable -> acc
          monotype.Variable(id) ->
            case set.contains(finalized, id), set.contains(reported, id) {
              False, _ -> #([requirement, ..kept], diagnostics, reported)
              True, True -> acc
              True, False -> {
                let kind = case dict.get(domains, id) {
                  Ok(kind) -> kind
                  Error(Nil) -> requirement.kind
                }
                let error =
                  diagnostic.error(
                    "type.ambiguous_operator",
                    "ambiguous operator operand type",
                  )
                  |> diagnostic.primary(
                    requirement.origin.found_at,
                    "the operand type is still unknown",
                  )
                  |> diagnostic.conclusion(
                    "Add an operand type annotation to choose a supported primitive operation.",
                  )
                  |> diagnostic.help(
                    "Supported operand types: " <> primitive_names(kind) <> ".",
                  )
                #(kept, [error, ..diagnostics], set.insert(reported, id))
              }
            }
          _ -> {
            let error =
              diagnostic.error("type.invalid_operator", "invalid operand type")
              |> diagnostic.primary(
                requirement.origin.found_at,
                "found " <> monotype.to_string(value),
              )
              |> diagnostic.conclusion(
                "This operator requires "
                <> primitive_names(requirement.kind)
                <> " operands.",
              )
            let #(_, origins) = dereference(requirement.value, state)
            let error =
              list.unique(origins)
              |> list.fold(error, fn(error, origin) {
                case origin == requirement.origin {
                  True -> error
                  False ->
                    diagnostic.secondary(
                      error,
                      origin.expected_at,
                      "this earlier constraint requires that type",
                    )
                }
              })
            #(kept, [error, ..diagnostics], reported)
          }
        }
      },
    )
  #(State(..state, primitives: kept), list.reverse(diagnostics))
}

fn primitive_names(kind: PrimitiveKind) -> String {
  case kind {
    Numeric -> "Int or Float"
    Addable -> "Int, Float or String"
  }
}

/// Store an expression's inferred type under its source span for later lowering.
///
/// ```text
/// span of 5 / 2 -> Int; codegen selects Erlang div
/// ```
pub fn remember_expression(
  state: State,
  path: String,
  span: Span,
  type_: Type,
) -> State {
  State(
    ..state,
    expressions: dict.insert(
      state.expressions,
      #(path, span.start.byte_offset, span.end.byte_offset),
      type_,
    ),
  )
}

/// Read remembered metadata with the current substitution applied. Codegen
/// depends on this final view rather than repeating inference.
///
/// ```text
/// a remembered result variable later solved as Int is read as Int
/// ```
pub fn expression_type(
  state: State,
  path: String,
  span: Span,
) -> Result(Type, Nil) {
  dict.get(state.expressions, #(
    path,
    span.start.byte_offset,
    span.end.byte_offset,
  ))
  |> result.map(apply(_, state))
}

/// Publish a nominal class descriptor in the current registry. Registration and
/// prepared field metadata are separate stages.
///
/// ```text
/// registered Box identity -> later prepared Box fields and methods
/// ```
pub fn register_class(state: State, class: nominal.Class) -> State {
  State(
    ..state,
    classes: dict.insert(state.classes, nominal.identity(class), class),
  )
}

/// Look up a class by its qualified identity, without falling back to a matching
/// display name.
///
/// ```text
/// module A's Box is distinct from module B's Box
/// ```
pub fn class(
  state: State,
  identity: nominal.Identity,
) -> Result(nominal.Class, Nil) {
  dict.get(state.classes, identity)
}

pub fn classes_in(state: State, module: String) -> List(nominal.Class) {
  dict.values(state.classes)
  |> list.filter(fn(class) { class.module == module })
}

/// Associate a source-visible type name with its qualified identity for later
/// annotation and constructor lookup.
///
/// ```text
/// an imported alias -> its original nominal identity
/// ```
pub fn bind_type(
  state: State,
  path: String,
  qualifier: String,
  name: String,
  identity: nominal.Identity,
) -> State {
  State(
    ..state,
    type_names: dict.insert(
      state.type_names,
      #(path, qualifier, name),
      identity,
    ),
  )
}

/// Resolve a class name in the given source/import context before retrieving its
/// descriptor.
///
/// ```text
/// Box in a module -> the class bound to that module's Box name
/// ```
pub fn named_class(
  state: State,
  path: String,
  qualifier: String,
  name: String,
) -> Result(nominal.Class, Nil) {
  use identity <- result.try(
    dict.get(state.type_names, #(path, qualifier, name)),
  )
  class(state, identity)
}

pub fn owner(state: State) -> Option(nominal.Identity) {
  state.owner
}

/// Set the current nominal owner for private-member checks and restore it at the
/// caller's scope boundary.
///
/// ```text
/// checking Box's method -> owner Box; checking module function -> no class owner
/// ```
pub fn with_owner(state: State, owner: Option(nominal.Identity)) -> State {
  State(..state, owner:)
}

pub fn classes_for_path(state: State, path: String) -> List(nominal.Class) {
  dict.values(state.classes) |> list.filter(fn(class) { class.path == path })
}

pub fn register_interface(state: State, interface: nominal.Interface) -> State {
  State(
    ..state,
    interfaces: dict.insert(
      state.interfaces,
      #(interface.module, interface.source.name.name),
      interface,
    ),
  )
}

pub fn interface(
  state: State,
  identity: nominal.Identity,
) -> Result(nominal.Interface, Nil) {
  dict.get(state.interfaces, identity)
}

pub fn interfaces_in(state: State, module: String) -> List(nominal.Interface) {
  dict.values(state.interfaces)
  |> list.filter(fn(interface) { interface.module == module })
}

pub fn named_interface(
  state: State,
  path: String,
  qualifier: String,
  name: String,
) -> Result(nominal.Interface, Nil) {
  use identity <- result.try(
    dict.get(state.type_names, #(path, qualifier, name)),
  )
  interface(state, identity)
}

/// Find a declared interface view and instantiate it for the concrete nominal
/// arguments.
///
/// ```text
/// Box(Int) with Item(a) -> Item(Int)
/// ```
pub fn interface_view(
  state: State,
  value: Type,
  target: nominal.Identity,
) -> Result(Type, Nil) {
  case apply(value, state) {
    monotype.Nominal(module, name, _, arguments) -> {
      use class <- result.try(class(state, #(module, name)))
      list.find_map(class.interfaces, fn(implemented) {
        case nominal.instantiate(apply(implemented, state), class, arguments) {
          monotype.Nominal(m, n, monotype.InterfaceKind, _) as view
            if #(m, n) == target
          -> Ok(view)
          _ -> Error(Nil)
        }
      })
    }
    _ -> Error(Nil)
  }
}

/// Retain a loop's break-result type and location so all value-producing exits
/// can agree.
///
/// ```text
/// break 1 and break 2 -> Int result; incompatible breaks produce a diagnostic
/// ```
pub fn remember_break(
  state: State,
  loop: Type,
  value: Type,
  span: Span,
) -> State {
  let assert monotype.Variable(id) = loop
  let previous = dict.get(state.loop_breaks, id) |> result.unwrap([])
  State(
    ..state,
    loop_breaks: dict.insert(state.loop_breaks, id, [#(value, span), ..previous]),
  )
}

pub fn loop_breaks(state: State, loop: Type) -> List(#(Type, Span)) {
  let assert monotype.Variable(id) = loop
  dict.get(state.loop_breaks, id) |> result.unwrap([]) |> list.reverse
}

/// Combine dependency metadata into a state suitable for the next module's
/// inference context.
///
/// ```text
/// checked dependency interfaces -> importing module state
/// ```
pub fn module_state(identity: String, dependencies: List(State)) -> State {
  list.fold(
    dependencies,
    State(..new(), next_id: module_seed(identity)),
    fn(found, dependency) {
      State(
        ..found,
        bindings: dict.merge(found.bindings, dependency.bindings),
        classes: dict.merge(found.classes, dependency.classes),
        interfaces: dict.merge(found.interfaces, dependency.interfaces),
        enums: dict.merge(found.enums, dependency.enums),
        type_names: dict.merge(found.type_names, dependency.type_names),
      )
    },
  )
}

/// Rebase a reusable module report into another inference context, keeping
/// nominal identities while avoiding variable-ID collisions.
///
/// ```text
/// cached module variables -> fresh IDs in the receiving context
/// ```
pub fn rebase_module(
  cached: State,
  current: State,
  identity: String,
  path: String,
) -> State {
  let seed = module_seed(identity)
  State(
    ..cached,
    bindings: dict.merge(
      current.bindings,
      dict.filter(cached.bindings, fn(id, _) {
        id >= seed && id < seed + variable_namespace_width()
      }),
    ),
    classes: dict.merge(
      current.classes,
      dict.filter(cached.classes, fn(_, c) { c.path == path }),
    ),
    interfaces: dict.merge(
      current.interfaces,
      dict.filter(cached.interfaces, fn(_, i) { i.path == path }),
    ),
    enums: dict.merge(
      current.enums,
      dict.filter(cached.enums, fn(_, e) { e.path == path }),
    ),
    type_names: dict.merge(
      current.type_names,
      dict.filter(cached.type_names, fn(key, _) { key.0 == path }),
    ),
  )
}

pub fn module_classes(state: State) -> List(nominal.Class) {
  dict.values(state.classes)
}

pub fn module_interfaces(state: State) -> List(nominal.Interface) {
  dict.values(state.interfaces)
}

pub fn register_enum(state: State, enum: nominal.Enum) -> State {
  State(
    ..state,
    enums: dict.insert(state.enums, nominal.enum_identity(enum), enum),
  )
}

pub fn enum(
  state: State,
  identity: nominal.Identity,
) -> Result(nominal.Enum, Nil) {
  dict.get(state.enums, identity)
}

pub fn enums_in(state: State, module: String) -> List(nominal.Enum) {
  dict.values(state.enums)
  |> list.filter(fn(enum) { enum.module == module })
}

pub fn named_enum(
  state: State,
  path: String,
  qualifier: String,
  name: String,
) -> Result(nominal.Enum, Nil) {
  use identity <- result.try(
    dict.get(state.type_names, #(path, qualifier, name)),
  )
  enum(state, identity)
}

pub fn module_enums(state: State) -> List(nominal.Enum) {
  dict.values(state.enums)
}

fn module_seed(identity: String) -> Int {
  namespace_bytes(bit_array.from_string(identity), 1)
  * variable_namespace_width()
}

fn namespace_bytes(bytes: BitArray, prefix: Int) -> Int {
  case bytes {
    <<byte:8, rest:bits>> -> namespace_bytes(rest, prefix * 256 + byte)

    _ -> prefix
  }
}

fn variable_namespace_width() -> Int {
  18_446_744_073_709_551_616
}

pub fn expression_types(state: State, path: String) -> List(#(Int, Int, Type)) {
  dict.to_list(state.expressions)
  |> list.filter_map(fn(entry) {
    case entry.0.0 == path {
      True -> Ok(#(entry.0.1, entry.0.2, apply(entry.1, state)))
      False -> Error(Nil)
    }
  })
}
