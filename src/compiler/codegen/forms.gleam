//// These are the little wooden pieces of an Erlang syntax tree.
////
//// Build a small portable term representation that the Erlang bridge decodes
//// before compile:forms. Distinguish an atom payload from an atom-expression
//// node: the latter also carries its tag and source line.
////
//// ```text
//// atom("ok", 1) decodes to {atom,1,ok}
//// ```

// SPDX-License-Identifier: Apache-2.0

pub type Term {
  Atom(String)
  Integer(Int)
  Floating(Float)
  Characters(String)
  Tuple(List(Term))
  Sequence(List(Term))
}

/// Attach the tag and source annotation before the node's payload. Atom payloads
/// are data; atom-expression nodes are tagged tuples.
///
/// ```text
/// node("integer", 7, [Integer(42)])
/// decodes to {integer,7,42}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#atomic-literals.
pub fn node(tag: String, line: Int, fields: List(Term)) -> Term {
  Tuple([Atom(tag), Integer(line), ..fields])
}

/// Build an atom expression, with its source line still pinned to it.
///
/// ```erlang
/// {atom,7,ok}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#atomic-literals.
pub fn atom(value: String, line: Int) -> Term {
  node("atom", line, [Atom(value)])
}

/// Build a variable expression or pattern. The Erlang variable name is an atom
/// inside the var node.
///
/// ```erlang
/// {var,7,'Pooka0'}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#patterns.
pub fn variable(name: String, line: Int) -> Term {
  node("var", line, [Atom(name)])
}

/// Make an unguarded clause. The empty guard list is intentional; callers needing
/// guards construct those clauses separately.
///
/// ```erlang
/// {clause,1,[{var,1,'X'}],[],[{var,1,'X'}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#clauses.
pub fn clause(patterns: List(Term), body: List(Term), line: Int) -> Term {
  node("clause", line, [Sequence(patterns), Sequence([]), Sequence(body)])
}

/// Build a module-qualified call from an expression node for the module and
/// another for the function name.
///
/// ```erlang
/// {call,1,{remote,1,{atom,1,erlang},{atom,1,abs}},[{integer,1,2}]}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
pub fn remote(
  module: String,
  name: String,
  args: List(Term),
  line: Int,
) -> Term {
  node("call", line, [
    node("remote", line, [atom(module, line), atom(name, line)]),
    Sequence(args),
  ])
}

/// Reference an already declared local function without calling it. The function
/// name and arity in this particular form are raw payloads.
///
/// ```erlang
/// {'fun',1,{function,identity,1}}
/// ```
///
/// Erlang abstract format: https://www.erlang.org/doc/apps/erts/absform.html#expressions.
pub fn local_fun(name: String, arity: Int, line: Int) -> Term {
  node("fun", line, [Tuple([Atom("function"), Atom(name), Integer(arity)])])
}
