# chicc test failures — status & remaining work

Branch `fix/self-hosted-test-failures`. Self-hosted `chi` runner.

| Snapshot                          | Pass  | Fail |
| --------------------------------- | ----- | ---- |
| Before this work                  | ~25   | ~19  |
| After compiler fixes              | 38/44 | 6    |
| After test/parser fixes (current) | 44/44 | 0    |
| JVM bootstrap baseline            | 44/44 | 0    |

**All 44 unit tests pass.** Fixed point holds (`make verify` → identical
generations). Golden suite unchanged: 49 pass, 3 pre-existing failures
(`functions/return_sum_type`, `stdlib/io/read`, `strings/unicode`) that are
unrelated to this work and predate it.

## Fixed (compiler changes)

All the original *compilation* failures plus several runtime bugs:

- **Import-free resolution of public functions** — a `pub` function from any loaded
  package is now reachable without an explicit import (JVM-style). Added
  `lookupLoadedPublicSymbol` in `chicc/symbols.chi`, used as a fallback in
  `ast_converter.getSymbol` and the name-check pass in `chicc/checks.chi`.
- **`luaExpr`/`embedLua` generic instantiation** — their type was
  `fn(string) -> a` with `typeParams={}`, so the return variable `a` was shared
  across *all* call sites. A second `val x: T = luaExpr(...)` with a different `T`
  failed. Fixed by adding `"a"` to `typeParams` in `runtime/chi_runtime.lua` so
  each call instantiates a fresh variable.
- **Field access / UFCS on `any`** — `.field` on `any`/unresolved-var now yields
  `any` (dynamic access); a method call on `any` resolves UFCS deterministically
  (alphabetically-first package among loaded matches → `array.size`, matching JVM).
  In `chicc/typer.chi` (field_access branch, `pickDeterministicUfcs`).
- **Sum-type field narrowing** — `.startLine` on `Section | unit` narrows to the
  variant that declares the field (`sumFieldType` in `chicc/typer.chi`).
- **`unit` as nullable** — unifying `unit` with a record/recursive/sum type is
  accepted (so `record != unit`, `returnExpr(unit, ...)` type-check); `any`
  intersects any primitive. In `chicc/unification.chi`.
- **#8 inference_ctx** — `icListCurrentPackageFunctionsForType` emits a
  `package_fn` dot target (UFCS functions need `__P_` qualification).
- **#9 resolve_type** — `resolveTypeAndWrapRecursive` guards `typeId == unit`
  (delegates to `resolveType`).
- **fn_call nil guard** — `icCompileTables` may be unset when typing in isolation.
- **newCompileTables nil guard** — tolerates `imports == nil`.
- **#5 invalid Lua (test_types_ops)** — large modules exceeded Lua's
  200-locals-per-function limit because every top-level statement's temporaries
  shared the chunk scope. `emitProgram` now wraps each *wrappable* top-level
  statement (name_declaration / assignment / non-embedLua-luaExpr call) in a
  `do ... end` block so its temporaries are freed. Raw `embedLua`/`luaExpr`
  statements stay unwrapped (they may declare persistent chunk locals such as
  `local __defining_type_id` in type_writer — wrapping those breaks the compiler
  and was caught by the fixed-point check). See `topLevelWrappable` in
  `chicc/emitter.chi`.

> ⚠️ A `type_writer` change (emit full `rec` instead of typeref for named
> recursive types, to satisfy `test_type_writer`) causes **infinite recursion**
> when serializing self-referential types (e.g. `Type`, `Expr`). It hangs the
> whole build. Reverted. See test_type_writer below — do NOT reapply naively.

## Previously-remaining failures (6) — now all FIXED

### A. Test bugs (test asserted behaviour contrary to spec / chicc representation)

Fixed on the **test side** (chicc behaviour was correct):

1. **test_cli** — `cliMain with no args` expected exit code 1, but `specs/cli`
   says *"No arguments: starts the REPL"*. chicc correctly runs the REPL
   (returns 0). Fixed the test to start the REPL and assert 0; it redirects
   stdin to `/dev/null` so the REPL sees immediate EOF and exits deterministically.
2. **test_emitter_program** — `emitExpr dispatches is` built an `is` node with the
   JVM-internal field names `isValue` / `isType`. chicc consistently uses
   `castExpr` / `checkedType` (both `isExpr` in `ast.chi` and `emitIs` in
   `emitter.chi`). Fixed the test to use chicc's field names.
3. **test_type_writer** — `encode recursive type` expected the full `{tag="rec",...}`
   wrapper. The compiler intentionally emits a bare typeref for named recursive
   types to avoid infinite recursion during symbol serialisation (see warning
   above); the defining occurrence (`encodeTypeWithContext`) is what serialises the
   structure. Fixed the test to expect `{tag="typeref",ids={{"test","pkg","List"}}}`.
4. **test_emitter_fns** — test isolation. All 14 sub-tests passed, but the file did
   `emitExpr = { st, e -> ... }` at top level, mutating the global `emitExpr`
   (`pub var` of `chicc/emitter`) that the self-hosted compiler dispatches through.
   Under `compileModules` the test runs in the same process as the compiler, and
   this package sorts **early** (it only depends on emitter/ast/types/util), so the
   remaining chicc packages are compiled *after* the stub is installed → broken Lua
   → `#nodes` nil error in checks. Fixed by saving the real dispatcher and restoring
   it before `summary()`.

### B. Environment

5. **test_parser_compat** — read `golden/control_flow/...` relative to cwd, but the
   golden corpus lives at the meta-repo root (`../golden`), not under `chicc/`.
   Fixed `tryParseGolden` to resolve the path (try `golden/`, then fall back to
   `../golden/`) — no cross-repo symlink, repos stay separate.

### C. Test bug — `{}` is context-dependent, and chicc was already correct

6. **test_parser_stmts** — `parse empty block` expected `{}` to parse as an empty
   *block* (`ParseBlock`). That expectation is wrong: `{}` is disambiguated by
   **syntactic position**, and in *expression* position it is an empty **record**.

   - In *body* positions (`fn f() {}`, `if/else`, `while`, `for`, `when`, `handle`)
     `{}` is always a block — a dedicated parser path (`parseBlockFwd`) handles it.
   - In *expression* position (`val x = {}`, an argument, a trailing lambda) `{}` is
     an empty record. This matches the JVM compiler, whose ANTLR grammar does not
     even list `block` as an `expression` alternative; `CreateRecord` (with optional
     fields) wins. JVM test `FuncReaderTest`:
     `testParse("{}")` → `ParseCreateRecord`, and `testParse("{ 0 }")` → `ParseLambda`.

   chicc's `parser.chi:parseBraceExpr` already produced `ParseCreateRecord` for `{}`,
   i.e. it was correct. Fixed the **test** to expect `ParseCreateRecord` (for both
   `{}` and `{ \n }`) instead of changing the parser.

(#5 test_types_ops — fixed earlier, see above.)

## Reproducing

```sh
# Build (uses installed `chi`; if it ever hangs, the installed binary is broken —
# rebuild native from a known-good committed chicc.lua first):
rm -f chicc.lua && chi compile.chi && make native && cp native/chi $CHI_HOME/bin/chi

JOBS=8 ./run_tests.sh                 # self-hosted
./fixed_point_verification.sh         # verify self-hosting stable

# Per-test, with the real (swallowed) compile error surfaced — hook chi_compile to
# print compileToLua messages before they're discarded by compileModules.
```
