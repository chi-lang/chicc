# chicc Remaining Bugs

**Status:** Golden tests 52/52 pass. Stdlib 9/16 pass (7 fail). Self-compilation blocked.

6 distinct bugs remain: 5 cause stdlib failures, 1 blocks self-compilation.

---

## Bug 1: Import Aliases Not Recognized

**Affected files:** `std/math.chi`, `std/math.random.chi`, `std/lang.any.chi`
**Error:** `[UNRECOGNIZED_NAME] Identifier lua not found!`

**Reproduction:**

```chi
import std/lang { luaExpr as lua, embedLua as elua }
pub val pi: float = lua("math.pi")  // ERROR: lua not found
```

```chi
import std/lang.float { hashCode as floatHashCode }
floatHashCode(value as float)  // ERROR: floatHashCode not found
```

**Root cause:** In `ast_converter.chi:49-53`, `getSymbol` calls `ctGetLocalSymbol` which
looks up the symbol by name. When an import uses `as` (e.g., `luaExpr as lua`), the
symbol table registers the original name `luaExpr`, not the alias `lua`. The name
resolution fails because `lua` is never registered.

The import alias is parsed correctly by the parser (`ParseImport` nodes contain
`originalName` and `aliasName` fields), but `symbols.chi:newCompileTables` only
registers the original name when populating the local symbol table.

**Fix location:** `chicc/symbols.chi` — in `newCompileTables`, where import entries
are registered into `localSymbolTable`. When an import has an alias, register the
symbol under the alias name, not the original name. Also need to ensure `getSymbol`
in `ast_converter.chi` emits `packageTarget` with the original name (not the alias)
for correct Lua code generation.

**Severity:** High — affects 3 stdlib files, 27 errors in `math.chi` alone.

---

## Bug 2: `!` (Not) Operator Precedence Too High

**Affected files:** `std/lang.string.chi` (lines 66, 88), `std/lang.any.chi` (line 43)
**Error:** `[TYPE_MISMATCH] Expected type is 'bool' but got 'function'`

**Reproduction:**

```chi
// lang.string.chi:66
pub fn allCodePoints(s: string, f: (CodePoint) -> bool): bool {
    for cp in s.codePoints() {
        if !f(cp) {        // ERROR: !f is (!) applied to f, then (cp) calls result
            return false
        }
    }
    true
}

// lang.string.chi:88
pub fn isNotEmpty(s: string): bool {
    !isEmpty(s)            // ERROR: same issue — (!isEmpty)(s)
}
```

**Root cause:** In `parser.chi:346-351`, `parsePrefixExpr` handles `TK_NOT` by
recursively calling `parsePrefixExpr(p)`, which only parses atoms and other prefix
operators — not postfix operators like function calls, field access, or indexing.

The Pratt parser flow for `!f(cp)`:
1. `parseExprFwd` calls `parsePrefixExpr`
2. `parsePrefixExpr` sees `!`, advances, calls `parsePrefixExpr` again
3. Inner call returns `f` (variable read)
4. Returns `Not(f)` — type `bool`
5. Back in `parseExprFwd`, postfix loop sees `(`, creates `FnCall(Not(f), [cp])`
6. Type checker: `Not(f)` requires `f: bool`, but `f: (CodePoint) -> bool` → error

The Kotlin compiler parses `!f(cp)` as `Not(FnCall(f, [cp]))` because `!` binds
less tightly than function calls.

**Fix location:** `parser.chi:349` — change `parsePrefixExpr(p)` to parse a full
postfix expression (including function calls, field access, indexing) before applying
`!`. Either call a dedicated `parsePostfixExpr` or call `parseExprFwd` with a
precedence that includes postfix but excludes binary operators.

**Severity:** High — affects 2 stdlib files (3 errors).

---

## Bug 3: IIFE (Immediately Invoked Block) Not Supported

**Affected file:** `std/lang.generator.chi` (line 31)
**Error:** `[TYPE_MISMATCH] Expected type is 'unit' but got 'function'`

**Reproduction:**

```chi
// lang.generator.chi — entire module body is wrapped:
{
    val g = generator(0) { last ->
        if last > 10 { unit } else { last + 1 }
    }
    var x = g.initialValue
    while true {
        x = g.nextValue(x)
        if x == unit { break }
        println(x)
    }
}()    // <-- line 31: IIFE — block called as zero-arg function
```

**Root cause:** The `{ ... }` without `->` is parsed as a `ParseBlock`, not a lambda.
When `()` follows it (line 31), the Pratt parser creates a function call on the block.
During type inference, the block's result type is `unit` (from the while loop), and
calling `unit()` produces the type mismatch.

The Kotlin compiler treats `{ ... }()` as an IIFE — the block becomes a zero-arg
lambda that is immediately invoked.

A related fix was already applied for closures (blocks as function return values in
`ast_converter.chi`), but that only handles the case where a block is the last
expression in a function with a function return type. This case is a standalone IIFE.

**Fix location:** Either in `parser.chi` — detect `}()` pattern and parse the block
as a zero-arg lambda, or in `ast_converter.chi` — when a `FnCall` has a `ParseBlock`
as its callee and zero arguments, wrap the block in a zero-arg lambda before
converting.

**Severity:** Medium — affects 1 stdlib file (1 error).

---

## Bug 4: Record/Lambda Disambiguation Fails on `->` in Type Cast

**Affected file:** `std/lang.set.chi` (line 13)
**Error:** `Parse error: unexpected token in type ref: lang.set.Set`

**Reproduction:**

```chi
type Set[T] = { class: string, set: {}, hash: (T) -> int }

pub fn emptySet[T](): Set[T] {
    val set = { class: "lang.set.Set", set: {}, hash: anyHashCode as (T) -> int }
    //         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //         This is a RECORD, but parser thinks it's a lambda due to -> in type cast
    set
}
```

**Root cause:** In `parser.chi:208-225`, the brace disambiguation logic scans forward
from the opening `{` looking for `->` at brace depth 0. The scan finds `->` in the
type annotation `(T) -> int` and incorrectly concludes this is a lambda expression.
The parser then enters `parseBlockFwd` (lambda parsing), tries to parse `class` as a
lambda parameter name, and `"lang.set.Set"` as its type annotation — which fails.

The scan only tracks `{}`, `()`, `[]` depth but doesn't account for `->` appearing
inside type annotations (after `as`, in record field type declarations, etc.).

**Fix location:** `parser.chi:208-225` — the disambiguation scan needs to skip over
`->` that appears inside type annotations. One approach: also track when inside
parentheses `()` (which wrap function type params) and don't count `->` found there
as lambda arrows. Alternatively, use a more precise heuristic: a lambda `->` must
appear after bare identifiers (param names), not after complex expressions.

**Severity:** Medium — affects 1 stdlib file (6 errors). Could affect user code with
similar patterns.

---

## Bug 5: Default-Arg Fill Ignores Local Variable Shadowing

**Affected file:** `std/io.file.chi` (line 11)
**Error:** `[FUNCTION_ARITY_ERROR] Function requires 0 parameters, but was called with 1`

**Reproduction:**

```chi
// io.file.chi
pub fn lineIterator(fileName: string): () -> string|unit {
    val lines = luaExpr("io.lines(fileName)") as () -> Option[string]
    {
        lines()    // <-- ERROR: 0 params expected but called with 1
    }
}

// Same file, later:
pub fn lines(file: File): () -> string|unit {  // package-level function with 1 param
    // ...
}
```

**Root cause:** In `ast_converter.chi:570-589`, `convertFnCallImpl` tries to fill
default arguments by looking up the callee symbol. For `lines()`, it calls
`ctGetLocalSymbol(tables, "lines")` which finds the **package-level** `pub fn
lines(file: File)` (1 parameter). Since `convertedArgs.size()` (0) < `paramCount` (1),
it inserts a default `@` argument, making the call `lines(@)`.

But the actual `lines` being called is the **local variable** `val lines` (a zero-arg
function). The default-arg fill code doesn't check `currentFnSymbolTable` first,
so it finds the wrong symbol.

During type inference, the local `lines: () -> Option[string]` is called with 1 arg
→ arity mismatch.

**Fix location:** `ast_converter.chi:570-589` — before looking up `ctGetLocalSymbol`,
check `currentFnSymbolTable` first. If the callee name exists as a local variable in
the current function, skip the default-arg fill entirely (local variables don't have
default parameter metadata).

```
// Pseudocode fix:
val fst: any = currentFnSymbolTable
val isLocalVar = fst != unit && fstGet(fst as FnSymbolTable, calleeName) != unit
if !isLocalVar {
    val sym: any = ctGetLocalSymbol(tables as CompileTables, calleeName)
    // ... existing default fill logic
}
```

**Severity:** Medium — affects 1 stdlib file (1 error). Could affect any code where
a local variable shadows a package-level function.

---

## Bug 6: No Multi-Module Compilation (Self-Compilation Blocker)

**Affected:** All chicc modules that import from other chicc modules (16 of 19 files)
**Error:** `Unknown type 'Type'`, `Unknown type 'Expr'`, `Unknown type 'Section'`, etc.

**Reproduction:**

```
$ ./run_chicc.sh compile chicc/token.chi
Unknown type 'Section'           # defined in user/source via: type Section = { ... }

$ ./run_chicc.sh compile chicc/types.chi
Unknown type 'Type' (x8+)       # self-referential type alias

$ ./run_chicc.sh compile chicc/emitter.chi
Unknown type 'StringBuilder'     # from user/type_writer
Unknown type 'Program'           # from user/ast
```

Only 3 modules compile successfully: `util.chi`, `source.chi`, `messages.chi` —
exactly the modules with no `import user/*` statements.

**Root cause:** chicc is a single-file compiler. Each file is compiled in isolation
with only `std/*` packages available from the LuaJIT runtime. When `token.chi` does
`import user/source { Section }`, there is no `user/source` in `package.loaded`
because that module was never compiled and loaded.

The Kotlin compiler's `compileConcat` function compiles files individually and runs
each result in the LuaJIT environment before compiling the next file. This populates
`package.loaded['user/source']._types.Section`, making the type available. chicc has
no equivalent mechanism.

**Architecture:** chicc's `emitter.chi` already emits `_package` and `_types`
metadata in the Lua output (mirroring the Kotlin emitter). chicc's
`newLuaCompilationEnv` in `compiler.chi` already reads from `package.loaded` for type
aliases. The missing piece is purely orchestration: compile file → load result → repeat.

**Fix approach:** Add an incremental compilation mode to `cli.chi`:

1. Accept multiple files (or a file list) on the command line
2. For each file in dependency order:
   - Compile with `compileToLua(source, ns)`
   - Execute the result Lua with `load(luaCode)()` to register in `package.loaded`
   - Collect the Lua output
3. Concatenate all Lua outputs into the final `.lua` file

The infrastructure exists — only the CLI/orchestration loop is missing (~50 lines).

**Severity:** Critical — blocks self-compilation and bootstrap, which are core Phase 4
acceptance criteria.

---

## Summary

| # | Bug | Affected Files | Error Type | Fix Location | Severity |
|---|-----|---------------|------------|--------------|----------|
| 1 | Import aliases | math, math.random, lang.any | UNRECOGNIZED_NAME | symbols.chi | High |
| 2 | `!` precedence | lang.string, lang.any | TYPE_MISMATCH | parser.chi | High |
| 3 | IIFE blocks | lang.generator | TYPE_MISMATCH | parser/ast_converter | Medium |
| 4 | Record/lambda disambiguation | lang.set | Parse error | parser.chi | Medium |
| 5 | Default-arg shadowing | io.file | FUNCTION_ARITY | ast_converter.chi | Medium |
| 6 | No multi-module compilation | 16/19 chicc modules | Unknown type | cli.chi | Critical |

### Recommended Fix Order

1. **Bug 1** (import aliases) — straightforward, unblocks 3 files
2. **Bug 2** (`!` precedence) — clear fix, unblocks 2 files
3. **Bug 5** (default-arg shadowing) — small targeted fix, unblocks 1 file
4. **Bug 4** (record/lambda disambiguation) — parser change, unblocks 1 file
5. **Bug 3** (IIFE) — unblocks 1 file
6. **Bug 6** (multi-module compilation) — architectural, unblocks self-compilation

After bugs 1-5: stdlib should be 16/16. After bug 6: self-compilation and bootstrap.
