# A Tour of Pooka

It is late. The kettle has just finished complaining, the rain has settled into a steady sort of typing against the window, and somewhere in your terminal a small creature is waiting to be introduced.

In the old stories, a pooka is a shape-shifter. It might be a horse at midnight, a goat by the river, a black dog on the road home. It is never quite one thing, and it is rarely unkind to people who are polite to it.

The language is a little like that. It is a statically typed language for the BEAM, the patient virtual machine underneath Erlang, Elixir and Gleam. Its values can change shape: a `Fox` can travel as a `Creature`, a `Moon` can stand in for anything `Glowing`. But underneath the shapes, the compiler keeps careful notes, and it will not let a fox pretend to be a teapot.

This tour walks through the language one small room at a time. Each section has a little story, a piece of code, and the rules you need to remember. You can read it straight through, like a short book, or wander in and out of rooms as you like.

> A language is a house. A tour is somebody holding the lantern while you look around.

If you have not installed Pooka yet, the [installation guide](install.md) will help. If you would like to make a project and run it first, [getting started](getting_started.md) is a short walk.

## Contents

1. [The front door](#chapter-1-the-front-door): hello world, modules, numbers, strings, bools, bindings, lists and tuples
2. [Functions, the lonely creatures](#chapter-2-functions-the-lonely-creatures): functions, privacy, anonymous functions, generics and pipes
3. [Choosing a path](#chapter-3-choosing-a-path): `match`, patterns, guards, recursion and loops
4. [Shapes of things](#chapter-4-shapes-of-things): `Nil`, enums, classes, methods, `Option`, `Result` and bit arrays
5. [Families and promises](#chapter-5-families-and-promises): inheritance, class patterns and interfaces
6. [Actors, the ones with mailboxes](#chapter-6-actors-the-ones-with-mailboxes)
7. [When things go wrong](#chapter-7-when-things-go-wrong): `?`, `let assert`, `assert`, `panic`, `todo` and `echo`
8. [Visiting the neighbours](#chapter-8-visiting-the-neighbours): external functions
9. [The pantry](#chapter-9-the-pantry): the standard library
10. [Before you go](#before-you-go)

---

## Chapter 1: The front door

### Hello, world

Every journey starts with somebody saying hello into the dark and hoping the dark says something back.

```pooka
module main

import pooka/io

main() {
  let assert Ok(_) = io.println("Hello, world")
}
```

A few things are already happening here.

- Every file begins with `module`, followed by its name. The name matches the file: `src/main.pooka` declares `module main`.
- `import pooka/io` brings in the `io` module from the standard library. You call its functions with the module name in front: `io.println`.
- `main()` is where a program starts when you type `pooka run`.
- Printing can fail. A terminal can disappear while you are talking to it. So `io.println` returns a `Result`, and `let assert Ok(_) = ...` says: *I expect this to work, and if it does not, please stop the program.* We will meet `Result` properly in [chapter 4](#result).

There is a gentler way to look at a value while you work, called `echo`:

```pooka
module main

main() {
  echo "Hello, world"
}
```

`echo` prints the value with the file and line it came from, then gives the value back unchanged. It is a lantern, not a speaker. Use it to see what is happening, then take it away before you publish.

### Modules and imports

A module is a room. A file is a module. A folder is a corridor of rooms.

```text
src/
  main.pooka              module main
  library/shelf.pooka     module shelf, imported as library/shelf
```

```pooka
module main

import pooka/string
import pooka/list.{map as each}

main() {
  echo string.uppercase("quiet")
  echo each([1, 2, 3], fn(n) { n * 2 })
}
```

- `import pooka/string` makes `string.uppercase` available.
- The braces import names directly, so they can be used without the module in front. `as` gives them another name while they are visiting.
- Imports that are never used get a small warning, the way a tidy librarian notices a borrowed book still sitting on your desk.

### Ints

Integers are whole numbers. On the BEAM they can grow as large as your memory allows, which is a comforting thing to know at 2 AM.

```pooka
module main

main() {
  echo 1 + 2 * 3
  echo 1_000_000
  echo 0xFF + 0b1010 + 0o17
  echo 7 % 3
}
```

- The usual operators work: `+`, `-`, `*` and `%`. Division is special, and has [its own section](#division).
- Underscores make large numbers easier to read. `0x`, `0b` and `0o` write hexadecimal, binary and octal.
- `&` and `|` work on the bits of an integer. The `pooka/bit` module has the rest.

### Floats

Floats are numbers with a decimal point. They are a little less exact than integers, the way a watercolour is a little less exact than a pencil drawing.

```pooka
module main

import pooka/int

main() {
  echo 1.5 + 2.25
  echo 7.0 / 2
  echo int.to_float(3)
}
```

- Floats use the same operators as integers.
- Every operator except `/` wants both sides to be the same type. `1 + 2.0` is refused. The compiler does not guess which one you meant, so convert one side yourself with `int.to_float` or `float.round`.
- `int.to_float` returns a `Result`, because a very large integer may not fit in a float. That is why the last line above prints `Ok(3.0)`.

### Division

Division is where whole numbers sometimes stop being whole. Seven biscuits shared between two people is three and a half biscuits each, and nobody wants to be the one who gets three.

So in Pooka, as in Python, `/` always gives a `Float`:

```pooka
module main

import pooka/int

main() {
  echo 7 / 2
  echo -7 / 2
  echo 4 / 2
  echo 7.0 / 2
  echo int.divide(7, 2)
}
```

- `7 / 2` is `3.5`, and `-7 / 2` is `-3.5`.
- `4 / 2` is `2.0`, not `2`. The answer is a `Float` even when it happens to be whole, because the compiler has to know the type before the program runs, long before it knows the numbers.
- `/` accepts any mix of `Int` and `Float`.
- When you want a whole-number answer, use `int.divide`. It cuts toward zero, so `int.divide(7, 2)` is `Ok(3)`, and `int.divide(-7, 2)` is `Ok(-3)`. `int.remainder` gives what is left over.
- Dividing by zero with `/` stops the program. `int.divide` returns `Error(int.MathError.DivisionByZero)` instead, a polite letter rather than a slammed door.

### Equality and comparison

```pooka
module main

main() {
  echo 1 == 1
  echo "owl" != "crow"
  echo [1, 2] == [1, 2]
  echo 3 < 4
  echo 2.5 >= 1.0
}
```

- `==` and `!=` compare any two values of the same type, by what they contain. Two lists with the same items are equal, even if they were made on different evenings.
- `<`, `<=`, `>` and `>=` compare numbers only. To put strings in order, use the [`pooka/order`](#chapter-9-the-pantry) tools.

### Strings

Strings are text, stored as UTF-8. They are joined with `+`.

```pooka
module main

import pooka/string

main() {
  echo "tea" + " and " + "toast"
  echo "a tab\there, a quote \", a moon \u{1F319}"
  echo string.length("héllo")
  echo string.split("oak,pine,birch", ",")
}
```

- Escapes: `\n`, `\t`, `\"`, `\\` and `\u{...}` for any Unicode code point.
- A string stays on one line. For longer text, join smaller pieces, or use `string.join` on a list.
- The `pooka/string` module has the tools: `trim`, `split`, `replace`, `contains`, `uppercase` and friends.

### Bools

```pooka
module main

main() {
  echo True && False
  echo True || False
  echo !False
}
```

A `Bool` is `True` or `False`. `&&` and `||` stop early: if the left side already decides the answer, the right side is never asked.

### Let bindings

`let` gives a name to a value.

```pooka
module main

main() {
  let tea = "chamomile"
  let cups = 2
  let cups = cups + 1
  echo #(tea, cups)
}
```

A name, once given, never changes its mind. Writing `let cups = cups + 1` does not change the old `cups`. It makes a new name that happens to share the old one's coat, and the old value is left exactly as it was.

> In Pooka, values are kept like old letters. You can write a new one. You cannot rewrite the one you already sent.

If you need to ignore a value, give it to `_`. A name starting with `_`, like `_unused`, tells the next reader that you meant to leave it alone.

### Type annotations

Pooka infers types on its own, most of the time. But you can write them down, the way you might label a jar even though you know what is in it.

```pooka
module main

main() {
  let name: String = "Peregrine"
  let ages: List(Int) = [3, 7]
  echo #(name, ages)
}
```

- Bindings, parameters and fields use `:`.
- Return types use `->`, as you will see in the next chapter.
- If an annotation and the code disagree, the compiler will show you both and ask which one is telling the truth.

### Blocks

A block is a pair of braces holding a few lines. Its value is the value of its last line.

```pooka
module main

main() {
  let tea = {
    let leaves = 2
    let water = 250
    water / leaves
  }
  echo tea
}
```

Names made inside a block stay inside it, like a cat that refuses to leave the airing cupboard.

### Lists

A list holds many values of one type, in order.

```pooka
module main

import pooka/list

main() {
  let birds = ["finch", "owl", "heron"]
  echo list.length(birds)
  echo list.first(birds)
  echo list.prepend(birds, "wren")
  echo list.reverse(birds)
}
```

Lists are immutable. `list.prepend` does not change `birds`. It gives back a new list with `"wren"` at the front, and the old list carries on, undisturbed, as if nothing happened. Adding to the front is cheap. Adding to the end has to walk the whole list first.

### Tuples

A tuple is a small parcel of a fixed number of values, which may have different types.

```pooka
module main

main() {
  let book = #("The Night Garden", 1974)
  let #(title, year) = book
  echo title
  echo year
}
```

Open a tuple by matching on its shape, as with `let #(title, year) = book`. Tuples are good for passing two or three things together. When the parcel gets heavier, or needs a name, a [class](#classes) is kinder.

### Comments

```pooka
//// The first lines of a file describe the module. They come before `module`.

module main

/// Three slashes describe the declaration below them.
main() {
  // Two slashes are notes for whoever reads this next.
  echo "hello"
}
```

`pooka docs` turns `////` and `///` comments into documentation pages. `//` comments stay in the code, like pencil notes in the margin.

---

## Chapter 2: Functions, the lonely creatures

### Functions

I think functions are lonely. They spend their whole lives waiting to be called. So let us call one.

```pooka
module main

/// Pour some tea for a guest.
pour(guest: String, cups: Int) -> String {
  guest + " receives " + describe(cups)
}

describe(cups: Int) -> String {
  match cups {
    1 -> "one cup"
    _ -> "several cups"
  }
}

main() {
  echo pour("Finch", 2)
}
```

- A function is a name, some parameters and a body. There is no keyword in front.
- The last expression in the body is the answer. There is no `return`.
- Return types come after `->`. You may leave them out and the compiler will work them out, but writing them down is a kindness to the next reader.
- Functions can be declared in any order. `pour` may call `describe` even though `describe` lives further down the page.

### Private functions

A function whose name starts with `_` is private. Other modules cannot import it, not even under a different name.

```pooka
module main

/// The public door.
greet(name: String) -> String {
  _polish(name) + ", good evening."
}

_polish(name: String) -> String {
  "Dear " + name
}

main() {
  echo greet("Finch")
}
```

Everything else is public. This rule works the same way for classes, fields and methods.

### Anonymous functions

Sometimes a function only needs to exist for a moment, like a note slipped under a door.

```pooka
module main

main() {
  let add = fn(a: Int, b: Int) -> Int { a + b }
  let double = fn(n) { n * 2 }
  echo add(1, 2)
  echo double(21)
}
```

Anonymous functions start with `fn`. They can see the names around them when they are made, and they carry those names with them wherever they go.

### Higher-order functions

A function can be handed to another function, like a key left with a neighbour.

```pooka
module main

twice(value: Int, step: fn(Int) -> Int) -> Int {
  step(step(value))
}

add_one(n: Int) -> Int {
  n + 1
}

main() {
  echo twice(5, add_one)
  echo twice(5, fn(n) { n * 10 })
}
```

The type of a function is written `fn(Int) -> Int`: what goes in, and what comes out. A named function like `add_one` can be passed by name. So can a module's function, like `int.to_string`.

### Generic functions

Some functions do not mind what they carry.

```pooka
module main

apply(value: a, transform: fn(a) -> b) -> b {
  transform(value)
}

main() {
  echo apply(3, fn(n) { n + 1 })
  echo apply("owl", fn(word) { word + "s" })
}
```

Lowercase names in types, like `a` and `b`, are type variables. They mean *some type, decided each time the function is called*. Here, `a` is `Int` the first time and `String` the second. Within one call, every `a` must be the same `a`.

### Pipelines

Reading `c(b(a(x)))` is like reading a sentence backwards. Pipes let you write it in the order it happens.

```pooka
module main

import pooka/int
import pooka/list
import pooka/string

main() {
  [3, 1, 2]
  |> list.sort
  |> list.map(int.to_string)
  |> string.join(", ")
  |> echo
}
```

`x |> f(y)` means `f(x, y)`: the value on the left goes in as the first argument. The standard library puts the main value first in nearly every function, so long chains read naturally from top to bottom. `echo` fits into a pipe too, so you can peek between steps.

---

## Chapter 3: Choosing a path

### Match

Sooner or later a program reaches a fork in the road. `match` looks at a value, compares it with each pattern from top to bottom, and follows the first one that fits.

```pooka
module main

describe(owls: Int) -> String {
  match owls {
    0 -> "an empty branch"
    1 -> "a single owl"
    _ -> "a parliament"
  }
}

main() {
  echo describe(0)
  echo describe(12)
}
```

`_` matches anything, and keeps nothing. It is the patient waiter at the end of the line.

`match` must cover every possible value. If you forget a case, the compiler will tell you which one, before the program ever runs. This is the most considerate thing it does.

### Variables and guards

A pattern can give a name to what it finds, and a guard can ask one more question.

```pooka
module main

classify(temperature: Int) -> String {
  match temperature {
    0 -> "freezing, exactly"
    t if t < 0 -> "the pond is a mirror"
    t if t > 30 -> "even the cat is tired"
    _ -> "a pleasant evening"
  }
}

main() {
  echo classify(-4)
  echo classify(18)
}
```

A guard comes after `if`. The branch is taken only when the pattern fits *and* the guard is `True`.

### Strings and tuples

Patterns can be strings, numbers, bools, tuples, and anything else that has a shape.

```pooka
module main

weather(sky: String, wind: Bool) -> String {
  match #(sky, wind) {
    #("clear", False) -> "a night for stargazing"
    #("clear", True) -> "hold on to your hat"
    #(_, True) -> "the trees are talking"
    _ -> "a night for reading"
  }
}

main() {
  echo weather("clear", False)
  echo weather("cloudy", True)
}
```

Pooka has no `|` between patterns. If two patterns should do the same thing, write two branches. It is a little more typing, and a little more honest.

### Lists

List patterns describe the start of a list. `..rest` names everything after it.

```pooka
module main

describe(birds: List(String)) -> String {
  match birds {
    [] -> "the feeder is empty"
    [one] -> "only " + one + " came today"
    [first, ..] -> first + " arrived first, with friends"
  }
}

main() {
  echo describe([])
  echo describe(["wren"])
  echo describe(["robin", "wren", "finch"])
}
```

### Recursion

Pooka has no `for` loop that counts on its fingers. Instead, a function can call itself on a smaller piece of the problem, the way you might read a long letter one page at a time.

```pooka
module main

total(cups: List(Int)) -> Int {
  match cups {
    [] -> 0
    [first, ..rest] -> first + total(rest)
  }
}

main() {
  echo total([2, 1, 3])
}
```

Every recursive function needs a way to stop. Here, the empty list is the last page.

### Loops

When you want to visit each item in turn, there is `loop ... in`.

```pooka
module main

main() {
  loop bird in ["owl", "finch", "heron"] {
    echo bird
  }
}
```

A loop can also look for something and come back with it. `break` leaves the loop, carrying a value. `continue` skips to the next item.

```pooka
module main

main() {
  let first_large = loop n in [3, 8, 12, 20] {
    match n > 10 {
      True -> break n
      False -> continue
    }
  }
  echo first_large
}
```

A loop that promises a value must find one. If it runs out of items without reaching `break`, the program stops with *the loop ended without breaking with a value*. When the thing you are looking for might not be there, `list.find` returns an [`Option`](#option) instead.

A `loop` with no `in` goes round and round until something says `break`.

---

## Chapter 4: Shapes of things

### Nil

`Nil` is the value that means *nothing in particular*. A function with nothing useful to say, such as one that only prints, returns `Nil`.

### Enums

An enum is a small, closed family of names.

```pooka
module main

enum Weather {
  Sunny,
  Rainy,
  Foggy
}

plan(weather: Weather) -> String {
  match weather {
    Weather.Sunny -> "walk to the harbour"
    Weather.Rainy -> "write a parser"
    Weather.Foggy -> "listen for the lighthouse"
  }
}

main() {
  echo plan(Weather.Rainy)
}
```

A variant always travels with its family name: `Weather.Rainy`, never just `Rainy`. Because the family is closed, `match` knows every member, and will remind you if a new one is added and forgotten.

### Classes

A class gives a name and a shape to some values that belong together. The short form fits on one line.

```pooka
module main

class Book(title: String, pages: Int)

main() {
  let book = Book("Moths of the Coast", 212)
  echo book.title
  echo book.pages
  echo book == Book("Moths of the Coast", 212)
}
```

- `Book(...)` makes a new book.
- `book.title` reads a field.
- Objects are immutable. Two books with the same fields are equal.

### Methods

A class can also hold functions, called methods. Inside a method, the object's fields are just there, like furniture in your own room.

```pooka
module main

import pooka/int

class Point(x: Int, y: Int) {
  moved(dx: Int, dy: Int) -> Point {
    Point(x + dx, y + dy)
  }

  describe() -> String {
    "(" + int.to_string(x) + ", " + int.to_string(y) + ")"
  }
}

main() {
  let home = Point(1, 2)
  echo home.moved(3, 0).describe()
  echo home.describe()
}
```

`moved` does not change `home`. It makes a new point a little further along, and the old one stays where it was, waiting by the door.

A method can also be held without calling it. `let say = home.describe` keeps the method with its object, ready for later: `say()`.

### Constructors

The short form is enough for most classes. When an object needs a little preparation before it is ready, write the fields and a `new` constructor yourself.

```pooka
module main

class Lantern {
  let room: String
  let brightness: Int

  new(room: String) {
    self.room = room
    self.brightness = 3
  }

  describe() -> String {
    "a lantern in the " + room
  }
}

main() {
  let lantern = Lantern("attic")
  echo lantern.brightness
  echo lantern.describe()
}
```

- `let` declares a field, with its type.
- `new` sets every field through `self`, exactly once. If a field is forgotten, the compiler will notice before the lantern is ever lit.
- You can call the constructor as `Lantern("attic")` or `Lantern.new("attic")`. The second form is useful when you want to pass the constructor itself to another function.

### Generic classes

A class can hold values of any type, decided when it is made.

```pooka
module main

class Jar(contents: a) {
  relabel(change: fn(a) -> b) -> Jar(b) {
    Jar(change(contents))
  }
}

main() {
  let jar = Jar(12)
  echo jar.contents
  echo jar.relabel(fn(n) { n * 2 }).contents
}
```

A `Jar(Int)` holds an `Int`. A `Jar(String)` holds a `String`. A jar never forgets what is inside it.

### Option

Some things might be there, or might not. A lost glove. A reply to a letter. `Option` is how Pooka says *maybe*.

```pooka
module main

nickname(name: String) -> Option(String) {
  match name {
    "Peregrine" -> Some("Perry")
    _ -> None
  }
}

main() {
  echo nickname("Peregrine")
  echo nickname("Finch")
}
```

`Some(value)` holds a value. `None` holds nothing. Because the type says `Option`, the compiler asks you to handle both, so nobody is surprised by an empty envelope.

`Option`, `Some` and `None` are always available. You do not need to import them.

### Result

`Result` is for things that can fail. It holds either `Ok(value)` or `Error(reason)`.

```pooka
module main

import pooka/int

parse_age(text: String) -> Result(Int, String) {
  match int.parse(text) {
    Ok(age) if age >= 0 -> Ok(age)
    Ok(_) -> Error("ages do not go backwards")
    Error(_) -> Error("that is not a number")
  }
}

main() {
  echo parse_age("41")
  echo parse_age("-3")
  echo parse_age("owl")
}
```

An error in Pooka is not a crash. It is a letter, delivered in a clearly labelled envelope. You open it with `match`, decide what to do, and the program carries on. [Chapter 7](#chapter-7-when-things-go-wrong) has a few shortcuts for opening many envelopes at once.

### Bit arrays

Sometimes you need to read bytes directly: a file header, a network packet, a message from an old machine. Bit arrays describe bytes the way a pattern describes a list.

```pooka
module main

import pooka/bit_array

read_letter(bytes: BitArray) -> Result(String, String) {
  match bytes {
    <<1:8, length:16, body:bytes-size(length), _:bits>> ->
      match bit_array.to_string(body) {
        Ok(text) -> Ok(text)
        Error(_) -> Error("the letter is not text")
      }
    _ -> Error("the envelope is damaged")
  }
}

main() {
  let letter = <<1:8, 3:16, "owl":utf8>>
  echo read_letter(letter)
  echo read_letter(<<9>>)
}
```

`1:8` is the number 1 in 8 bits. `length:16` reads 16 bits and calls them `length`. `body:bytes-size(length)` then reads exactly that many bytes, and `bit_array.to_string` turns them back into text, if they are text. The `pooka/bit_array` module has helpers for building, slicing and converting them.

---

## Chapter 5: Families and promises

### Inheritance

A pooka changes shape, but it is still a pooka underneath. Classes can do the same. A class can extend another with `is`, and inherit its fields and methods.

```pooka
module main

import pooka/list

class Creature {
  let name: String

  new(name: String) {
    self.name = name
  }

  greet() -> String {
    "..."
  }

  introduce() -> String {
    name + " says " + greet()
  }
}

class Owl is Creature {
  new(name: String) {
    super.new(name)
  }

  greet() -> String {
    "hoo"
  }
}

class Fox is Creature {
  let tails: Int

  new(name: String, tails: Int) {
    super.new(name)
    self.tails = tails
  }

  greet() -> String {
    "yip"
  }
}

main() {
  let neighbours: List(Creature) = [Owl("Ada"), Fox("Ren", 9)]
  echo list.map(neighbours, fn(creature) { creature.introduce() })
}
```

- `class Owl is Creature` makes `Owl` a kind of `Creature`.
- The constructor calls `super.new(...)` to prepare the inherited fields first.
- `Owl` replaces `greet` with its own version. When `introduce` calls `greet()`, each creature answers in its own voice.
- An `Owl` can be used wherever a `Creature` is expected, even inside a list, an `Option` or a `Result`. It does not work the other way round: a `Creature` is never quietly assumed to be an `Owl`.

A family can also be declared briefly, when the parent only gives the family a name:

```pooka
module main

class Shape {}

class Circle(radius: Float) is Shape

class Rect(width: Float, height: Float) is Shape
```

### Class patterns

To find out which shape a creature is wearing tonight, `match` on it.

```pooka
module main

class Shape {}

class Circle(radius: Float) is Shape

class Rect(width: Float, height: Float) is Shape

area(shape: Shape) -> Float {
  match shape {
    Circle(r) -> 3.14159 * r * r
    Rect(w, h) -> w * h
  }
}

main() {
  echo area(Circle(1.0))
  echo area(Rect(2.0, 3.0))
}
```

The compiler knows the whole family, so it knows that a circle and a rectangle are all the shapes there are. Leave one out and it will remind you.

A class pattern lists every field in order, starting with the inherited ones. For our creatures, a fox would be matched as `Fox(name, tails)`. Use `_` for the fields you do not need. Guards work here too: `Fox(_, tails) if tails > 8 -> "an old fox"`.

### Interfaces

An interface is a promise. It lists methods, and a class that declares it with `with` must keep the promise.

```pooka
module main

interface Glowing {
  glow() -> String
}

class Firefly with Glowing {
  new() {}

  glow() -> String {
    "blink"
  }
}

class Moon(phase: String) with Glowing {
  glow() -> String {
    "a " + phase + " glow"
  }
}

shine(light: Glowing) -> String {
  light.glow()
}

main() {
  echo shine(Firefly())
  echo shine(Moon("silver"))
}
```

A class has to say `with Glowing` out loud. Having a method called `glow` by coincidence is not enough. As the compiler puts it, a matching silhouette is not a signed agreement.

Interfaces can be generic, like `interface Reader(a) { read() -> a }`, and a class may make several promises at once: `class Lamp with Glowing, Switchable`. A class can extend a parent and keep promises in the same breath: `class Owl is Creature with Glowing`. Actors can keep promises too.

### Closed families, open promises

Families and promises travel differently.

**A class family is closed at the edge of its module.** A class can only extend a class declared in the same module. If `Creature` lives in `creatures.pooka`, then `Owl` and `Fox` must live there too. Another module can use creatures, pass them around and match on them, but it cannot add a new kind of creature.

```pooka
module garden

import creatures.{Creature}

// Not allowed: Creature belongs to another module.
class Hedgehog is Creature {
  new(name: String) {
    super.new(name)
  }
}
```

```text
error: class inheritance crosses a module boundary
help: Declare subclasses alongside their parent, or use an interface with `with` for an open extension point.
```

This is what makes `match` so confident. Because every member of the family lives in one module, the compiler can see all of them at once, and it can tell you when a match forgets one. Nobody can add a new member somewhere else and quietly break a match that used to cover everything.

**An interface is open to everyone.** Any class or actor, in any module, in any package, can keep an interface's promise with `with`:

```pooka
module garden

import creatures.{Glowing}

class Glowworm(colour: String) with Glowing {
  glow() -> String {
    "a " + colour + " glow"
  }
}
```

So the rule of thumb is:

- Use a **class family** when you know every shape in advance, and want `match` to check that each one is handled. A `Shape` that is a circle or a rectangle. A parse that is `Finished`, `Incomplete` or `Invalid`.
- Use an **interface** when other people should be able to add their own shapes later. Anything `Glowing`. Anything that can be compared, saved or drawn.

> A family keeps one house, and everybody knows who lives there. A promise can be made by anyone, from anywhere, as long as they keep it.

---

## Chapter 6: Actors, the ones with mailboxes

Everything so far has been immutable. Values are made, passed around, and never changed. This is restful, but the world does change. Kettles boil. Lamps are switched on.

On the BEAM, changing things live inside processes: small, separate workers, each with its own mailbox. In Pooka, those workers are called actors.

```pooka
module main

actor Kettle {
  var cups: Int = 0

  be pour(count: Int) {
    cups += count
  }

  poured() -> Int {
    cups
  }
}

main() {
  let kettle = Kettle()
  kettle.pour(2)
  kettle.pour(1)
  echo kettle.poured()
}
```

- `actor` declares one. Creating it starts a new process.
- `var` fields can change, but only inside the actor. Nobody else can reach in and touch them.
- `be` declares a behaviour. Calling it drops a message in the mailbox and returns `Nil` straight away, without waiting.
- An ordinary method, like `poured()`, is a request. The caller waits for an answer.
- Messages are handled one at a time, in the order they were sent. So `poured()` sees both pours, and two callers can never tangle the same field.

> An actor is a small room with one occupant and a letterbox. You cannot go in. You can only write.

Actors can have constructors, keep promises with `with`, and hold ordinary `let` fields too:

```pooka
module main

actor Lamp {
  var lit: Bool
  let room: String

  new(room: String) {
    self.lit = False
    self.room = room
  }

  be toggle() {
    lit = !lit
  }

  status() -> String {
    match lit {
      True -> "the " + room + " is bright"
      False -> "the " + room + " is dark"
    }
  }
}

main() {
  let lamp = Lamp("study")
  lamp.toggle()
  echo lamp.status()
}
```

---

## Chapter 7: When things go wrong

Errors are not punishments. They are small notes slipped under the door by concerned machinery. Pooka has a few ways to answer them.

### Propagating with `?`

Opening every `Result` with `match` is honest, but it can feel like unwrapping a parcel inside a parcel inside a parcel. Writing `?` after a `Result` opens it for you: if it is `Ok`, you get the value. If it is an `Error`, the function stops right there and hands the same error back to its caller.

```pooka
module main

import pooka/int

parse_age(text: String) -> Result(Int, String) {
  match int.parse(text) {
    Ok(age) -> Ok(age)
    Error(_) -> Error(text + " is not an age")
  }
}

combined_age(a: String, b: String) -> Result(Int, String) {
  let first = parse_age(a)?
  let second = parse_age(b)?
  Ok(first + second)
}

main() {
  echo combined_age("30", "12")
  echo combined_age("30", "owl")
}
```

`?` only works on `Result`, and only inside a function that itself returns a compatible `Result`. For an `Option`, use `option.to_result` first.

### `let assert`

Sometimes you know a pattern will match, or you have decided that if it does not, nothing sensible can happen next. `let assert` says so.

```pooka
module main

import pooka/int

main() {
  let assert Ok(year) = int.parse("1974") as "the year must be readable"
  echo year
}
```

If the pattern does not match, the program stops with your message. Use it for things that should never fail, not for things that merely might.

### `assert`

`assert` checks that something is `True`.

```pooka
module main

main() {
  let cups = 3
  assert cups > 0 as "there should always be tea"
  echo cups
}
```

It is mostly used in [tests](pooka_testing.md), where a failing `assert` shows what it expected and what it found.

### `panic` and `todo`

`panic` stops the program on purpose. `todo` marks a place you have not finished yet.

```pooka
module main

check_bridge(safe: Bool) -> String {
  match safe {
    True -> "cross carefully"
    False -> panic as "the bridge is out"
  }
}

teach_floats() -> Int {
  todo as "the parser is not ready for floats"
}

main() {
  echo check_bridge(True)
}
```

Both stop the program when they are reached, with your message. `todo` says *not yet*, and `panic` says *never*.

The program above still compiles and runs, because `main` never asks for floats. But the compiler leaves a note at every `todo`, so unfinished work is never quietly forgotten:

```text
warning: todo found
   ╭─ src/main.pooka:11:3
   │
11 │   todo as "the parser is not ready for floats"
   │   ──────────────────────┬─────────────────────
   │                         ╰─ this code will crash if it is run
   ╰─

Be sure to finish it before running or publishing your program.
```

### `echo`

You have met `echo` already. It prints a value with its file and line, then returns it unchanged, so it can go anywhere: in front of an expression, or at the end of a pipe.

```pooka
module main

import pooka/list

main() {
  let squares =
    list.range(1, 4)
    |> echo
    |> list.map(fn(n) { n * n })
  echo squares
}
```

---

## Chapter 8: Visiting the neighbours

Pooka lives on the BEAM, next door to Erlang, Elixir and Gleam. You can knock on their doors with `external`.

```pooka
module main

external Lists from erlang "lists" {
  reverse(items: List(a)) -> List(a)
}

main() {
  echo Lists.reverse([1, 2, 3])
}
```

- `external Lists from erlang "lists"` names a foreign module and gives it a local name.
- Inside the braces, every function you use is written down with its full type. Pooka cannot read the neighbour's mind, so you describe the shape of the reply.
- Call them as `Lists.reverse(...)`.
- The languages are `erlang`, `elixir`, `gleam` and `lfe`. Your own foreign source files go in the project's `ffi/` folder, as `.erl`, `.ex`, `.gleam` or `.lfe` files.

The types you write here are a promise that Pooka cannot check. If the Erlang function returns something else, the trouble will appear at runtime. Keep externals small, and wrap them in ordinary Pooka functions that the rest of your code can trust.

To call Pooka from the other side of the fence, see [BEAM interop](beam_interop.md).

---

## Chapter 9: The pantry

The standard library, `pooka_stdlib`, is a small pantry of useful things. Everything lives under `pooka/`.

| Module | What it keeps |
| --- | --- |
| `pooka/list` | `map`, `filter`, `fold`, `find`, `sort`, `range` and other list tools |
| `pooka/string` | `split`, `join`, `trim`, `replace`, `contains`, `uppercase` |
| `pooka/int`, `pooka/float` | parsing, conversion, rounding and arithmetic helpers |
| `pooka/dict`, `pooka/set` | key-value dictionaries and sets |
| `pooka/option`, `pooka/result` | helpers like `map`, `unwrap_or` and `to_result` |
| `pooka/order` | `Order` and the `Comparator` interface, for sorting your own things |
| `pooka/io` | printing, reading input and prompts |
| `pooka/file`, `pooka/path` | reading and writing files, joining paths |
| `pooka/env`, `pooka/process`, `pooka/time` | arguments, environment, other programs, clocks |
| `pooka/bool`, `pooka/bit`, `pooka/bit_array`, `pooka/hash` | smaller tools |

A short walk through a few shelves:

```pooka
module main

import pooka/dict
import pooka/list
import pooka/option
import pooka/string

main() {
  let shelf = dict.from_list([#("poems", 3), #("maps", 1)])
  let shelf = shelf.insert("maps", 2)
  echo shelf.get("maps")
  echo option.unwrap_or(shelf.get("atlases"), 0)

  let words = string.split("the owl and the finch", " ")
  echo list.filter(words, fn(word) { word != "the" })
  echo list.fold(words, 0, fn(total, word) { total + string.length(word) })
}
```

A `Dict` is used through methods, like `shelf.get` and `shelf.insert`. Like everything else, inserting gives you a new dictionary and leaves the old one untouched. Compare two dictionaries with `.equals(other)`, not `==`.

Each module's own documentation, generated with `pooka docs`, lists every function with examples.

---

## Before you go

That is the whole house, more or less. We have been through the front door, met the lonely functions, chosen paths, named the shapes of things, watched classes change their coats, posted letters to actors, read the notes that errors leave, and knocked on the neighbours' doors.

There is more to find, but you now know enough to find it yourself. A few doors from here:

- [Getting started](getting_started.md): make a project and grow it a little.
- [Testing](pooka_testing.md): `test`, `test skip` and `assert`.
- [The CLI reference](cli_reference.md) and [pooka.toml](pooka_toml.md).
- [Publishing](publishing.md): sharing your package on Hex.

Leave the lantern by the door when you go. Someone else might need it.

— Peregrine Finch
