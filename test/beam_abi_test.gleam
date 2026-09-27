//// A foreign caller knocks on the same door as a Pooka program.
////
//// These calls are written in Erlang on purpose. They pin the public names and
//// receiver positions without using the Pooka compiler to produce both sides
//// of the conversation. Object internals remain behind their constructors.
////
//// ```erlang
//// P = 'pooka@interop@api':'$class@Point@new'(1, 2),
//// 'pooka@interop@api':'$class@Point@moved'(P, 10, 20).
//// ```

import builder/build
import support

pub fn erlang_calling_conventions_are_a_public_contract_test() {
  use directory <- support.with_directory("beam_public_abi")
  support.write(
    directory <> "/pooka.toml",
    "name = \"interop\"\nversion = \"1.0.0\"\n",
  )
  support.write(
    directory <> "/src/api.pooka",
    "module api\nclass Point(x: Int, y: Int) { moved(dx: Int, dy: Int) -> Point { Point(x + dx, y + dy) } }\nenum Unit { Metres, Feet }\nunit() { Unit.Feet }\nresult() { Ok(42) }\noption() { Some(42) }\nabsent() { None }\napply(f: fn(Int) -> Int, x: Int) { f(x) }\nactor Counter { var _value = 0\nbe add(amount: Int) { _value += amount\nNil }\nvalue() -> Int { _value } }\n",
  )
  support.write(
    directory <> "/src/main.pooka",
    "module main\nexternal Probe from erlang \"abi_probe\" { verify() -> Bool }\nmain() { echo { Probe.verify() } }",
  )
  support.write(
    directory <> "/ffi/abi_probe.erl",
    "-module(abi_probe).\n-export([verify/0]).\nverify() ->\n    M = 'pooka@interop@api',\n    P = M:'$class@Point@new'(1, 2),\n    Expected = M:'$class@Point@new'(11, 22),\n    Expected = M:'$class@Point@moved'(P, 10, 20),\n    'Unit.Feet' = M:unit(),\n    {ok, 42} = M:result(),\n    {some, 42} = M:option(),\n    none = M:absent(),\n    42 = M:apply(fun(X) -> X * 2 end, 21),\n    C = M:'$class@Counter@new'(),\n    M:'$class@Counter@add'(C, 42),\n    42 = M:'$class@Counter@value'(C),\n    true.\n",
  )
  let assert Ok(report) = build.build_production(directory)
  assert support.execute(report.directory, "pooka@interop@main", [])
    == Ok("True\n")
}
