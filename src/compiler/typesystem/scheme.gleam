//// A generic function needs a fresh coat for every visit.
////
//// Quantify variables that are not captured by the environment, then instantiate
//// them freshly at each use. Monomorphic captured variables remain shared,
//// however inviting generalization may look.
////
//// ```text
//// forall a. fn(a) -> a -> fn(Int) -> Int at one use
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/typesystem/monotype.{type Type}
import compiler/typesystem/unify.{type State}
import gleam/dict
import gleam/int
import gleam/list
import gleam/set.{type Set}

pub opaque type Scheme {
  Scheme(quantified: List(Int), body: Type)
}

/// Keep this type's flexible variables shared with their environment. A captured
/// value must not acquire fresh types merely because it is used twice.
///
/// ```text
/// captured a -> Scheme([], a), with the same a on every use
/// ```
pub fn monomorphic(body: Type) -> Scheme {
  Scheme([], body)
}

/// Quantify variables free in the result but not free in the surrounding
/// environment. Apply current substitutions before calculating that difference.
///
/// ```text
/// result fn(a) -> a, environment has no a -> forall a. fn(a) -> a
/// ```
pub fn generalize(
  body: Type,
  environment: List(Scheme),
  state: State,
) -> Scheme {
  let body = unify.apply(body, state)
  let environment_variables =
    list.fold(environment, set.new(), fn(found, value) {
      set.union(found, free_variables(value, state))
    })
  let quantified =
    set.difference(monotype.variables(body), environment_variables)
    |> set.to_list
    |> list.sort(int.compare)
  Scheme(quantified, body)
}

/// Subtract the scheme's quantified IDs from the variables still visible after
/// substitution.
///
/// ```text
/// free(forall a. fn(a) -> b) = {b}
/// ```
pub fn free_variables(value: Scheme, state: State) -> Set(Int) {
  set.difference(
    monotype.variables(unify.apply(value.body, state)),
    set.from_list(value.quantified),
  )
}

/// Replace quantified variables with fresh flexible variables at each use.
/// Unquantified captures keep their existing identity.
///
/// ```text
/// identity(1) and identity("oak") instantiate independent argument types
/// ```
pub fn instantiate(value: Scheme, state: State) -> #(Type, State) {
  let #(replacements, state) =
    list.fold(value.quantified, #(dict.new(), state), fn(acc, id) {
      let #(replacements, state) = acc
      let #(variable, state) = unify.fresh(state)
      #(dict.insert(replacements, id, variable), state)
    })
  #(unify.apply(monotype.replace(value.body, replacements), state), state)
}

/// Find rigid promises retained in this scheme after current substitutions.
/// Escape checking uses this to inspect captures.
///
/// ```text
/// a captured binding containing method-local rigid b must be rejected
/// ```
pub fn rigid_variables(value: Scheme, state: State) -> Set(Int) {
  monotype.rigids(unify.apply(value.body, state))
}

/// Construct a scheme with an explicitly selected list of quantified IDs. The
/// caller is responsible for choosing valid quantifiers.
///
/// ```text
/// quantified(fn(a) -> a, [a]) -> independently instantiable identity
/// ```
pub fn quantified(body: Type, variables: List(Int)) -> Scheme {
  Scheme(variables, body)
}
