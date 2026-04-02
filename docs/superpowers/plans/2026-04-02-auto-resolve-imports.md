# Auto-Resolve Missing Imports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `chi tests/test_messages.chi` (and any test file) compile and run directly, without `run_tests.sh`, by auto-resolving missing imports at compile time.

**Architecture:** When the CLI's `runFile()` or `compileFile()` encounters a source file with imports, it extracts import paths, checks which are missing from `package.loaded`, and resolves them by: (1) checking a `.cache/` directory for pre-compiled `.lua` files with mtime validation, or (2) scanning `.chi` files in the working directory for matching `package` declarations, then compiling and loading them. A new `std/io.dir` stdlib module provides directory listing and mtime comparison primitives. Each test file gets its own `package` declaration so it can be compiled standalone.

**Tech Stack:** Chi language, LuaJIT runtime, `io.popen` for directory listing, `os.execute('test -nt')` for mtime comparison

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `../stdlib/std/io.dir.chi` | Stdlib module: directory listing, file existence, mtime comparison |
| Modify | `../stdlib/compile.chi:96-97` | Add `std/io.dir.chi` to stdlib build list |
| Modify | `chicc/cli.chi` | Add import resolution logic to `runFile()` and `compileFile()` |
| Modify | `tests/test_*.chi` (44 files) | Add `package chicc/test_<name>` declaration to each |
| Modify | `run_tests.sh:89` | Remove package prepend (files now have their own) |

---

### Task 1: Create `std/io.dir` stdlib module

**Files:**
- Create: `../stdlib/std/io.dir.chi`

This module provides directory listing and file metadata functions using `io.popen` and `os.execute`, following the same patterns as `std/io.file.chi`.

- [ ] **Step 1: Create the `std/io.dir` module**

Create file at `/home/marad/dev/chi/stdlib/std/io.dir.chi`:

```chi
package std/io.dir
import std/lang { luaExpr, embedLua }

/// Check if a file or directory exists at the given path.
pub fn exists(path: string): bool {
    embedLua("local f=io.open(path,'r')")
    embedLua("if f then f:close() end")
    luaExpr("f ~= nil")
}

/// Check if path1 has a newer modification time than path2.
/// Returns true if path1 is newer. Uses POSIX `test -nt`.
pub fn isNewer(path1: string, path2: string): bool {
    luaExpr("os.execute('test \"' .. path1 .. '\" -nt \"' .. path2 .. '\"') == 0")
}

/// List immediate entries in a directory (files and subdirectories).
/// Returns an array of entry names (not full paths).
pub fn listDir(path: string): array[string] {
    embedLua("local __io_dir_h=io.popen('ls -1 \"' .. path .. '\" 2>/dev/null')")
    embedLua("local __io_dir_r=__io_dir_h:read('a')")
    embedLua("__io_dir_h:close()")
    embedLua("local __io_dir_t={}")
    embedLua("for line in __io_dir_r:gmatch('[^\\n]+') do table.insert(__io_dir_t, line) end")
    luaExpr("__io_dir_t")
}

/// Recursively find all files under rootPath with the given extension.
/// Returns an array of relative paths (e.g. "tests/test_lexer.chi").
/// Excludes the .cache directory.
pub fn findFiles(rootPath: string, extension: string): array[string] {
    embedLua("local __ff_cmd='find \"' .. rootPath .. '\" -name \"*' .. extension .. '\" -not -path \"*/.cache/*\" -not -path \"*/.git/*\" 2>/dev/null | sort'")
    embedLua("local __ff_h=io.popen(__ff_cmd)")
    embedLua("local __ff_r=__ff_h:read('a')")
    embedLua("__ff_h:close()")
    embedLua("local __ff_t={}")
    embedLua("for line in __ff_r:gmatch('[^\\n]+') do table.insert(__ff_t, line) end")
    luaExpr("__ff_t")
}
```

- [ ] **Step 2: Verify the module compiles**

Run from the stdlib directory:

```bash
cd /home/marad/dev/chi/stdlib && chi compile std/io.dir.chi
```

This should compile without errors. If the `chi` binary doesn't support `compile` for individual files in this context, verify syntax by including it in the full build (next step).

- [ ] **Step 3: Commit**

```bash
git add ../stdlib/std/io.dir.chi
git commit -m "feat: add std/io.dir stdlib module with directory listing and mtime comparison"
```

---

### Task 2: Add `std/io.dir` to stdlib build

**Files:**
- Modify: `../stdlib/compile.chi:96-97`

- [ ] **Step 1: Add `std/io.dir.chi` to the source list**

In `/home/marad/dev/chi/stdlib/compile.chi`, add `"std/io.dir.chi"` after `"std/io.file.chi"` in the source array (line 96-97). The modified section should read:

```chi
compileModule("std.chim", [
    "std/math.chi",
    "std/math.random.chi",
    "std/lang.int.chi",
    "std/lang.float.chi",
    "std/lang.option.chi",
    "std/lang.array.chi",
    "std/lang.string.chi",
    "std/lang.any.chi",
    "std/lang.map.chi",
    "std/lang.set.chi",
    "std/io.chi",
    "std/io.file.chi",
    "std/io.dir.chi",
    "std/lang.chi",
    "std/utils.chi"
], {
    loadCompiledModules: true,
    verbose: true,
    binary: false
})
```

- [ ] **Step 2: Build the stdlib**

```bash
cd /home/marad/dev/chi/stdlib && chi compile.chi
```

Expected: All modules compile successfully, `std.chim` is regenerated. Look for `Compiling std/io.dir.chi...` in the output.

- [ ] **Step 3: Install the stdlib**

```bash
cd /home/marad/dev/chi/stdlib && make install
```

This copies the new `std.chim` to `$CHI_HOME/lib/std.chim`.

- [ ] **Step 4: Rebuild native binary (phase 1)**

```bash
cd /home/marad/dev/chi/chicc/native && make
```

This rebuilds the `chi` binary with the new stdlib embedded (but old chicc.lua). After this, the `chi` binary can compile code that imports `std/io.dir`.

- [ ] **Step 5: Commit**

```bash
cd /home/marad/dev/chi/stdlib
git add compile.chi std.chim
git commit -m "feat: include std/io.dir in stdlib build"
```

---

### Task 3: Add package declarations to all 44 test files

**Files:**
- Modify: all `tests/test_*.chi` files (44 files, excluding `test_util.chi` which already has one)

Each test file needs a `package chicc/<name>` declaration as the **very first line**, before any imports or comments. The package name matches the filename without the `.chi` extension.

- [ ] **Step 1: Add package declarations to all test files**

For each file, prepend the package declaration as the first line. Here is the mapping:

| File | First line to add |
|------|-------------------|
| `tests/test_ast.chi` | `package chicc/test_ast` |
| `tests/test_ast_converter.chi` | `package chicc/test_ast_converter` |
| `tests/test_ast_program.chi` | `package chicc/test_ast_program` |
| `tests/test_checks.chi` | `package chicc/test_checks` |
| `tests/test_cli.chi` | `package chicc/test_cli` |
| `tests/test_compiler.chi` | `package chicc/test_compiler` |
| `tests/test_emitter.chi` | `package chicc/test_emitter` |
| `tests/test_emitter_atoms.chi` | `package chicc/test_emitter_atoms` |
| `tests/test_emitter_control.chi` | `package chicc/test_emitter_control` |
| `tests/test_emitter_effects.chi` | `package chicc/test_emitter_effects` |
| `tests/test_emitter_fns.chi` | `package chicc/test_emitter_fns` |
| `tests/test_emitter_ops.chi` | `package chicc/test_emitter_ops` |
| `tests/test_emitter_program.chi` | `package chicc/test_emitter_program` |
| `tests/test_emitter_records.chi` | `package chicc/test_emitter_records` |
| `tests/test_emitter_vars.chi` | `package chicc/test_emitter_vars` |
| `tests/test_inference_ctx.chi` | `package chicc/test_inference_ctx` |
| `tests/test_lexer.chi` | `package chicc/test_lexer` |
| `tests/test_lexer_comments.chi` | `package chicc/test_lexer_comments` |
| `tests/test_lexer_nums.chi` | `package chicc/test_lexer_nums` |
| `tests/test_lexer_ops.chi` | `package chicc/test_lexer_ops` |
| `tests/test_lexer_strings.chi` | `package chicc/test_lexer_strings` |
| `tests/test_lexer_tokenize.chi` | `package chicc/test_lexer_tokenize` |
| `tests/test_messages.chi` | `package chicc/test_messages` |
| `tests/test_parse_ast.chi` | `package chicc/test_parse_ast` |
| `tests/test_parser.chi` | `package chicc/test_parser` |
| `tests/test_parser_compat.chi` | `package chicc/test_parser_compat` |
| `tests/test_parser_control.chi` | `package chicc/test_parser_control` |
| `tests/test_parser_effects.chi` | `package chicc/test_parser_effects` |
| `tests/test_parser_expr.chi` | `package chicc/test_parser_expr` |
| `tests/test_parser_interp.chi` | `package chicc/test_parser_interp` |
| `tests/test_parser_stmts.chi` | `package chicc/test_parser_stmts` |
| `tests/test_parser_top.chi` | `package chicc/test_parser_top` |
| `tests/test_parser_types.chi` | `package chicc/test_parser_types` |
| `tests/test_resolve_type.chi` | `package chicc/test_resolve_type` |
| `tests/test_smoke.chi` | `package chicc/test_smoke` |
| `tests/test_source.chi` | `package chicc/test_source` |
| `tests/test_symbols.chi` | `package chicc/test_symbols` |
| `tests/test_token.chi` | `package chicc/test_token` |
| `tests/test_type_writer.chi` | `package chicc/test_type_writer` |
| `tests/test_typer.chi` | `package chicc/test_typer` |
| `tests/test_types.chi` | `package chicc/test_types` |
| `tests/test_types_ops.chi` | `package chicc/test_types_ops` |
| `tests/test_unification.chi` | `package chicc/test_unification` |
| `tests/test_util_sb.chi` | `package chicc/test_util_sb` |

**Do NOT modify `tests/test_util.chi`** — it already has `package chicc/test_util` on line 2.

Example for `tests/test_messages.chi` — the file currently starts with:

```chi
import chicc/test_util { test, assertEqual, summary }
```

After modification, it should start with:

```chi
package chicc/test_messages
import chicc/test_util { test, assertEqual, summary }
```

Example for `tests/test_smoke.chi` — the file currently starts with:

```chi
// Smoke test for the test framework
// Run via: ../run_tests.sh test_smoke.chi
import chicc/test_util { test, assertEqual, assertTrue, assertFalse, summary }
```

After modification, it should start with:

```chi
package chicc/test_smoke
// Smoke test for the test framework
// Run via: ../run_tests.sh test_smoke.chi
import chicc/test_util { test, assertEqual, assertTrue, assertFalse, summary }
```

The pattern: always insert `package chicc/<name>` as the very first line (line 1), pushing everything else down.

- [ ] **Step 2: Verify a test file compiles with the existing `run_tests.sh`**

We need to check that `run_tests.sh` still works. Since it prepends `package chicc/test_runner`, and the file now has its own `package` declaration, there will be TWO package declarations. This will likely cause a compilation error.

```bash
./run_tests.sh tests/test_smoke.chi
```

If this fails (expected), proceed to Step 3 to fix `run_tests.sh`.

- [ ] **Step 3: Update `run_tests.sh` to not prepend package declaration**

In `/home/marad/dev/chi/chicc/run_tests.sh`, line 89, change:

```bash
{ echo "package chicc/test_runner"; cat "$test_file"; } > /tmp/_chicc_test_tmp.chi
```

to:

```bash
cp "$test_file" /tmp/_chicc_test_tmp.chi
```

This removes the package prepend since test files now have their own declarations.

- [ ] **Step 4: Verify `run_tests.sh` still works**

```bash
./run_tests.sh tests/test_smoke.chi
```

Expected: PASS. The test file's own `package chicc/test_smoke` declaration is used.

- [ ] **Step 5: Commit**

```bash
git add tests/test_*.chi run_tests.sh
git commit -m "feat: add package declarations to all test files, update run_tests.sh"
```

---

### Task 4: Add auto-import resolution to `cli.chi`

**Files:**
- Modify: `chicc/cli.chi`

This is the core task. We add functions to:
1. Scan `.chi` files and build a `package name -> file path` index
2. Extract import paths from source text
3. Resolve missing imports by compiling from source or loading from cache
4. Call resolution before compilation in `runFile()` and `compileFile()`

- [ ] **Step 1: Add new imports to `cli.chi`**

At the top of `/home/marad/dev/chi/chicc/chicc/cli.chi`, add the new imports after the existing ones (after line 9):

```chi
import std/io.dir { findFiles, exists, isNewer }
import std/lang.string { startsWith, trim, len, substring, split, find }
import std/lang.map { emptyMap, put, get, Map }
import std/lang.array { forEach }
```

The full import section should look like:

```chi
package chicc/cli
import std/lang { luaExpr, embedLua }
import std/lang.array { size, push, forEach }
import std/io.file { readString, writeString }
import std/io.dir { findFiles, exists, isNewer }
import std/lang.string { startsWith, trim, len, substring, split, find }
import std/lang.map { emptyMap, put, get, Map }
import chicc/compiler { newLuaCompilationEnv, compileToLua, formatMessage }
```

Note: `push` was already imported from `std/lang.array`; we add `forEach`. Check if `push` is already there from the original imports (it is: `size, push`).

- [ ] **Step 2: Add `extractImports` function**

Add after the `loadStdlib()` function (after line 40), before the compile mode section:

```chi
// ============================================================================
// Import resolution
// ============================================================================

// Extract import package paths from source text.
// Returns array of strings like ["chicc/test_util", "chicc/messages"].
fn extractImports(source: string): array[string] {
    embedLua("local __ei_result = {}")
    embedLua("for line in source:gmatch('[^\\n]+') do")
    embedLua("  local pkg = line:match('^%s*import%s+([%w_/%.]+)')")
    embedLua("  if pkg then table.insert(__ei_result, pkg) end")
    embedLua("end")
    luaExpr("__ei_result")
}
```

- [ ] **Step 3: Add `extractPackageName` function**

Add immediately after `extractImports`:

```chi
// Extract package declaration from source text.
// Returns the package name (e.g. "chicc/test_util") or unit if none found.
fn extractPackageName(source: string): any {
    embedLua("local __ep_result = nil")
    embedLua("for line in source:gmatch('[^\\n]+') do")
    embedLua("  local trimmed = line:match('^%s*(.-)%s*$')")
    embedLua("  if trimmed ~= '' and not trimmed:match('^//') then")
    embedLua("    local pkg = trimmed:match('^package%s+([%w_/%.]+)')")
    embedLua("    __ep_result = pkg")
    embedLua("    break")
    embedLua("  end")
    embedLua("end")
    luaExpr("__ep_result")
}
```

- [ ] **Step 4: Add `buildPackageIndex` function**

Add immediately after `extractPackageName`:

```chi
// Scan all .chi files in rootDir recursively and build a map of
// package name -> file path. E.g. "chicc/test_util" -> "tests/test_util.chi"
fn buildPackageIndex(rootDir: string): Map[string, string] {
    var index = emptyMap[string, string]()
    val chiFiles = findFiles(rootDir, ".chi")
    chiFiles.forEach { filePath ->
        val source = readString(filePath)
        val pkgName: any = extractPackageName(source)
        if pkgName != unit {
            index = index.put(pkgName as string, filePath)
        }
    }
    index
}
```

- [ ] **Step 5: Add `resolveImports` and `resolveOneImport` (mutually recursive)**

Add immediately after `buildPackageIndex`. These two functions call each other (`resolveImports` -> `resolveOneImport` -> `resolveImports`), so they **must** use the `var` pattern for mutual recursion in Chi:

```chi
// Forward declarations for mutual recursion (Chi requires var pattern)
var resolveImports: (string, string, Map[string, string], any) -> unit = { source, cacheDir, index, resolving -> unit }
var resolveOneImport: (string, string, Map[string, string], any) -> unit = { importPath, cacheDir, index, resolving -> unit }

// Resolve all missing imports for a source file.
// Checks package.loaded first, then cache, then compiles from source.
// cacheDir: path to cache directory (e.g. ".cache")
// index: package name -> file path map from buildPackageIndex
// resolving: Lua table used to detect circular dependencies (pass unit for initial call)
resolveImports = { source: string, cacheDir: string, index: Map[string, string], resolving: any ->
    // Initialize resolving set if nil
    embedLua("if resolving == nil then resolving = {} end")

    val imports = extractImports(source)
    imports.forEach { importPath ->
        // Skip if already loaded
        val loaded: any = luaExpr("package.loaded[importPath]")
        if loaded == unit {
            // Skip std/ imports (they should be in stdlib)
            val isStd: bool = luaExpr("importPath:sub(1,4) == 'std/'")
            if isStd == false {
                // Check for circular dependency
                val isResolving: bool = luaExpr("resolving[importPath] == true")
                if isResolving {
                    println("WARN: Circular dependency detected for '$importPath', skipping")
                } else {
                    embedLua("resolving[importPath] = true")
                    resolveOneImport(importPath, cacheDir, index, resolving)
                    embedLua("resolving[importPath] = nil")
                }
            }
        }
    }
}

// Resolve a single missing import.
// Tries cache first (with mtime validation), then source compilation.
resolveOneImport = { importPath: string, cacheDir: string, index: Map[string, string], resolving: any ->
    // Build cache path: e.g. ".cache/chicc/test_util.lua"
    val cachePath: string = luaExpr("cacheDir .. '/' .. importPath:gsub('%.', '/') .. '.lua'")

    // Try to find the source file via the package index
    val sourcePath: any = index.get(importPath)

    // Try cache-first strategy
    if exists(cachePath) {
        // Cache exists - check if it's still valid
        var cacheValid = true
        if sourcePath != unit {
            if isNewer(sourcePath as string, cachePath) {
                cacheValid = false
            }
        }

        if cacheValid {
            // Load from cache
            embedLua("local __rc_f=io.open(cachePath,'r')")
            embedLua("local __rc_code=__rc_f:read('a')")
            embedLua("__rc_f:close()")
            embedLua("local __rc_chunk,__rc_err=load(__rc_code,cachePath)")
            val cacheLoadErr: any = luaExpr("__rc_err")
            if cacheLoadErr == unit {
                embedLua("__rc_chunk()")
                return unit
            } else {
                println("WARN: Cache load failed for '$importPath', recompiling")
            }
        }
    }

    // Cache miss or invalid - compile from source
    if sourcePath != unit {
        val depSource = readString(sourcePath as string)

        // Recursively resolve this dependency's imports first
        resolveImports(depSource, cacheDir, index, resolving)

        // Now compile and load
        val ns = newLuaCompilationEnv()
        val result = compileToLua(depSource, ns)
        val luaCode: any = luaExpr("result.luaCode")

        if luaCode == unit {
            val messages: any = luaExpr("result.messages")
            val msgCount = luaExpr("#messages") as int
            println("Error resolving import '$importPath' from '${sourcePath as string}':")
            var i = 1
            while i <= msgCount {
                val msg: any = luaExpr("messages[i]")
                val formatted = formatMessage(msg)
                println("  $formatted")
                i = i + 1
            }
            return unit
        }

        // Load the compiled code into package.loaded
        embedLua("local __rl_chunk,__rl_err=load(luaCode, sourcePath)")
        val loadErr: any = luaExpr("__rl_err")
        if loadErr != unit {
            println("Error loading compiled '$importPath': ${loadErr as string}")
            return unit
        }
        embedLua("__rl_chunk()")

        // Write to cache for next time
        embedLua("os.execute('mkdir -p ' .. cachePath:match('(.+)/[^/]+$'))")
        writeString(cachePath, luaCode as string)
    } else {
        // No source found - give a detailed error
        val directPath: string = luaExpr("importPath:gsub('%.', '/') .. '.chi'")
        println("Could not resolve import '$importPath':")
        println("  tried: $directPath (not found)")
        println("  tried: $cachePath (not found)")
        println("  scanned .chi files in '.' (no matching package declaration)")
    }
}
```

- [ ] **Step 6: Modify `runFile()` to call import resolution**

In `runFile()` (line 75-110), add import resolution after reading the source and before creating the compilation env. Change:

```chi
pub fn runFile(inputPath: string): int {
    val source = readString(inputPath)
    val ns = newLuaCompilationEnv()
```

to:

```chi
pub fn runFile(inputPath: string): int {
    val source = readString(inputPath)

    // Auto-resolve missing imports
    val index = buildPackageIndex(".")
    resolveImports(source, ".cache", index, unit)

    val ns = newLuaCompilationEnv()
```

- [ ] **Step 7: Modify `compileFile()` to call import resolution**

In `compileFile()` (line 46-69), add the same resolution. Change:

```chi
pub fn compileFile(inputPath: string, outputPath: string): int {
    val source = readString(inputPath)
    val ns = newLuaCompilationEnv()
```

to:

```chi
pub fn compileFile(inputPath: string, outputPath: string): int {
    val source = readString(inputPath)

    // Auto-resolve missing imports
    val index = buildPackageIndex(".")
    resolveImports(source, ".cache", index, unit)

    val ns = newLuaCompilationEnv()
```

- [ ] **Step 8: Commit**

```bash
git add chicc/cli.chi
git commit -m "feat: add auto-import resolution to CLI for missing packages"
```

---

### Task 5: Bootstrap build and verification

**Files:** No new changes — this task builds and tests the work from Tasks 1-4.

- [ ] **Step 1: Compile the updated chicc**

From the chicc directory:

```bash
cd /home/marad/dev/chi/chicc && chi compile.chi
```

Expected: `chicc.lua` is regenerated with the new `cli.chi` code (which now imports `std/io.dir`). This works because Task 2 already rebuilt the native binary with the new stdlib.

- [ ] **Step 2: Rebuild native binary (phase 2)**

```bash
cd /home/marad/dev/chi/chicc/native && make
```

This rebuilds the `chi` binary with both the new stdlib (including `std/io.dir`) AND the new `chicc.lua` (with auto-import resolution).

- [ ] **Step 3: Test with `test_smoke.chi`**

```bash
cd /home/marad/dev/chi/chicc && chi tests/test_smoke.chi
```

Expected output:
```
Tests: 4 total, 4 passed, 0 failed
```

This test is the simplest — it only imports `chicc/test_util`. The auto-resolver should:
1. See `import chicc/test_util` is missing from `package.loaded`
2. Scan `.chi` files, find `tests/test_util.chi` has `package chicc/test_util`
3. Compile and load `tests/test_util.chi`
4. Then compile and run `test_smoke.chi`

- [ ] **Step 4: Test with `test_messages.chi`**

```bash
cd /home/marad/dev/chi/chicc && chi tests/test_messages.chi
```

Expected output:
```
Tests: 8 total, 8 passed, 0 failed
```

This test imports `chicc/test_util`, `chicc/source`, and `chicc/messages`. The latter two should already be in `package.loaded` (embedded in the binary). Only `chicc/test_util` needs resolution.

- [ ] **Step 5: Test that `run_tests.sh` still works**

```bash
cd /home/marad/dev/chi/chicc && ./run_tests.sh tests/test_smoke.chi tests/test_messages.chi
```

Expected: Both PASS.

- [ ] **Step 6: Test the compiler still self-compiles**

```bash
cd /home/marad/dev/chi/chicc && chi compile.chi
```

Expected: `chicc.lua` is rebuilt without errors. This verifies the new imports and functions don't break the compiler's own compilation.

- [ ] **Step 7: Run the full test suite**

```bash
cd /home/marad/dev/chi/chicc && ./run_tests.sh
```

Expected: All 44 tests PASS.

- [ ] **Step 8: Commit (if any fixes were needed)**

If any adjustments were made during verification:

```bash
git add -A
git commit -m "fix: adjustments from verification testing"
```

---

## Bootstrap Build Summary

The build requires a two-phase bootstrap because `cli.chi` imports `std/io.dir`, which must exist in the embedded stdlib:

1. **Phase 1** (Task 2): Compile new stdlib with `std/io.dir` → rebuild native binary → now `chi` has `std/io.dir` available
2. **Phase 2** (Task 5): Compile updated chicc (which imports `std/io.dir`) → rebuild native binary → now `chi` has both new stdlib and new CLI

## Error message format

When an import cannot be resolved, the error looks like:

```
Could not resolve import 'chicc/test_util':
  tried: chicc/test_util.chi (not found)
  tried: .cache/chicc/test_util.lua (not found)
  scanned .chi files in '.' (no matching package declaration)
```

This shows the user exactly what paths were tried and makes debugging straightforward.
