# chicc test failures — status & remaining work

Branch `fix/self-hosted-test-failures`. Self-hosted `chi` runner.

| Snapshot                          | Pass  | Fail |
| --------------------------------- | ----- | ---- |
| Before this work                  | ~25   | ~19  |
| After compiler fixes (this work)  | 38/44 | 6    |
| JVM bootstrap baseline            | 44/44 | 0    |

Fixed point holds (`make verify` → identical generations).

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

## Remaining failures (6) — to handle later

### A. Test bugs (test asserts behaviour contrary to spec / chicc representation)

These should be fixed on the **test side** (or the spec clarified), not the compiler:

1. **test_cli** — `cliMain with no args returns 1` expects exit code 1, but
   `specs/cli` says explicitly *"No arguments: starts the REPL"*. chicc correctly
   runs the REPL (returns 0). The test contradicts the spec.
2. **test_emitter_program** — `emitExpr dispatches is` manually builds an `is`
   node with fields `isValue` / `isType` (JVM-internal names). chicc consistently
   uses `castExpr` / `checkedType` (both the `isExpr` constructor in `ast.chi` and
   `emitIs` in `emitter.chi` agree). The test should use chicc's field names.
3. **test_type_writer** — `encode recursive type` expects `encodeType` to emit the
   full `{tag="rec",...}` wrapper. The compiler intentionally emits a typeref for
   named recursive types to avoid infinite recursion during symbol serialization
   (see warning above). Test expectation conflicts with a required strategy.
4. **test_emitter_fns** — test isolation. All 14 sub-tests pass, but the file does
   `emitExpr = { st, e -> ... }` at top level, which compiles to
   `__chicc__emitter.emitExpr = ...` — i.e. it **mutates the global `emitExpr`
   that the self-hosted compiler itself uses**. Under `compileModules` the test
   runs in the same process as the compiler, so once test_runner loads, every
   package compiled afterwards uses the test's stub and fails (cascading nil
   derefs in checks/symbols). On the JVM bootstrap the compiler was a separate
   binary, so the reassignment was harmless. Fix on the test/runner side
   (save/restore `emitExpr`, or isolate), or rework the compiler's mutable-global
   wiring (`pub var emitExpr`/`parseExpression`/...).

### B. Environment

4. **test_parser_compat** — reads `golden/control_flow/...` relative to cwd, but
   `golden/` lives at the meta-repo root (`../golden`), not under `chicc/`. Native
   `chi` can't open the file. Needs a symlink `chicc/golden -> ../golden`, or the
   test should resolve the path differently. Not a compiler bug.

### C. Compiler design choice (risky to change)

5. **test_parser_stmts** — `parse empty block`: chicc parses `{}` as an empty
   *record* (`ParseCreateRecord`); the test/JVM expect an empty *block*
   (`ParseBlock`). Changing the disambiguation in `parser.chi:parseBraceExpr`
   (line ~189) risks breaking code that uses `{}` as an empty record. Decide intent.

(#5 test_types_ops — FIXED, see above.)

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
