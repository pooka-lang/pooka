//// Keep yesterday's type report in a labelled drawer.
////
//// Serialize reusable module interfaces and inference data behind a versioned
//// key. A cache miss asks the checker to work again; it must never become a type-
//// system assumption.
////
//// ```text
//// source key + imported interface keys -> cached type report
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/analysis/module
import compiler/foreign_language
import compiler/typesystem/module_infer
import compiler/typesystem/monotype
import compiler/typesystem/nominal
import compiler/typesystem/unify
import gleam/int
import gleam/list
import gleam/string

pub fn interface(value: module_infer.Module) -> List(String) {
  let state = value.state
  list.flatten([
    value.functions
      |> list.filter(fn(f) { !string.starts_with(f.name.name, "_") })
      |> list.map(fn(f) {
        f.name.name <> ":" <> monotype.to_string(unify.apply(f.type_, state))
      }),
    value.externals
      |> list.flat_map(fn(e) {
        [
          "external:"
            <> e.name.name
            <> ":"
            <> foreign_language.name(e.language)
            <> ":"
            <> e.module,
          ..list.map(e.functions, fn(f) {
            f.name.name
            <> ":"
            <> monotype.to_string(unify.apply(f.type_, state))
          })
        ]
      }),
    unify.module_classes(state)
      |> list.sort(fn(a, b) {
        string.compare(
          a.module <> a.source.name.name,
          b.module <> b.source.name.name,
        )
      })
      |> list.flat_map(fn(c) {
        [
          "class:"
            <> c.module
            <> "."
            <> c.source.name.name
            <> ":"
            <> case c.actor {
            True -> "actor"
            False -> "class"
          },
          "parameters:" <> int.to_string(list.length(c.parameters)),
          "types:"
            <> monotype.to_string(
            monotype.TupleType(
              list.flatten([
                list.map(c.parameters, fn(p) { p.1 }),
                [c.constructor],
                case c.superclass {
                  Some(parent) -> parent.arguments
                  None -> []
                },
                list.map(c.fields, fn(f) { f.type_ }),
                list.map(c.methods, fn(m) { m.type_ }),
                c.interfaces,
              ]),
            )
            |> unify.apply(state),
          ),
          "super:"
            <> case c.superclass {
            None -> ""
            Some(parent) ->
              parent.identity.0
              <> "."
              <> parent.identity.1
              <> monotype.to_string(monotype.TupleType(parent.arguments))
          },
          ..list.append(
            list.map(c.fields, fn(f) {
              f.name.name
              <> ":"
              <> int.to_string(f.index)
              <> ":"
              <> f.owner.0
              <> "."
              <> f.owner.1
            }),
            list.append(
              c.behaviours,
              list.map(c.methods, fn(m) {
                m.name.name
                <> ":"
                <> m.owner.0
                <> "."
                <> m.owner.1
                <> ":"
                <> int.to_string(list.length(m.quantified))
              }),
            ),
          )
        ]
      }),
    unify.module_interfaces(state)
      |> list.sort(fn(a, b) {
        string.compare(
          a.module <> a.source.name.name,
          b.module <> b.source.name.name,
        )
      })
      |> list.flat_map(fn(i) {
        [
          "interface:" <> i.module <> "." <> i.source.name.name,
          "parameters:" <> int.to_string(list.length(i.parameters)),
          monotype.to_string(
            monotype.TupleType(list.append(
              list.map(i.parameters, fn(p) { p.1 }),
              list.map(i.methods, fn(m) { m.type_ }),
            ))
            |> unify.apply(state),
          ),
          ..list.map(i.methods, fn(m) {
            m.name.name <> ":" <> int.to_string(list.length(m.quantified))
          })
        ]
      }),

    unify.module_enums(state)
      |> list.sort(fn(a, b) {
        string.compare(
          a.module <> a.source.name.name,
          b.module <> b.source.name.name,
        )
      })
      |> list.map(fn(e) {
        "enum:"
        <> e.module
        <> "."
        <> e.source.name.name
        <> ":"
        <> string.join(nominal.variants(e), ",")
      }),
  ])
}

import gleam/option.{None, Some}

@external(erlang, "pooka_analysis_cache_ffi", "key")
pub fn key(
  source: module.SourceModule,
  imports: List(#(String, List(String))),
) -> BitArray

@external(erlang, "pooka_analysis_cache_ffi", "load")
pub fn load(
  directory: String,
  identity: String,
  key: BitArray,
) -> Result(module_infer.Module, Nil)

@external(erlang, "pooka_analysis_cache_ffi", "save")
pub fn save(
  directory: String,
  identity: String,
  key: BitArray,
  value: module_infer.Module,
) -> Nil
