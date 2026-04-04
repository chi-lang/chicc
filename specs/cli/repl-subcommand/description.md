---
id: 1b5e7b0a-c177-46b4-ac89-8f9527a7cd24
title: REPL subcommand
type: product
version: 1
status: draft
created_at: "2026-04-04T11:27:20+02:00"
updated_at: "2026-04-04T11:27:20+02:00"
---
# REPL Subcommand

## Overview

The `repl` subcommand provides an interactive Read-Eval-Print Loop for the Chi language. It allows users to enter Chi expressions and declarations one at a time, compiling and evaluating them immediately within a persistent execution context.

Chi compiles to Lua, so the REPL leverages LuaJIT's runtime to evaluate compiled code within a shared environment where all prior definitions and state are preserved across inputs.

## Invocation

- `chi repl` — start the REPL explicitly
- `chi` (no arguments) — drop into the REPL (like Python)

## Behavior

### Prompt

A simple `> ` prompt is displayed, waiting for user input.

### Read

The REPL reads a single line of Chi code from stdin.

### Eval

Each line is passed to the compiler as-is using a persistent compilation environment. The resulting Lua code is then executed in a shared Lua environment using LuaJIT's `load()`.

### Print

The result of evaluating the input is printed unless it is `unit`.

Values are printed as follows:

- **Primitives**: natural representation — `42`, `3.14`, `true`, `"hello"`
- **Arrays**: Chi literal syntax — `[1, 2, 3]`
- **Records**: Chi literal syntax — `{ name: "Alice", age: 30 }`. Nested records are printed inline. Circular references print as `<circular>`.
- **Variant types**: constructor syntax — `Circle(radius: 3.14)`, `Some(value: 42)`, `None`
- **Functions**:
  - Named: `<function greet(name: string): string>`
  - Anonymous: `<function (int) -> int>`
- **unit**: not printed (no spurious output)

### Loop

After printing (or on unit result), the REPL displays the prompt again and waits for the next input.

### Error Handling

- Compilation errors: display the error message and return to the prompt. No crash.
- Runtime errors: display the error message and return to the prompt. No crash.
- The REPL session state is preserved after errors — prior definitions remain available.

## State Persistence

All variables, functions, and imports defined in previous inputs remain available in subsequent inputs. This is achieved by reusing the same Lua environment and compilation context across all evaluations within a session.

### Redefinition

In the REPL, rebinding a name with `val` or `var` is allowed, replacing the previous binding and its type. This differs from normal Chi compilation where duplicate bindings in the same scope are errors.

## Default Environment

### Package

User code runs within the `user/default` package by default.

### Auto-imported modules

To make the REPL useful out of the box, the following standard library modules are auto-imported (in addition to the normal prelude):

- `std/lang.array` — array manipulation (`map`, `fold`, `size`, etc.)
- `std/lang.string` — string operations (`len`, `split`, `trim`, etc.)
- `std/lang.option` — `Option[T]` type and helpers
- `std/math` — numeric functions (`abs`, `sqrt`, `pow`, etc.)
- `std/io` — `readLine` for interactive input

Additional modules can be imported explicitly via `import` as usual.

## Exit

- `Ctrl-D` (EOF) exits the REPL cleanly.

## Example Session

```
> val x = 42
> x + 1
43
> fn greet(name: string): string { "Hello, $name!" }
> greet("World")
"Hello, World!"
> import std/math { sqrt }
> sqrt(16.0)
4.0
> val xs = [1, 2, 3]
> xs
[1, 2, 3]
> val p = { name: "Alice", age: 30 }
> p
{ name: "Alice", age: 30 }
> greet
<function greet(name: string): string>
> val bad =
Error: unexpected end of input
> x
42
> val x = "now a string"
> x
"now a string"
```

## Non-Goals (v1)

- Multi-line input / continuation prompts
- Tab completion
- Command history (beyond what the terminal provides)
- Debugger integration
- Syntax highlighting
