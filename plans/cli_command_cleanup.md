# CLI command cleanup (spec a3c1f9)

## Goal

Make the CLI match the spec: all command dispatch in `cli.chi`, thin C launcher, drop `run`, add `build` and `--version`.

The `repl` command and no-args REPL behavior are already implemented and stay as-is.

## Step 1: `cli.chi` — update commands and help

File: `chicc/cli.chi`

### 1a. Add version constant

Add a `CHI_VERSION` string constant after the imports.

### 1b. Rewrite `printUsage`

Update the help text to:
- Keep `repl` and no-args REPL entries
- Add `build` command
- Add `--version` option
- Remove `run` command
- Change output file option description to apply to both `compile` and `build`

### 1c. Add `--version` handling in `cliMain`

After the `--help` check, handle `--version`. Read the `_CHI_NATIVE` Lua global to decide whether to append `(native)` to the output.

### 1d. Add `build` command handling

After the `compile` block, before the current `run` block. Check that the `chi_build` Lua global exists — if not, print an error saying build requires the native binary and return 1. Otherwise call `loadStdlib()` and delegate to `chi_build(args)`.

### 1e. Remove `run` command

Delete the entire `run` command block. The `repl` block and default file-run behavior remain unchanged.

## Step 2: `chi_main.c` — thin out the launcher

File: `native/chi_main.c`

### 2a. Remove `CHI_VERSION` define

No longer used — version lives in `cli.chi`.

### 2b. Remove `--version` early exit

Delete the `--version` check that runs before Lua init.

### 2c. Flatten compiler mode in `main`

Replace the `build`-vs-normal branching with unconditional setup:
- Always load `chi_build.lua` bytecode
- Always set `_CHI_EXE_PATH` to the executable path
- Set `_CHI_NATIVE = true`
- Forward all arguments to `cliMain`

### 2d. Update top-of-file comment

Reduce to two modes: payload mode and compiler mode. Remove mention of "Build mode" as a separate C-level concern.

## Step 3: Update tests

File: `tests/test_cli.chi`

### 3a. Remove `run` tests

Delete the two tests for `run` without file and `run` with non-chi file.

### 3b. Add `--version` test

Verify that `--version` returns exit code 0.

### 3c. Add `build` without native test

Set `chi_build` global to nil, then verify that `build test.chi` returns exit code 1.

### 3d. Fix no-args test

The existing test expects exit code 1 (old behavior: print usage). No args now starts the REPL which returns 0. Mock `io.read` to return nil (immediate EOF) so the REPL exits cleanly, then assert exit code 0.

## Step 4: Verify

1. Run tests: `chi tests/test_cli.chi`
2. Rebuild the compiler: `chi compile.chi`
3. Verify fixed point: run `chi compile.chi` again — output must be identical
4. Rebuild native: `make clean && make` in `native/`
5. Smoke test native: `chi --version`, `chi --help`, `chi hello.chi`
