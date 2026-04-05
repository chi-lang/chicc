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

---

## Stdlib Migration — Remaining

### Lexer.chi — string byte ops + escape chars (BLOCKED)

```chi
// These changes compile but cause a fixed-point failure:
// the new compiler truncates identifiers (e.g. freshVar → fresh).
// See lexer_problem.md for details.
luaExpr("string.byte(lex.source, lex.pos)")  // → lex.source.charCodeAt(lex.pos)
luaExpr("string.char(ch)")                    // → fromCharCode(ch)
luaExpr("lex.source:sub(from, to)")           // → lex.source.byteSub(from, to)
luaExpr("'\\n'")                              // → "\n"
luaExpr("string.char(34)")                    // → "\""
luaExpr("string.char(36)")                    // → "\$"
```

### Map operations in symbols.chi (~40 uses)

```chi
// Current:
embedLua("symbols[name] = sym")
luaExpr("symbols[name]")
embedLua("symbols[name] = nil")

// Should become:
import std/lang.map { put, get, remove }
symbols.put(name, sym)
symbols.get(name)
symbols.remove(name)
```

Requires changing `SymbolTable.symbols` from `any` (raw Lua table) to `Map[string, Symbol]`. The st* API functions provide a clean abstraction boundary — no callers access `.symbols` directly.

### Remaining table.insert / #array in unmigrated files

These files still use `embedLua("table.insert(…)")` and `luaExpr("#arr")`:

| File | `table.insert` | `#array` | Difficulty |
|------|----------------|----------|------------|
| `checks.chi` | 7 | 26 | Medium — untyped arrays |
| `typer.chi` | 15 (incl. 2 position-based) | 26 | Medium — position-based inserts need `insertAt` |
| `unification.chi` | 16 (incl. 8 position-based) | 11 | Hard — complex queue management |
| `compiler.chi` | 15 | 17 | Hard — complex inline Lua blocks |
| `inference_context.chi` | 4 | 4 | Hard — multi-statement embedLua |
| `ast_converter.chi` | 0 | 2 | Easy |
| `symbols.chi` | 1 | 4 | Medium |

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

| Migration | Approx. uses | Blocker |
|-----------|-------------|---------|
| Lexer string byte ops + escape chars | ~20 | Fixed-point bug (see `lexer_problem.md`) |
| Map operations → `std/lang.map` | ~40 | Requires type changes |
| `table.insert` / `#array` in remaining files | ~130 | Mixed typed/untyped arrays, complex inline Lua |
| `tonumber` float → `toFloat` | 1 | None (just do it) |

### Recommended next steps

1. **Investigate lexer fixed-point bug** — unblocks the biggest single-file win
2. **Migrate remaining `table.insert`/`#array`** in easier files (`ast_converter.chi`, `checks.chi`)
3. **Map operations in `symbols.chi`** — clean abstraction boundary makes this safe
4. **Proper Chi types for AST/Type** — eliminates the majority of remaining FFI but is a major refactor
