# Chi Language Gaps & FFI Removal Progress

This document tracks language features Chi is missing and the effort to remove Lua FFI (`luaExpr`/`embedLua`) from the compiler codebase.

---

## Part 1: Fundamental Language Gaps

These are language features that Chi doesn't yet support, forcing the compiler to use FFI.

### 1. Record field access/mutation (~60% of all uses)

The single biggest category. Nearly every file does this:

```chi
// getters in ast.chi, parse_ast.chi, types.chi
pub fn exprKind(e: Expr): string { luaExpr("e.kind") }
pub fn typeTag(t: Type): string { luaExpr("t.tag") }

// setters
embedLua("e.atomValue = value")
embedLua("e.exprType = t")
```

**Root cause**: `Expr`, `Type`, `TypeRef`, `ParseAst` etc. are opaque Lua tables. Chi's type system doesn't know their fields, so every access/mutation goes through FFI.

**Would be fixed by**: Declaring these as proper Chi `data` types or records. The hundreds of accessor functions in `ast.chi` (50+), `parse_ast.chi` (80+), `types.chi` (25+) would all become plain `.field` access. This is a major structural change since the bootstrap compiler also produces these tables.

### 2. Error handling / pcall (~30 uses)

```chi
embedLua("error({ code = 'ERROR', text = message })")
embedLua("local ok, result = pcall(function() ... end)")
val ok = luaExpr("__pcall_ok") as bool
```

**Language need**: Chi has no `try`/`catch` or structured error handling beyond effects. Needs either:
- A built-in `try { ... } catch { e -> ... }` construct, or
- A `Result[T, E]` type with `pcall` integration in stdlib, or
- Error handling via algebraic effects (which Chi already has -- but the compiler doesn't use them for this)

### 3. Reference equality (~15 uses)

```chi
luaExpr("resolved ~= child") as bool
luaExpr("newLhs ~= lhs or newRhs ~= rhs") as bool
```

**Language need**: Chi's `==` does structural equality. The type system (unification, type resolution) genuinely needs reference equality to detect "did this change?" cheaply. Needs a `refEq(a, b)` stdlib function or a dedicated operator.

### 4. Empty array type inference

```chi
val result: array[any] = []    // works but requires explicit type
```

`[]` syntax is supported but requires an explicit type annotation. Type inference from context (e.g. return type, assignment target) does not fill in the element type automatically.

### 5. Metatable / global environment manipulation (1 use in messages.chi)

```chi
embedLua("setmetatable(_G, { __index = function(t, k) ... end })")
```

Deeply Lua-specific runtime bootstrapping. Should stay as FFI.

---

## Part 2: FFI Removal Progress

### Session History (2026-04-05)

- ✅ Lexer escape chars: `luaExpr("'\\n'")` → `"\n"` (8 conversions)
- ✅ Lexer string ops: `charCodeAt`, `byteSub`, `fromCharCode` (5 uses across 2 functions)
- ✅ Symbol tables: Initialized `SymbolTable`, `FnSymbolTable`, `TypeTable` with `emptyMap[]` (3 constructors)
- **Total FFI reduction:** ~32 luaExpr/embedLua calls removed
- **Tested:** Fixed-point verification passed on all changes (branch `test/lexer-escape-chars`)

### Session History (2026-04-06 — 2026-04-09)

- ✅ Fixed `compileModules` in stdlib (`std/lang.chi`): rewrote as IIFE `luaExpr` with topological sort, per-package cache, `$` escape fix
- ✅ Added `map.remove[K,V]`, `map.has[K,V]` to `std/lang.map.chi`
- ✅ Added `string.toFloat` to `std/lang.string.chi`
- ✅ Reverted deferred embedLua in emitter, re-enabled `_G.__index` metatable in `messages.chi`
- ✅ Improved `fixed_point_verification.sh` (Lua syntax validation, backup/restore)
- **Tested:** 44/44 chicc tests pass, fixed-point verified, stdlib self-compilation verified

### Session History (2026-04-09, continued)

- ✅ Completed full `luaExpr` removal from `lexer.chi` (6 remaining calls):
  - `luaExpr("string.byte(lex.source, scanPos)")` → `lex.source.charCodeAt(scanPos)`
  - `luaExpr("'\\\\' .. c")` → `"\\" + c`
  - `luaExpr("string.char(36) .. '{'")` → `"\${"`
  - `luaExpr("string.char(36)")` → `"\$"` (two locations)
  - `luaExpr("#source")` → `source.byteLen()` (required new stdlib function)
- ✅ Added `string.byteLen` to `std/lang.string.chi` — wraps Lua `#s` (byte count, distinct from `len` which uses `utf8.len`)
- ✅ Discovered `len` vs `byteLen` distinction: `len()` = Unicode codepoint count, `byteLen()` = byte count. Lexer needs byte-level operations.
- **Total FFI reduction this session:** 6 luaExpr calls removed, lexer.chi now FFI-free
- **Tested:** 44/44 chicc tests pass, fixed-point verified

### Session History (2026-04-25)

- ✅ `parser.chi`: `luaExpr("tonumber(tok.value)")` → `tok.value.toFloat()` (1 FFI removed)
- ✅ `unification.chi`: Migrated `#arr` → `.size()`, `table.insert` → `.push()`/`insertAt`, `luaExpr("arr[i]")` → `arr[i]` where types are known (39 FFI calls removed)
- ✅ `typer.chi`: Migrated `sumRemoveType` to use `.size()`, `.push()`, direct indexing (8 FFI calls removed)
- **Total FFI reduction this session:** ~174 calls removed
  - `parser.chi`: 1 (tonumber → toFloat)
  - `unification.chi`: 39 (`#`/`table.insert`/`[i]` → `.size()`/`.push()`/`.insertAt()`/direct index)
  - `typer.chi`: 42 (`sumRemoveType`, `typeTerms`, local arrays, UFCS call sites)
  - `inference_context.chi`: 23 (`icTrialUnify`, `icList*FunctionsForType` return types, direct `Type` access)
  - `types.chi`: 69 (massive field access migration: `t.lhs`, `t.rhs`, `t.elementType`, `t.variable`, `t.body`, `t.innerType`, array indexing)
- **Tested:** Key tests pass (types, typer, checks, compiler, unification), fixed-point verification blocked by pre-existing `chicc.lua` generation issue (see below)

### Current FFI Counts by File (as of 2026-04-25)

| File | `luaExpr` + `embedLua` | Notes |
|------|------------------------|-------|
| `compiler.chi` | 243 | Complex inline Lua blocks, pcall wrappers, env builder |
| `typer.chi` | 193 | Array clearing (`for i = 1, #constraints do constraints[i] = nil end`), position-based inserts; `sumRemoveType`, `typeTerms`, local arrays, UFCS call sites migrated |
| `checks.chi` | 174 | Massive untyped node field access (`node.tag`, `node.value`, etc.) |
| `inference_context.chi` | 66 | Multi-statement embedLua, package.loaded scanning; `icTrialUnify`, `icList*FunctionsForType` migrated |
| `parse_ast.chi` | 88 | Opaque Lua table field access |
| `ast_converter.chi` | 88 | Opaque Lua table fields (`body.blockBody`, `symType.types`) |
| `types.chi` | 17 | Heavy field access migrated to direct record access; remaining: ref equality, cache table mutation |
| `symbols.chi` | 61 | Symbol table manipulation; only 3 constructors migrated to `emptyMap` |
| `type_writer.chi` | 59 | Inline Lua helpers (`deep_copy_type`, `error` calls) |
| `ast.chi` | 59 | Large inline Lua block for `exprChildren` |
| `emitter.chi` | 57 | Field access on AST nodes, large inline Lua cross-ref walker |
| `cli.chi` | 46 | REPL formatting functions, `pcall`, `#messages` |
| `unification.chi` | 48 | Complex queue management, pcall, `pairs()` iteration; `#`/`table.insert`/`[i]` migrated |
| `parser.chi` | 5 | Float `tonumber` migrated to `toFloat` |
| `util.chi` | 3 | `#s` string length |
| `messages.chi` | 3 | `_G.__index` metatable (intentional) |
| `lexer.chi` | **0** | **FFI-free** ✅ |

### Partial Migrations

These files had some work done but still contain significant FFI:

| File | What was done | What remains |
|------|---------------|--------------|
| `types.chi` | Array operations: `#arr` → `.size()`, `table.insert` → `.push()` | ~86 FFI calls: field access (`t.lhs`, `t.elementType`), reference equality, cache management |
| `symbols.chi` | 3 constructors: `luaExpr("{}")` → `emptyMap[]` | ~61 FFI calls: table mutation, field access on symbols/imports |
| `parser.chi` | `tonumber(tok.value) as int` → `tok.value.toInt()` | `luaExpr("tonumber(tok.value)")` for float literals (1 call) |
| `emitter.chi` | Some string ops moved to stdlib | ~57 FFI calls: field access, inline Lua blocks, `#params`, `#body` |
| `cli.chi` | `os.getenv` → `getEnv`, some string ops | ~46 FFI calls: REPL formatting, pcall, `#messages` |
| `type_writer.chi` | `gsub` chain → `replaceAll` chain | ~59 FFI calls: `error()` wrappers, `deep_copy_type` Lua block |

### Remaining Work: `tonumber` for floats

**Status:** ✅ Migrated in `parser.chi` — `luaExpr("tonumber(tok.value)")` → `tok.value.toFloat()`.

---

## Part 3: Recommended Path Forward

### Next priorities (in order)

1. **✅ DONE:** Lexer string ops + escape chars
2. **✅ DONE:** Map operations in `symbols.chi` (3 constructors)
3. **Easy:** `tonumber` float → `toFloat` in `parser.chi` (1 use)
4. **Medium:** Migrate `table.insert` / `#array` in `checks.chi`, `typer.chi`, `unification.chi`
5. **Hard:** Migrate complex inline Lua in `compiler.chi`, `inference_context.chi`
6. **Blocked:** `ast_converter.chi` needs opaque Lua table fields resolved
7. **Fundamental refactor:** Proper Chi types for AST/Type (eliminates ~60% of remaining FFI)

---

### New stdlib additions (2026-04-09)

Available for future migrations:
- `std/lang.map`: `remove[K,V](m, key)`, `has[K,V](m, key): bool`
- `std/lang.string`: `toFloat(s): float`, `byteLen(s): int` (byte count via Lua `#s`)

---

## Summary: Current State

| Category | Impact | Status |
|----------|--------|--------|
| **Proper Chi types for AST/Type/ParseAst** | ~60% of all FFI calls | Language feature needed |
| **Error handling** (`try`/`catch` or `Result`) | ~30 uses | Language feature needed |
| **Reference equality** operator/function | ~15 uses | Language feature needed |
| **table.insert / #array migrations** | ~120 uses across 6 files | In progress |
| **tonumber float → toFloat** | 1 use | Easy, not started |

**Total FFI calls remaining:** ~1,138 across 15 files  
**Fully FFI-free files:** `lexer.chi`  
**Stdlib additions to date:** `map.remove`, `map.has`, `string.toFloat`, `string.byteLen`  
**Infrastructure fixes:** `compileModules` rewritten with toposort + cache (session 2026-04-09)

### Known Infrastructure Issue

`chicc.lua` generation via `make build` / `compile.chi` currently produces an output **missing `chicc/inference_context`** because `compileModules` (in the host stdlib) skips modules already loaded in `package.loaded`. Since the host `chi` binary pre-loads `inference_context`, it gets silently dropped from the self-hosting compiler output. This is a pre-existing issue — the committed `chicc.lua` also lacks `inference_context` but works for host-compiled tests. Use `bootstrap.lua` (which bypasses `compileModules`) for a complete rebuild if needed.
