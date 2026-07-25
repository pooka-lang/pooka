//// Some numbers can be settled before the program wakes.
////
//// Evaluate the supported integer expressions used by compile-time checks. Return
//// failure for unsupported or invalid expressions rather than executing arbitrary
//// user code.
////
//// ```text
//// constant integer expression -> Ok(value), or no constant value
//// ```

// SPDX-License-Identifier: Apache-2.0

import compiler/literal
import compiler/parser/ast
import gleam/int
import gleam/result

/// Evaluate the supported integer-only syntax without executing calls or reading
/// a runtime environment.
///
/// ```text
/// 2 * (3 + 1) -> Ok(8); a function call -> Error(Nil)
/// ```
pub fn integer(value: ast.Expression) -> Result(Int, Nil) {
  case value {
    ast.IntLiteral(value, _) -> literal.parse_int(value)
    ast.Unary(ast.Negate, operand, _) ->
      integer(operand) |> result.map(fn(value) { -value })
    ast.Binary(operator, left, right, _) -> {
      use left <- result.try(integer(left))
      use right <- result.try(integer(right))
      case operator {
        ast.Add -> Ok(left + right)
        ast.Subtract -> Ok(left - right)
        ast.Multiply -> Ok(left * right)
        ast.Remainder if right != 0 -> Ok(left % right)
        ast.BitAnd -> Ok(int.bitwise_and(left, right))
        ast.BitOr -> Ok(int.bitwise_or(left, right))
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}
