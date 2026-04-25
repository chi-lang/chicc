# Chi Language Gaps & FFI Removal Progress

> **What belongs here:** Current state — language features still missing, remaining FFI counts per file, partial migration status, next steps, and known blockers.
>
> **What does NOT belong here:** Historical session logs or changelogs. That history lives in git.

This document tracks language features Chi is missing and the effort to remove Lua FFI (`luaExpr`/`embedLua`) from the compiler codebase.

---

## Fundamental Language Gaps

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

## Current FFI Counts by File

| File | `luaExpr` + `embedLua` | Notes |
|------|------------------------|-------|
| `compiler.chi` | 243 | Complex inline Lua blocks, pcall wrappers, env builder |
| `typer.chi` | 193 | Array clearing, position-based inserts |
| `checks.chi` | 174 | Massive untyped node field access (`node.tag`, `node.value`, etc.) |
| `parse_ast.chi` | 88 | Opaque Lua table field access |
| `ast_converter.chi` | 88 | Opaque Lua table fields (`body.blockBody`, `symType.types`) |
| `inference_context.chi` | 66 | Multi-statement embedLua, package.loaded scanning |
| `symbols.chi` | 61 | Symbol table manipulation |
| `type_writer.chi` | 59 | Inline Lua helpers (`deep_copy_type`, `error` calls) |
| `ast.chi` | 59 | Large inline Lua block for `exprChildren` |
| `emitter.chi` | 57 | Field access on AST nodes, large inline Lua cross-ref walker |
| `cli.chi` | 46 | REPL formatting functions, pcall, `#messages` |
| `unification.chi` | 48 | Complex queue management, pcall, `pairs()` iteration |
| `parser.chi` | **0** | **FFI-free** ✅ |
| `util.chi` | 3 | `#s` string length |
| `messages.chi` | 3 | `_G.__index` metatable (intentional) |
| `lexer.chi` | **0** | **FFI-free** ✅ |

**Total FFI calls remaining:** ~1,138 across 15 files  
**Fully FFI-free files:** `lexer.chi`

---

## Partial Migrations

| File | What was done | What remains |
|------|---------------|--------------|
| `types.chi` | Array operations: `#arr` → `.size()`, `table.insert` → `.push()` | Field access (`t.lhs`, `t.elementType`), reference equality, cache management |
| `symbols.chi` | 3 constructors migrated to `emptyMap[]` | ~61 FFI calls: table mutation, field access on symbols/imports |
| `parser.chi` | Integer and float `tonumber` migrated to `toInt()` / `toFloat()`; qualified name parsing migrated to native Chi | **0** — fully migrated |
| `emitter.chi` | Some string ops moved to stdlib | ~57 FFI calls: field access, inline Lua blocks, `#params`, `#body` |
| `cli.chi` | `os.getenv` → `getEnv`, some string ops | ~46 FFI calls: REPL formatting, pcall, `#messages` |
| `type_writer.chi` | `gsub` chain → `replaceAll` chain | ~59 FFI calls: `error()` wrappers, `deep_copy_type` Lua block |
| `unification.chi` | `#`/`table.insert`/`[i]` → `.size()`/`.push()`/`.insertAt()`/direct index | Complex queue management, pcall, `pairs()` iteration |
| `typer.chi` | `sumRemoveType`, `typeTerms`, local arrays, UFCS call sites migrated | Array clearing, position-based inserts |
| `inference_context.chi` | `icTrialUnify`, `icList*FunctionsForType` return types migrated | Multi-statement embedLua, package.loaded scanning |

---

## Recommended Next Steps

1. **Medium:** Migrate `table.insert` / `#array` in `checks.chi`, `typer.chi`, `unification.chi`
2. **Hard:** Migrate complex inline Lua in `compiler.chi`, `inference_context.chi`
3. **Blocked:** `ast_converter.chi` needs opaque Lua table fields resolved
4. **Fundamental refactor:** Proper Chi types for AST/Type (eliminates ~60% of remaining FFI)

---

## Known Infrastructure Issue

`chicc.lua` generation via `make build` / `compile.chi` currently produces an output **missing `chicc/inference_context`** because `compileModules` (in the host stdlib) skips modules already loaded in `package.loaded`. Since the host `chi` binary pre-loads `inference_context`, it gets silently dropped from the self-hosting compiler output. This is a pre-existing issue — the committed `chicc.lua` also lacks `inference_context` but works for host-compiled tests. Use `bootstrap.lua` (which bypasses `compileModules`) for a complete rebuild if needed.
