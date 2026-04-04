---
name: chi-language
description: Guide for writing Chi language code. Covers syntax differences from mainstream languages, type system, effects, modules, stdlib, and known quirks to avoid.
---

# Chi Language Reference for Code Generation

Chi is a statically-typed language with Hindley-Milner type inference and structural typing that compiles to Lua (LuaJIT). Think of it as: ML-family type system + Kotlin-like syntax + algebraic effects + Lua runtime.

## How Chi differs from what you know

### Variables: `val` (immutable) and `var` (mutable)

```chi
val x = 42          // immutable, type inferred as int
var counter = 0     // mutable
counter += 1
val name: string = "Chi"  // explicit type annotation
```

### Primitives: `int`, `float`, `bool`, `string`, `unit`

`unit` is Chi's null/void. There is also `any` (top type).

### Arrays are 1-indexed

```chi
val arr = [10, 20, 30]
arr[1]   // 10, NOT arr[0]
arr[3]   // 30
```

### Records (not classes/objects)

Chi has no classes. Records are structural, anonymous, and mutable:

```chi
val person = { name: "Alice", age: 30 }
person.name      // "Alice"
person.age = 31  // field mutation allowed
```

Functions accept records by structure (extra fields are fine) and by name:

```chi
fn greet(p: { name: string }): string { "Hello ${p.name}" }
greet({ name: "Bob", age: 25 })  // OK -- extra fields are fine
```

### Functions: implicit return, no `fun`/`func`/`def`

The last expression is the return value. Use `return` only for early exit.

```chi
fn add(a: int, b: int): int { a + b }

pub fn greet(name: string): string {
    "Hello $name!"
}
```

### Lambdas: `{ params -> body }`

```chi
val double = { x: int -> x * 2 }
val add = { a, b -> a + b }       // types inferred
val thunk = { "hello" }           // no-arg lambda
```

### Trailing lambda syntax

When the last parameter is a function, the lambda can go outside the parentheses:

```chi
arr.forEach { x -> println(x) }
arr.fold(0) { acc, x -> acc + x }
```

This is preffered notation.

### UFCS (Uniform Function Call Syntax)

Any function can be called as a method on its first argument:

```chi
fn double(x: int): int { x * 2 }
5.double()     // same as double(5)
"hello".len()  // len is a function from std/lang.string
```

This is how all "methods" work in Chi -- there are no method declarations.

### `if` is an expression

```chi
val label = if x > 0 { "positive" } else { "negative" }
```

### `when` expression (like `cond`/`switch`)

```chi
val result = when {
    x < 0  -> "negative"
    x == 0 -> "zero"
    else   -> "positive"
}
```

### `for` iterates over arrays, records, and generators

```chi
for item in [1, 2, 3] { println(item) }
for idx, val in ["a", "b"] { println("$idx: $val") }  // 1-based index
for key, val in { x: 1, y: 2 } { println("$key=$val") }
```

### String interpolation: `$var` and `${expr}`

```chi
val name = "World"
println("Hello $name! Sum: ${1 + 2}")
```

Escape `$` with `\$`.

### Weave operator `~>` (piping with placeholder)

```chi
"hello" ~> toUpper(_) ~> "${_}!"
```

`_` is replaced with the left-hand value at each step.

### Sum types (union types)

```chi
type Result = int | string
val x: Result = 42

if x is int {
    val n = x as int
    println(n)
}
```

`Option[T]` is just `T | unit` (from `std/lang.option`).

### Type aliases are transparent

```chi
type Name = string
type Point = { x: int, y: int }
type Callback = (int) -> string
```

They do not create new distinct types.

### Generics with `[T]`

```chi
fn identity[T](x: T): T { x }
fn map[T, R](arr: array[T], f: (T) -> R): array[R] { ... }
type Pair[A, B] = { first: A, second: B }
```

### Algebraic effects

Effects are Chi's unique approach to side effects. Define, invoke inside `handle`, handle with `resume`:

```chi
effect ask(prompt: string): string
effect log(msg: string): unit

val result = handle {
    log("starting")
    val name = ask("who?")
    "Hello $name"
} with {
    ask(prompt) -> resume("World")
    log(msg) -> {
        println("LOG: $msg")
        resume(unit)
    }
}
```

Effects can be `pub` for cross-package use. They support type parameters: `effect read[T](): T`.

### Variant types (algebraic data types)

```chi
data Shape =
    Circle(radius: float)
    | Rectangle(width: float, height: float)

data Option[T] = Some(value: T) | None
data pub Node(value: int, next: Node)  // recursive
```

### Modules and imports

```chi
package myapp/utils              // module: myapp, package: utils
package std/lang.option          // module: std, package: lang.option

import std/lang.array { map, fold, size }
import std/lang.string { len, toLower }
import std/math { abs, pow }
import mod/pkg as p              // alias: p.foo()
import mod/pkg { foo as bar }    // name alias
```

Only `pub` declarations are visible across modules. `println`, `print`, `eval` are auto-imported.

### Visibility

```chi
pub fn publicFn() { ... }
pub val publicVal = 42
fn privateFn() { ... }        // only visible within module
```

## Quirks and pitfalls

These are real compiler limitations. Follow the workarounds exactly.

### Mutual recursion requires `var` pattern

Self-recursion via `fn` works fine. However, mutual recursion (two functions calling each other) requires the `var` workaround since Chi lacks forward declarations:

```chi
// Self-recursion works directly:
fn factorial(n: int): int {
    if n <= 1 { 1 } else { n * factorial(n - 1) }
}

// Mutual recursion needs var pattern:
var isEven: (int) -> bool = { n -> false }
var isOdd: (int) -> bool = { n -> false }
isEven = { n: int -> if n == 0 { true } else { isOdd(n - 1) } }
isOdd = { n: int -> if n == 0 { false } else { isEven(n - 1) } }
```

### Reserved Lua names cause runtime errors

Avoid naming functions or variables: `repeat`, `type`, `error`, `load`, `require`, `select`, `pairs`, `ipairs`, `next`, `pcall`, `xpcall`, `tostring`, `tonumber`, `unpack`, `rawget`, `rawset`.

### Negative float literals

`-3.14` as an argument can fail. Assign to a variable first:

```chi
// WRONG: fabs(-3.14)
val neg: float = 0.0 - 3.14
fabs(neg)
```

### Record iteration order is non-deterministic

`for k, v in { a: 1, b: 2 }` may iterate in any order (Lua's `pairs()` behavior).

### Default parameters have type-checking issues

Functions with default parameters may produce unexpected type errors in some cases. Test carefully.

## Standard library quick reference

All stdlib modules use the `std/` prefix. Import specific functions.

| Module            | Key exports                                                                                                                                                                                               |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `std/lang.array`  | `size`, `push`, `pop`, `map`, `fold`, `reduce`, `sort`, `sortWith`, `reverse`, `any`, `all`, `count`, `indexOf`, `forEach`, `first`, `last`, `isEmpty`, `sum`, `joinToStringWithSeparator`, `intersperse` |
| `std/lang.string` | `len`, `find`, `substring`, `toLower`, `toUpper`, `trim`, `replace`, `replaceAll`, `split`, `contains`, `startsWith`, `endsWith`, `isEmpty`, `reverse`, `toInt`, `codePoints`                             |
| `std/lang.option` | `Option[T]` (= `T \| unit`), `valueOr`, `ifPresent`, `orElse`, `map`                                                                                                                                      |
| `std/lang.map`    | `emptyMap[K,V]()`, `put`, `get`, `getOrDefault`, `size`, `forEach`, `keys`, `values`, `mapValues`                                                                                                         |
| `std/lang.set`    | `emptySet[T]()`, `add`, `remove`, `contains`, `size`, `toArray`, `fromArray`                                                                                                                              |
| `std/math`        | `abs`, `min`, `max`, `pow`, `sqrt`, `floor`, `ceil`, `sin`, `cos`, `tan`, `pi`                                                                                                                            |
| `std/math.random` | `seed`, `randomInt`, `randomFloat`                                                                                                                                                                        |
| `std/io`          | `readLine`                                                                                                                                                                                                |
| `std/io.file`     | `readString`, `writeString`, `readAllLines`, `lineIterator`, `open`, `close`, `write`                                                                                                                     |
| `std/utils`       | `range(from, to)` returns an iterator                                                                                                                                                                     |

### Stdlib usage pattern

```chi
import std/lang.array { map, fold, size }
import std/lang.string { len, split }

val words = "hello world chi".split(" ")
val lengths = words.map { w -> w.len() }
val total = lengths.fold(0) { acc, n -> acc + n }
```

## Lua FFI

Chi can call Lua directly for low-level operations:

```chi
import std/lang { luaExpr, embedLua }

val time = luaExpr("os.time()")         // eval Lua expression, return result
embedLua("print('from lua')")           // execute Lua statements (side effects)
```

These are used extensively in the stdlib. Avoid them in application code unless necessary.
