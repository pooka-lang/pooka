//// Prove only the arithmetic we can actually see.
////
//// The small constant evaluator supplies integer facts to later analyses.
//// Precedence and signs must survive evaluation, while unknown or non-integer
//// expressions return no proof. A missing fact is safer than an invented
//// answer.
////
//// ```text
//// known integer expression -> a value
//// unknown expression       -> no static proof
//// ```

import compiler/constant
import support

pub fn integer_arithmetic_preserves_precedence_and_sign_test() {
  assert constant.integer(support.expression("2 + 3 * 4")) == Ok(14)
  assert constant.integer(support.expression("-(2 + 3) * 4")) == Ok(-20)
  assert constant.integer(support.expression("0x10 - 0b10")) == Ok(14)
  assert constant.integer(support.expression("17 % 5")) == Ok(2)
  assert constant.integer(support.expression("-17 % 5")) == Ok(-2)
  assert constant.integer(support.expression(
      "100000000000000000000 * 100000000000000000000",
    ))
    == Ok(10_000_000_000_000_000_000_000_000_000_000_000_000_000)
}

// An unproved expression is not zero. Keeping the absence of a fact explicit
// prevents downstream layout checks from relying on an invented constant.
pub fn unknown_and_non_integer_expressions_provide_no_proof_test() {
  assert constant.integer(support.expression("5 / 1")) == Error(Nil)
  assert constant.integer(support.expression("5 % 0")) == Error(Nil)
  assert constant.integer(support.expression("1.0 + 2.0")) == Error(Nil)
  assert constant.integer(support.expression("1 == 1")) == Error(Nil)
  assert constant.integer(support.expression("compute(1)")) == Error(Nil)
  assert constant.integer(support.expression("value")) == Error(Nil)
  assert constant.integer(support.expression("{ 8 }")) == Error(Nil)
}
