# BEAM interop

Pooka is a newcomer on an old street. Erlang has lived here for decades, Elixir moved in with a lot of plants, and Gleam keeps a very tidy garden. The good news is that everyone speaks the same language underneath: BEAM modules, functions and values.

So Pooka code can be called from all of them, and they can be called from Pooka. This page shows how, with small examples.

## Calling Erlang, Elixir and Gleam from Pooka

Use `external`, and write down the type of each function you need:

```pooka
module main

external Lists from erlang "lists" {
  reverse(items: List(a)) -> List(a)
}

external Clock from erlang "erlang" {
  system_time() -> Int
}

main() {
  echo Lists.reverse([1, 2, 3])
  echo Clock.system_time()
}
```

The languages are `erlang`, `elixir`, `gleam` and `lfe`. Your own foreign files go in the project's `ffi/` folder, as `.erl`, `.ex`, `.gleam` or `.lfe` files.

Pooka trusts the types you write here. Keep externals small, and wrap them in ordinary Pooka functions, so the rest of your code never has to wonder.

## Calling Pooka from other languages

### 1. Build it

```sh
pooka build --target prod
```

This compiles your package and its dependencies into `build/prod/erlang`, one folder per package, without tests. Libraries do not need a `main()`.

Make those folders visible to the BEAM, for example with `ERL_LIBS`:

```sh
export ERL_LIBS="$PWD/build/prod/erlang"
```

Once your package is [published on Hex](publishing.md), this step is not needed: rebar3, Mix and Gleam download and build it like any other package.

### 2. Find the names

Here is a small Pooka library, in a package called `shapes`:

```pooka
module shapes

class Shape {}

class Circle(radius: Float) is Shape

class Rect(width: Float, height: Float) is Shape

class Point(x: Int, y: Int) {
  moved(dx: Int, dy: Int) -> Point {
    Point(x + dx, y + dy)
  }
}

enum Unit {
  Metres,
  Feet
}

actor Counter {
  var _value = 0

  be add(amount: Int) {
    _value += amount
  }

  value() -> Int {
    _value
  }
}

greet(name: String) -> String {
  "Hello, " + name + "!"
}

area(shape: Shape) -> Float {
  match shape {
    Circle(r) -> 3.0 * r * r
    Rect(w, h) -> w * h
  }
}

circle(radius: Float) -> Result(Shape, String) {
  match radius < 0.0 {
    True -> Error("negative radius")
    False -> Ok(Circle(radius))
  }
}

apply_twice(f: fn(Int) -> Int, x: Int) -> Int {
  f(f(x))
}
```

And this is how it looks from the other side of the fence:

| In Pooka | On the BEAM |
| --- | --- |
| Module `shapes` in package `shapes` | Module `'pooka@shapes@shapes'` |
| Module `library/shelf` in package `night_library` | Module `'pooka@night_library@library@shelf'` |
| Function `greet(name)` | `greet(Name)` |
| Constructor `Point(1, 2)` | `'$class@Point@new'(1, 2)` |
| Method `point.moved(1, 1)` | `'$class@Point@moved'(Point, 1, 1)`: the object comes first |
| Actor `Counter()` | `'$class@Counter@new'()` |
| Actor method `counter.add(5)` | `'$class@Counter@add'(Counter, 5)` |
| Enum variant `Unit.Feet` | The atom `'Unit.Feet'` |

Private declarations, the ones starting with `_`, are not exported.

### 3. Pass the values

| Pooka | BEAM |
| --- | --- |
| `Int`, `Float` | integer, float |
| `String` | UTF-8 binary |
| `Bool` | `true`, `false` |
| `Nil` | `nil` |
| `List(a)` | list |
| `#(a, b)` | tuple `{A, B}` |
| `Ok(v)`, `Error(e)` | `{ok, V}`, `{error, E}` |
| `Some(v)`, `None` | `{some, V}`, `none` |
| `fn(Int) -> Int` | a fun of one argument |
| `BitArray` | binary or bitstring |
| Objects and actors | Opaque: make them with constructors, use them with methods |

`Result` and `Option` look exactly like Gleam's, so they cross between the two without any translation.

Treat objects and actors as sealed envelopes. Make them with their constructors, use them through their methods, and never build or take them apart by hand. What is inside may change between versions; the names above will not.

## Examples

### Erlang

```erlang
M = 'pooka@shapes@shapes',
<<"Hello, Erlang!">> = M:greet(<<"Erlang">>),

P = M:'$class@Point@new'(1, 2),
Moved = M:'$class@Point@moved'(P, 1, 1),

6.0 = M:area(M:'$class@Rect@new'(2.0, 3.0)),
{error, <<"negative radius">>} = M:circle(-1.0),
18 = M:apply_twice(fun(X) -> X * 3 end, 2),

C = M:'$class@Counter@new'(),
M:'$class@Counter@add'(C, 5),
5 = M:'$class@Counter@value'(C).
```

### Elixir

```elixir
shapes = :"pooka@shapes@shapes"

shapes.greet("Elixir")
#=> "Hello, Elixir!"

point = apply(shapes, :"$class@Point@new", [1, 2])
apply(shapes, :"$class@Point@moved", [point, 10, 20])

shapes.circle(-1.0)
#=> {:error, "negative radius"}

shapes.apply_twice(fn x -> x * 3 end, 2)
#=> 18
```

Enum variants are atoms with a dot in them, so they need quotes: `:"Unit.Feet"`.

If you use Mix with `ERL_LIBS`, set `prune_code_paths: false` in `project/0`. Otherwise Mix removes paths it did not add itself.

### Gleam

Declare objects as opaque types, and bind each function with `@external`:

```gleam
pub type Shape

pub type Point

@external(erlang, "pooka@shapes@shapes", "greet")
pub fn greet(name: String) -> String

@external(erlang, "pooka@shapes@shapes", "circle")
pub fn circle(radius: Float) -> Result(Shape, String)

@external(erlang, "pooka@shapes@shapes", "area")
pub fn area(shape: Shape) -> Float

@external(erlang, "pooka@shapes@shapes", "$class@Point@new")
pub fn point(x: Int, y: Int) -> Point

@external(erlang, "pooka@shapes@shapes", "$class@Point@moved")
pub fn moved(point: Point, dx: Int, dy: Int) -> Point
```

```gleam
let assert Ok(c) = circle(1.0)
area(c)
// 3.0
```

### LFE

```lisp
(let* ((shapes 'pooka@shapes@shapes)
       (point (call shapes '$class@Point@new 1 2)))
  (call shapes 'greet #"LFE")
  (call shapes '$class@Point@moved point 1 1))
```

The enum variant `Unit.Feet` is written `'|Unit.Feet|` in LFE.

## A working example

The `BEAM-Interop` examples, next to the compiler, call the same `shapes` library from Erlang, Elixir, Gleam and LFE, with tests for each one, and an OTP release that starts it alongside the standard library.

Different languages, one street. Everybody waves.
