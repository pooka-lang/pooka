//// Carry the settled types all the way to the tree.
////
//// Check that expression metadata applies later substitutions and
//// distinguishes identical offsets in different files. Failed inference cannot
//// become a typed AST. Warnings, however, must not discard an otherwise valid
//// tree or its inferred types.

import compiler/parser/ast
import compiler/typesystem/infer
import compiler/typesystem/module_infer
import compiler/typesystem/monotype as t
import compiler/typesystem/typed_ast
import compiler/typesystem/unify
import gleam/dict
import support
import utilities/location

pub fn expression_metadata_applies_later_constraints_test() {
  let syntax = support.expression("fn(value) { value + 1 }")
  let assert ast.AnonymousFunction(_, _, body, _) = syntax
  let assert [ast.ExpressionStatement(ast.Binary(_, left, _, _))] =
    body.statements
  let assert Ok(report) =
    infer.infer(syntax, dict.new(), unify.new(), support.path)
  assert report.diagnostics == []
  assert unify.expression_type(
      report.state,
      support.path,
      ast.expression_span(left),
    )
    == Ok(t.IntType)
  assert unify.expression_type(
      report.state,
      support.path,
      ast.expression_span(syntax),
    )
    == Ok(t.FunctionType([t.IntType], t.IntType))
}

// Two files may use the same byte offset for unrelated expressions. Metadata
// lookup needs source identity as well as the local position.
pub fn metadata_distinguishes_paths_with_identical_offsets_test() {
  let span = location.span("value", 0, 5)
  let state =
    unify.new()
    |> unify.remember_expression("src/one.pooka", span, t.IntType)
    |> unify.remember_expression("src/two.pooka", span, t.StringType)
  assert unify.expression_type(state, "src/one.pooka", span) == Ok(t.IntType)
  assert unify.expression_type(state, "src/two.pooka", span) == Ok(t.StringType)
  assert unify.expression_type(state, "src/unknown.pooka", span) == Error(Nil)
}

pub fn typed_ast_rejects_failed_inference_test() {
  let syntax = support.parse("module main\nmain() { 1 + True }")
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  let assert Error(diagnostics) =
    typed_ast.checked(syntax, inferred, support.path)
  assert diagnostics != []
}

pub fn typed_ast_accepts_warnings_without_losing_types_test() {
  let syntax =
    support.parse("module main\nmain() { match True { _ -> 1\nTrue -> 2 } }")
  let assert Ok(inferred) =
    module_infer.infer(syntax, dict.new(), unify.new(), support.path)
  let assert Ok(typed) = typed_ast.checked(syntax, inferred, support.path)
  assert typed_ast.syntax(typed) == syntax
  let assert [function] = typed_ast.inferred(typed).functions
  assert function.type_ == t.FunctionType([], t.IntType)
}
