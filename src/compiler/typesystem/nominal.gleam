//// Two classes may share a spelling without sharing an identity.
////
//// Carry module-qualified class, actor, enum and interface metadata. Instantiate
//// declared generic parameters while preserving the owner of each inherited field
//// and method.
////
//// ```text
//// package/a.User and package/b.User are different identities
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/parser/ast
import compiler/typesystem/monotype.{type Type}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None}

pub type Identity =
  #(String, String)

pub type Field {
  Field(name: ast.Name, type_: Type, index: Int, owner: Identity)
}

pub type Method {
  Method(name: ast.Name, type_: Type, quantified: List(Int), owner: Identity)
}

pub type Superclass {
  Superclass(identity: Identity, arguments: List(Type))
}

pub type Class {
  Class(
    module: String,
    path: String,
    runtime_module: String,
    source: ast.Class,
    parameters: List(#(Int, Type)),
    fields: List(Field),
    constructor: Type,
    constructor_quantified: List(Int),
    methods: List(Method),
    ready: Bool,
    superclass: Option(Superclass),
    interfaces: List(Type),
    actor: Bool,
    behaviours: List(String),
  )
}

pub fn identity(class: Class) -> Identity {
  #(class.module, class.source.name.name)
}

pub fn type_(class: Class) -> Type {
  monotype.Nominal(
    class.module,
    class.source.name.name,
    kind(class),
    list.map(class.parameters, fn(parameter) { parameter.1 }),
  )
}

pub fn instantiate(value: Type, class: Class, arguments: List(Type)) -> Type {
  let replacements =
    list.zip(class.parameters, arguments)
    |> list.map(fn(pair) { #(pair.0.0, pair.1) })
    |> dict.from_list
  monotype.replace_rigids(value, replacements)
}

pub fn function_name(class: String, method: String) -> String {
  "$class@" <> class <> "@" <> method
}

pub fn tag(module: String, class: String) -> String {
  "pooka@class@" <> module <> "@" <> class
}

pub fn has_constructor(class: Class) -> Bool {
  list.any(class.source.members, fn(member) {
    case member {
      ast.ConstructorMember(_) -> True
      _ -> False
    }
  })
}

pub fn own_fields(class: Class) -> List(Field) {
  list.filter(class.fields, fn(field) { field.owner == identity(class) })
}

pub type Enum {
  Enum(module: String, path: String, source: ast.Enum)
}

pub fn enum_identity(enum: Enum) -> Identity {
  #(enum.module, enum.source.name.name)
}

pub fn enum_type(enum: Enum) -> Type {
  monotype.Nominal(enum.module, enum.source.name.name, monotype.EnumKind, [])
}

pub fn variants(enum: Enum) -> List(String) {
  list.map(enum.source.variants, fn(variant) { variant.name.name })
}

pub fn variant_atom(enum: String, variant: String) -> String {
  enum <> "." <> variant
}

pub type Interface {
  Interface(
    module: String,
    path: String,
    source: ast.Interface,
    parameters: List(#(Int, Type)),
    methods: List(Method),
  )
}

pub fn instantiate_interface(
  value: Type,
  interface: Interface,
  arguments: List(Type),
) -> Type {
  let replacements =
    list.zip(interface.parameters, arguments)
    |> list.map(fn(pair) { #(pair.0.0, pair.1) })
    |> dict.from_list
  monotype.replace_rigids(value, replacements)
}

pub fn kind(class: Class) -> monotype.NominalKind {
  case class.actor {
    True -> monotype.ActorKind
    False -> monotype.ClassKind
  }
}

pub fn actor_class(actor: ast.Actor) -> ast.Class {
  ast.Class(
    actor.documentation,
    actor.name,
    actor.type_parameters,
    None,
    actor.interfaces,
    list.map(actor.members, fn(member) {
      case member {
        ast.BehaviourMember(method) -> ast.MethodMember(method)
        _ -> member
      }
    }),
    actor.span,
  )
}
