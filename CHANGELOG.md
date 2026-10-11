# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-11

### Changed

- Identifiers must start with a letter: `_x` is no longer a valid name, a standalone `_` is only the weave placeholder and an error anywhere else, and `$_x` in a string is literal text ([#24]).
- `if`, `else`, `while` and `when` bodies open their own scope, so a `val` declared inside is not visible after the block ([#34]).
- Only a `val` initialized with a function, a variable or a literal is polymorphic; any other `val` and every `var` has a single type (value restriction) ([#49]).
- Function parameter types are checked contravariantly: a callback may expect a record with fewer fields than the caller passes, but not one with more ([#47]).
- Calling a value that is not a function reports `NOT_A_FUNCTION` instead of `TYPE_MISMATCH` ([#47]).
- An assignment can no longer be used as an argument, an array element or an operand (`f(r.a = 5)`, `[r.a = 5]`, `2 * r.a = 5`), and `=` or a compound assignment whose left side is not a variable, field or index is a syntax error ([#30]).
- Reassigning a function parameter or a `val` declared inside a function is a `CANNOT_CHANGE_IMMUTABLE` error ([#37]).
- Calling a function with fewer arguments than its parameters without defaults is a `FUNCTION_ARITY_ERROR`; the missing arguments used to be passed as `unit` ([#39]).
- An aliased type import (`import p { Option as Opt }`) makes only the alias visible, not the original type name ([#41]).
- An unknown type name in an annotation is an `UNKNOWN_TYPE` compile error instead of a printed warning that turned the type into `any` ([#42]).
- Mutually recursive `type` and `data` declarations are reported as `UNSUPPORTED_FEATURE` instead of compiling with the referenced type replaced by `any` ([#42]).
- An import of a missing package reports `PACKAGE_NOT_FOUND` once per import instead of `UNRECOGNIZED_NAME` for every imported name and each of its uses ([#65]).
- Float literals keep full double precision instead of being rounded to 14 significant digits, and a literal beyond the double range evaluates to infinity ([#43]).
- The REPL prints values in the specified format: named functions with parameter names, anonymous functions with their type, whole floats as `4.0`, record fields in source order and variants as `Ctor(field: value)` ([#64]).
- Compiler diagnostics and CLI errors go to stderr instead of stdout, and `chi compile` with more than one input file is an error ([#60]).
- `chi build` parses its arguments like `chi compile`: `-o`/`--output` is honored before or after the input, and a non-`.chi` input, a missing input or a missing option value is an error with exit code 1 ([#61]).
- The native `chi` runs on its embedded standard library and no longer reads `$CHI_HOME/lib/std.chim`; when the standard library must be loaded from `CHI_HOME` and is missing or broken, `compile`, `repl` and running a file exit with code 1 ([#62]).

### Added

- Newlines are allowed right after `${` and before the closing `}` of a string interpolation ([#25]).
- Compiler crashes are reported with the `INTERNAL_ERROR` code, so they can be told apart from errors in user code ([#31]).

### Fixed

- Weave templates can use the `_` placeholder, e.g. `"hello" ~> toUpper(_)` ([#24]).
- Comments inside `${...}` string interpolation are skipped instead of causing a syntax error ([#25]).
- A NUL byte no longer silently ends the source file, string literals with multibyte characters or `\0` followed by a digit keep their value, and error columns count characters instead of bytes ([#26]).
- A nested `if`, `when` or `while` inside a condition no longer makes the outer body parse as a trailing lambda, and a `when` `else ->` branch accepts a trailing lambda ([#27]).
- A line starting with `-`, `(`, `[` or `{` after an `if` without `else` is no longer joined to the `if` as an operator continuation ([#29]).
- Incomplete code at the end of a file reports a single "unexpected end of file" error instead of a parser crash ([#31]).
- The REPL prints a parse error once instead of twice ([#20]).
- Diagnostics name tokens and types as they are written in source instead of internal token kinds and type tags, and a type error in an array element points at that element ([#33]).
- A `val` declared in a top-level `for` body or an effect handler case is read back correctly and no longer overwrites a top-level `val` of the same name ([#35]).
- A package used only in a default argument value is loaded at runtime, and unknown names in default values and in `for` state and init expressions are reported with a position ([#36]).
- A function-local `var` can be reassigned even when a top-level `val` has the same name ([#37]).
- An early `return` inside a function-typed `val` initializer that is not a lambda returns from the enclosing function instead of failing with `TYPE_MISMATCH` ([#38]).
- Nested functions can use their own default arguments, a local lambda no longer takes the defaults of a same-named top-level function, and the string literal `"@"` is no longer dropped from call arguments ([#39]).
- User programs no longer see the compiler's own functions and packages, both under `run_chicc.sh` and under the native `chi` ([#40], [#68]).
- A field access on a local named like a package alias reads the local, and `handle ... with` cases find a top-level effect even when a local has the same name ([#41]).
- A `data` field or `type` alias that refers to a type declared later in the file, or a `type` alias that refers to a `data` type, is checked against that type instead of `any` ([#42]).
- Very large and very small float literals no longer produce invalid Lua ([#43]).
- Nullary `data` variants such as `None` are values of their data type instead of zero-argument functions ([#45]).
- Recursive generic types are compared with their type arguments, so `Box[string]` no longer passes for `Box[int]`, and structurally equal recursive aliases no longer hang the compiler ([#48]).
- A local declaration no longer generalizes type variables of the enclosing scope, so one value cannot be used at two incompatible types ([#49]).
- A UFCS call on a function-local lambda (`5.dbl()`) calls the local, also from a nested lambda ([#50]).
- An instantiated generic named record type (`Box[int]`) keeps its type arguments when imported from another package ([#52]).
- Field access on a sum of records is typed from every variant that declares the field, not only the first one ([#53]).
- `for` over a generator accepts a function annotated as `T | unit` ([#55]).
- Loops whose body uses `continue`, `break` or `return` compile to valid Lua, in files and in the REPL ([#56]).
- `&&` and `||` short-circuit, and operands are evaluated left to right ([#57]).
- Long functions no longer hit Lua's 200-locals limit, and compiler temporaries no longer overwrite user variables such as `tmp0` ([#58]).
- Record fields named like Lua builtins (`pairs`, `next`) are stored under their own name, so printing, iteration and Lua interop see the real field name ([#59]).
- An unreadable input file or an unwritable output path reports an error and exits with code 1 instead of a Lua traceback ([#60]).
- The REPL keeps `data` and `type` declarations and the `Option` type across lines, and a later definition shadows an earlier import ([#63]).
- A rejected `data` declaration no longer hides the other `data` declarations in the file or causes `UNRECOGNIZED_NAME` errors for its constructors ([#65]).
- A named `fn` declared inside a function or block can call itself ([#66]).
- A generic function called with UFCS from another function of the same package gets fresh type parameters, so they no longer leak into the caller's type ([#67]).

## [0.1.0]

Initial self-hosted release.

[#20]: https://github.com/chi-lang/chicc/issues/20
[#24]: https://github.com/chi-lang/chicc/issues/24
[#25]: https://github.com/chi-lang/chicc/issues/25
[#26]: https://github.com/chi-lang/chicc/issues/26
[#27]: https://github.com/chi-lang/chicc/issues/27
[#29]: https://github.com/chi-lang/chicc/issues/29
[#30]: https://github.com/chi-lang/chicc/issues/30
[#31]: https://github.com/chi-lang/chicc/issues/31
[#33]: https://github.com/chi-lang/chicc/issues/33
[#34]: https://github.com/chi-lang/chicc/issues/34
[#35]: https://github.com/chi-lang/chicc/issues/35
[#36]: https://github.com/chi-lang/chicc/issues/36
[#37]: https://github.com/chi-lang/chicc/issues/37
[#38]: https://github.com/chi-lang/chicc/issues/38
[#39]: https://github.com/chi-lang/chicc/issues/39
[#40]: https://github.com/chi-lang/chicc/issues/40
[#41]: https://github.com/chi-lang/chicc/issues/41
[#42]: https://github.com/chi-lang/chicc/issues/42
[#43]: https://github.com/chi-lang/chicc/issues/43
[#45]: https://github.com/chi-lang/chicc/issues/45
[#47]: https://github.com/chi-lang/chicc/issues/47
[#48]: https://github.com/chi-lang/chicc/issues/48
[#49]: https://github.com/chi-lang/chicc/issues/49
[#50]: https://github.com/chi-lang/chicc/issues/50
[#52]: https://github.com/chi-lang/chicc/issues/52
[#53]: https://github.com/chi-lang/chicc/issues/53
[#55]: https://github.com/chi-lang/chicc/issues/55
[#56]: https://github.com/chi-lang/chicc/issues/56
[#57]: https://github.com/chi-lang/chicc/issues/57
[#58]: https://github.com/chi-lang/chicc/issues/58
[#59]: https://github.com/chi-lang/chicc/issues/59
[#60]: https://github.com/chi-lang/chicc/issues/60
[#61]: https://github.com/chi-lang/chicc/issues/61
[#62]: https://github.com/chi-lang/chicc/issues/62
[#63]: https://github.com/chi-lang/chicc/issues/63
[#64]: https://github.com/chi-lang/chicc/issues/64
[#65]: https://github.com/chi-lang/chicc/issues/65
[#66]: https://github.com/chi-lang/chicc/issues/66
[#67]: https://github.com/chi-lang/chicc/issues/67
[#68]: https://github.com/chi-lang/chicc/issues/68
