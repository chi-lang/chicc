# Lexer.chi stdlib migration — fixed-point failure

## What was attempted

Replace all `luaExpr` calls in `lexer.chi` with stdlib equivalents:

- `import std/lang { luaExpr }` → `import std/lang.string { charCodeAt, fromCharCode, byteSub, len }`
- `luaExpr("#source")` → `source.len()`
- `luaExpr("string.byte(lex.source, lex.pos)")` → `lex.source.charCodeAt(lex.pos)`
- `luaExpr("string.byte(lex.source, p)")` → `lex.source.charCodeAt(p)`
- `luaExpr("lex.source:sub(from, to)")` → `lex.source.byteSub(from, to)`
- `luaExpr("string.char(ch)")` → `fromCharCode(ch)`
- Escape char literals: `luaExpr("'\\n'")` → `"\n"`, `luaExpr("string.char(34)")` → `"\""`, etc.
- Dollar sign: `luaExpr("string.char(36)")` → `"\$"`, `luaExpr("string.char(36) .. '{'")` → `"\${"`

## What happens

**First bootstrap** (old chicc.lua compiles new sources): succeeds.

**Second bootstrap / fixed point** (new chicc.lua compiles same sources): fails with:

```
Compiling package: chicc/types ...
Parse error: expected token kind 71 but got
Parse error: expected token kind 73 but got
MSG.codePoint: {line: 693, column: 47}
MSG.code: UNRECOGNIZED_NAME
MSG.text: Name 'fresh' was not recognized
```

The identifier `freshVar` (a function parameter) at `types.chi:693` is being truncated to `fresh`. This causes the name resolver to fail.

## Diagnosis

The bug is in the **new compiler's lexer** (built from the modified lexer.chi). When the new compiler lexes source files, it truncates some identifiers. The truncation of `freshVar` → `fresh` suggests the lexer stops scanning the identifier 5 characters too early at a `V` boundary.

The other changes (emitter, cli, parser, type_writer, types) were verified to NOT cause this issue — the fixed-point works perfectly with all changes EXCEPT lexer.chi.

## What was ruled out

- **`charCodeAt`/`fromCharCode`/`byteSub` return values**: These are thin wrappers around `string.byte`/`string.char`/`string.sub` — they call the exact same Lua functions.
- **Escape character changes**: The escape char replacements (`"\n"`, `"\t"`, `"\$"` etc.) should produce identical runtime values.
- **Other file changes**: Removing all non-lexer changes doesn't fix the issue; removing only lexer changes does.

## What to investigate

1. **Variable shadowing of `len`**: In `newLexer`, `val len = source.len()` creates a local that shadows the imported `len` function. This might cause scope issues in the compiled Lua output if the Chi compiler doesn't handle import shadowing correctly.

2. **UFCS resolution with stdlib imports**: The change from `luaExpr("string.byte(lex.source, lex.pos)")` to `lex.source.charCodeAt(lex.pos)` changes how the compiled Lua code calls the function. The old version inlines the Lua call; the new version goes through UFCS dispatch. If the UFCS resolution produces different code (e.g., different closure capture, different local scoping), it could affect the lexer's behavior at runtime.

3. **Type inference on `val len = source.len()`**: The original was `val len: int = luaExpr("#source")` with explicit type. The new version relies on type inference. If the inferred type differs or the compiled output differs, it could subtly change how `length` is used.

4. **Interaction between `len` (imported function) and `length` (record field)**: The `Lexer` type has a `length: int` field. The imported `len` function operates on strings. If the compiler confuses these during UFCS resolution, `lex.length` could be affected.

5. **Test with minimal change**: Try changing ONLY the escape chars (no import changes, keep `luaExpr` for `charCodeAt`/`byteSub`/`len`) to isolate whether the issue is the import or the function calls.
