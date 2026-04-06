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

### Completed Migrations

These migrations have been fully completed:

| File | What changed | Stdlib used |
|------|-------------|-------------|
| `types.chi` | `luaExpr("{}")` → `[]`, `#arr` → `.size()`, `table.insert` → `.push()` (~60 changes) | `std/lang.array { size }` |
| `emitter.chi` | `string.byte`/`string.sub`/`#value` → stdlib, `table.insert` → `.push()` | `std/lang.string { charCodeAt, byteSub, len }` |
| `cli.chi` | `os.getenv` → `getEnv`, `string.sub`/`string.len` → `byteSub`/`len` | `std/os { getEnv }`, `std/lang.string { len, byteSub }` |
| `parser.chi` | `tonumber(tok.value) as int` → `tok.value.toInt()` | `std/lang.string { toInt }` |
| `type_writer.chi` | `gsub` chain → `replaceAll` chain, `tostring(int)` → `"$lvl"` | `std/lang.string { replaceAll }` |
| `lexer.chi` | Escape chars: `luaExpr("'\\n'")` → `"\n"`, String ops: `charCodeAt`, `byteSub`, `fromCharCode` (~20 changes) | `std/lang.string { charCodeAt, byteSub, fromCharCode }` |
| `symbols.chi` | Symbol tables: `luaExpr("{}")` → `emptyMap[]` in SymbolTable, FnSymbolTable, TypeTable (~12 changes) | `std/lang.map { emptyMap }` |

### Remaining Work: table.insert / #array migrations

**Status:** ~130 FFI calls remaining in 6 files, mixed difficulty

These files still use `embedLua("table.insert(…)")` and `luaExpr("#arr")`:

| File | `table.insert` | `#array` | Difficulty |
|------|----------------|----------|------------|
| `checks.chi` | 7 | 26 | Medium — untyped arrays |
| `typer.chi` | 15 (incl. 2 position-based) | 26 | Medium — position-based inserts need `insertAt` |
| `unification.chi` | 16 (incl. 8 position-based) | 11 | Hard — complex queue management |
| `compiler.chi` | 15 | 17 | Hard — complex inline Lua blocks |
| `inference_context.chi` | 4 | 4 | Hard — multi-statement embedLua |
| `ast_converter.chi` | 0 | 2 | Blocked — opaque Lua table fields (`body.blockBody`, `symType.types`) |

### Remaining Work: tonumber for floats

**Status:** 1 easy use in `parser.chi` — `tok.value.toFloat()` is available in stdlib

---

## Part 3: Recommended Path Forward

### Next priorities (in order)

1. **✅ DONE:** Lexer string ops + escape chars
2. **✅ DONE:** Map operations in `symbols.chi`  
3. **Easy:** `tonumber` float → `toFloat` in parser.chi (1 use)
4. **Medium:** Migrate remaining `table.insert`/`#array` in easier files (`checks.chi`, `typer.chi`)
5. **Hard:** Migrate complex inline Lua in `unification.chi`, `compiler.chi`, `inference_context.chi`
6. **Blocked:** `ast_converter.chi` needs opaque Lua table fields resolved
7. **Fundamental refactor:** Proper Chi types for AST/Type (eliminates ~60% of remaining FFI)

---

## Summary: Current State

| Category | Impact | Status |
|----------|--------|--------|
| **Proper Chi types for AST/Type/ParseAst** | ~60% of all FFI calls | Language feature needed |
| **Error handling** (`try`/`catch` or `Result`) | ~30 uses | Language feature needed |
| **Reference equality** operator/function | ~15 uses | Language feature needed |
| **table.insert / #array migrations** | ~130 uses | Mixed difficulty, in progress |
| **tonumber float → toFloat** | 1 use | Easy, not started |

**Total FFI calls removed to date:** ~32 (session 2026-04-05)
