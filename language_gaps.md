# Chi Language Gaps: luaExpr/embedLua Usage in the Compiler

## Remaining Language-Level Gaps

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

## Stdlib Migration — Done

These migrations have been completed:

| File | What changed | Stdlib used |
|------|-------------|-------------|
| `types.chi` | `luaExpr("{}")` → `[]`, `#arr` → `.size()`, `table.insert` → `.push()` (~60 changes) | `std/lang.array { size }` |
| `emitter.chi` | `string.byte`/`string.sub`/`#value` → stdlib, `table.insert` → `.push()` | `std/lang.string { charCodeAt, byteSub, len }` |
| `cli.chi` | `os.getenv` → `getEnv`, `string.sub`/`string.len` → `byteSub`/`len` | `std/os { getEnv }`, `std/lang.string { len, byteSub }` |
| `parser.chi` | `tonumber(tok.value) as int` → `tok.value.toInt()` | `std/lang.string { toInt }` |
| `type_writer.chi` | `gsub` chain → `replaceAll` chain, `tostring(int)` → `"$lvl"` | `std/lang.string { replaceAll }` |
| `lexer.chi` | Escape chars: `luaExpr("'\\n'")` → `"\n"`, String ops: `charCodeAt`, `byteSub`, `fromCharCode` (~20 changes) | `std/lang.string { charCodeAt, byteSub, fromCharCode }` |
| `symbols.chi` | Symbol tables: `luaExpr("{}")` → `emptyMap[]` in SymbolTable, FnSymbolTable, TypeTable (~12 changes) | `std/lang.map { emptyMap }` |

---

## Stdlib Migration — Remaining & Progress Summary

**Progress (Session 2026-04-05):**
- ✅ Lexer escape chars: `luaExpr("'\\n'")` → `"\n"` (8 conversions)
- ✅ Lexer string ops: `charCodeAt`, `byteSub`, `fromCharCode` (5 uses across 2 functions)
- ✅ Symbol tables: Initialized `SymbolTable`, `FnSymbolTable`, `TypeTable` with `emptyMap[]` (3 constructors)
- **Total FFI reduction this session:** ~32 luaExpr/embedLua calls removed
- **Tested:** Fixed-point verification passed on all changes (branch `test/lexer-escape-chars`)

### Remaining table.insert / #array in unmigrated files

These files still use `embedLua("table.insert(…)")` and `luaExpr("#arr")`:

| File | `table.insert` | `#array` | Difficulty |
|------|----------------|----------|------------|
| `checks.chi` | 7 | 26 | Medium — untyped arrays |
| `typer.chi` | 15 (incl. 2 position-based) | 26 | Medium — position-based inserts need `insertAt` |
| `unification.chi` | 16 (incl. 8 position-based) | 11 | Hard — complex queue management |
| `compiler.chi` | 15 | 17 | Hard — complex inline Lua blocks |
| `inference_context.chi` | 4 | 4 | Hard — multi-statement embedLua |
| `ast_converter.chi` | 0 | 2 | Blocked — opaque Lua table fields (`body.blockBody`, `symType.types`) |

### tonumber for floats (1 use in parser.chi)

```chi
// Kept as FFI — toFloat was added to stdlib but not yet used
val v = luaExpr("tonumber(tok.value)") as float  // → tok.value.toFloat()
```

---

## Summary

### Remaining language-level gaps

| Feature | Impact |
|---------|--------|
| Proper Chi types for AST/Type/ParseAst | ~60% of all FFI calls |
| Error handling (`try`/`catch` or `Result`) | ~30 uses |
| Reference equality operator/function | ~15 uses |
| Empty array type inference | Minor ergonomic issue |

### Remaining stdlib migration

| Migration | Approx. uses | Status |
|-----------|-------------|--------|
| `table.insert` / `#array` in remaining files | ~130 | Mixed typed/untyped arrays, complex inline Lua |
| `tonumber` float → `toFloat` | 1 | Easy — just needs migration in parser.chi |

### Recommended next steps

1. **✅ Lexer string ops + escape chars** — COMPLETED (was blocked by fixed-point, resolved with escape char literals)
2. **✅ Map operations in `symbols.chi`** — COMPLETED (using `emptyMap[K,V]()` for table initialization)
3. **`tonumber` float → `toFloat`** in parser.chi — trivial (1 use)
4. **Migrate remaining `table.insert`/`#array`** in easier files (`checks.chi`, `typer.chi`) — Medium difficulty
5. **Proper Chi types for AST/Type** — eliminates the majority of remaining FFI but is a major refactor
