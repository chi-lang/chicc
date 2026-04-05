# Chi Language Gaps: luaExpr/embedLua Usage in the Compiler

Analysis of ~1700 `luaExpr` and ~635 `embedLua` calls across the self-hosted compiler.

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

## Stdlib Migration Opportunities

The following stdlib functions **exist** but the compiler has not yet migrated to use them. These are pure migration tasks — no language changes needed.

### table.insert → push / insertAt (~159 uses)

```chi
// Current:
embedLua("table.insert(result, item)")
embedLua("table.insert(queue, pos, nc)")

// Should become:
import std/lang.array { push, insertAt }
result.push(item)
queue.insertAt(pos, nc)
```

### #array length → size() (~242 luaExpr uses)

```chi
// Current:
val count = luaExpr("#types") as int

// Should become:
import std/lang.array { size }
val count = types.size()
```

### String byte operations (~20 uses in lexer.chi)

```chi
// Current:
luaExpr("string.byte(lex.source, lex.pos)")
luaExpr("string.char(ch)")
luaExpr("lex.source:sub(from, to)")

// Should become:
import std/lang.string { charCodeAt, fromCharCode, substring }
lex.source.charCodeAt(lex.pos)
fromCharCode(ch)
lex.source.substring(from, to)
```

### Escape character literals (~15 uses in lexer.chi)

```chi
// Current:
luaExpr("'\\n'")
luaExpr("'\\t'")
luaExpr("string.char(34)")

// Should become:
"\n"
"\t"
"\""
```

The lexer already handles escape sequences natively. These literal uses just need updating.

### OS/IO operations (~15 uses in cli.chi)

```chi
// Current:
luaExpr("os.getenv('CHI_HOME')")
luaExpr("os.clock()")

// Should become:
import std/os { getEnv, clock }
getEnv("CHI_HOME")
clock()
```

### Map operations (~40 uses)

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

Note: requires changing the symbol table types from raw Lua tables to `Map[K,V]`.

### Number/type conversion (~10 uses)

```chi
// Current:
luaExpr("tonumber(tok.value)") as int

// Should become:
import std/lang.string { toInt }
tok.value.toInt()
```

---

## Summary

### Remaining language-level gaps (cannot migrate without language changes)

| Feature | Impact |
|---------|--------|
| Proper Chi types for AST/Type/ParseAst | ~60% of all FFI calls (~1400+) |
| Error handling (`try`/`catch` or `Result`) | ~30 uses |
| Reference equality operator/function | ~15 uses |
| Empty array type inference | Minor ergonomic issue |

### Stdlib migration (ready to do now)

| Migration | Approx. uses | Stdlib |
|-----------|-------------|--------|
| `table.insert` → `push`/`insertAt` | ~159 | `std/lang.array` |
| `#array` → `size()` | ~242 | `std/lang.array` |
| String byte ops → `charCodeAt`/`fromCharCode` | ~20 | `std/lang.string` |
| Escape char literals | ~15 | Native Chi strings |
| OS operations → `getEnv`/`clock` | ~15 | `std/os` |
| Map operations → `std/lang.map` | ~40 | `std/lang.map` |
| `tonumber` → `toInt` | ~10 | `std/lang.string` |

### Recommended priority

1. **`#array` → `size()` + `table.insert` → `push`/`insertAt`** — highest count (~400 uses)
2. **String byte ops + escape chars** — unblocks pure-Chi lexer (~35 uses)
3. **OS operations** — unblocks pure-Chi CLI (~15 uses)
4. **Map operations** — moderate count but requires type changes (~40 uses)
5. **Proper Chi types for AST/Type** — eliminates the majority of remaining FFI but is a major refactor
6. **Error handling** — language-level change needed
7. **Reference equality** — language-level change needed
