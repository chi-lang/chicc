---
id: a3c1f920-4e2a-4d8b-b1f7-6d8e3a2c5b01
title: Chi compiler CLI
type: product
version: 1
status: draft
created_at: "2026-04-04T12:00:00+02:00"
updated_at: "2026-04-04T12:00:00+02:00"
---
# Chi Compiler CLI

## Overview

The `chi` command is the user-facing interface to the Chi compiler. It compiles and runs Chi source files, produces Lua output, and builds standalone native executables.

All command dispatch and argument parsing is handled in Chi (`cli.chi`). The native C launcher is a thin wrapper that sets up the LuaJIT runtime and forwards arguments to `cliMain`.

## Usage

```
chi <command> [options] <file>
```

## Commands

### `compile [-o OUTPUT] FILE`

Compiles a `.chi` source file to Lua. The output defaults to the input filename with a `.lua` extension.

```
chi compile hello.chi              # produces hello.lua
chi compile -o out.lua hello.chi   # produces out.lua
chi compile --output out.lua hello.chi
```

The input file must have a `.chi` extension.

### `build [-o OUTPUT] FILE`

Compiles a `.chi` source file to a standalone native executable. The output defaults to the input filename without the `.chi` extension.

```
chi build hello.chi                # produces hello
chi build -o myapp hello.chi       # produces myapp
```

The build process compiles Chi to Lua, converts to LuaJIT bytecode, then copies the `chi` binary and appends the bytecode as a payload. The resulting executable is self-contained — it needs no runtime installation.

This command is only available when running the native `chi` binary. Outside the native binary it reports an error:

```
Error: 'build' command requires native chi binary
```

### `repl`

Starts an interactive Read-Eval-Print Loop. Also the default when no arguments are given.

```
chi repl
chi          # equivalent
```

See child spec [REPL subcommand](../repl-subcommand/description.md) for full behavior.

### `FILE` (default)

When the argument is a `.chi` file and no command is given, the file is compiled and executed immediately.

```
chi hello.chi
```

This is the primary way to run Chi programs.

## Options

| Option | Description |
|---|---|
| `-o`, `--output FILE` | Output file path (for `compile` and `build`) |
| `-h`, `--help` | Show usage help |
| `--version` | Show version |

## Version

`--version` prints the compiler version:

- `chi 0.1.0 (native)` — when running the native binary
- `chi 0.1.0` — when running via LuaJIT directly

The version is defined in `cli.chi`. The native C launcher sets a `_CHI_NATIVE` global that controls the suffix.

## Architecture

### Native launcher (`chi_main.c`)

A thin C wrapper. Its responsibilities:

- Detect and run payload mode (executables produced by `chi build`)
- Initialize LuaJIT and load the runtime stack (utf8, chistr, chi_runtime, stdlib)
- Load the compiler (`chicc.lua`)
- Load build support (`chi_build.lua`) and expose `_CHI_EXE_PATH`
- Set `_CHI_NATIVE = true`
- Forward all arguments to `cliMain`

The launcher contains no command parsing or dispatch logic.

### `cli.chi`

Owns all command parsing, dispatch, help text, and version output. Exports `cliMain(args): int` as the single entry point.

## Error Handling

- No arguments: starts the REPL
- Unknown command: prints error and usage help, exits with code 1
- Non-`.chi` file: prints error, exits with code 1
- Missing required argument (e.g. `-o` without value): prints error, exits with code 1
- Compilation failure: prints compiler messages, exits with code 1
- Runtime error in executed program: prints error, exits with code 1

## Non-Goals (v1)

- Argument forwarding to executed programs
- Rewriting `chi_build.lua` in Chi (existing Lua implementation is sufficient)
