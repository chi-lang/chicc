# chicc test failures — gap analysis vs JVM bootstrap

Status snapshot, branch `test/lexer-escape-chars`:

| Runner                                                    | Pass  | Fail |
| --------------------------------------------------------- | ----- | ---- |
| `chi` (self-hosted, after recovery fixes in this session) | 29/44 | 15   |
| `/home/marad/dev/chi/compiler/chi` (JVM bootstrap)        | 44/44 | 0    |

The 15 below are the residual gap. All were uncovered when commit `74a83b4` flipped the test-runner default from JVM to `chi` — chicc itself has never run them clean.

## Compilation failures (test source rejected by chicc typer)

These files don't even reach test execution.

### 1. `test_ast_program.chi` — sum-type subtyping in generics

`[TYPE_MISMATCH] Expected 'string' but got 'unit'` at `assertEqual(entry.alias, "m")` (line 16).

- `assertEqual[T](actual: T, expected: T)` instantiated with `entry.alias: string | unit` and `"m": string`.
- JVM unifies `T = string | unit` and accepts the `string` arg via sum-type subtyping. chicc's unifier rejects unifying `string | unit` with `string`.
- **Missing:** width subtyping during unification — when the expected type is a sum, accept any of its variants.

### 2. `test_parser_compat.chi` — sum-type narrowing on `is` / field access

`[MEMBER_NOT_FOUND] Type primitive does not have field 'code'` (line 39, col 21).

- The sum-type field-access narrowing fix added in this session walks `lhs/rhs` of a sum looking for the field, but in this test the receiver type ends up resolved to a `primitive` after partial unification, so the narrowing path is never reached.
- **Missing:** narrowing should also fire when receiver was a poly type whose body is a sum; or when `effectiveReceiverType` after `ufResolve` collapsed too aggressively.

### 3. `test_parser_control.chi`, `test_parser_effects.chi`, `test_parser_expr.chi`, `test_parser_interp.chi`, `test_parser_stmts.chi` — unresolved type var on `.tag`

`[MEMBER_NOT_FOUND] Type var does not have field 'tag'` at e.g. `assertEqual(result.tag, "ParseIfElse")`.

- `parseExpression(p)` is declared to return `any`. chicc resolves it to a fresh type variable that never gets pinned by surrounding context, so `.tag` access fires before unification finishes.
- JVM treats `any` as a top type with structural field access permitted at runtime; chicc treats `any` as a unification variable and demands type info before allowing `.field`.
- **Missing:** field access on `any` should always type-check (degrade to a runtime lookup). 5 tests fail due to this single gap.

### 4. `test_typer.chi` — `unit` not accepted where record expected

`[TYPE_MISMATCH] Expected 'record' but got 'unit'` at `returnExpr(unit, testSection)` (line 291, col 26).

- `pub fn returnExpr(val_: Expr, section: Section | unit): Expr` — test passes `unit` as `val_`.
- JVM permits implicit `unit -> any-record` conversion (effectively treating record params as nullable). chicc enforces strict types.
- **Missing:** either widen `returnExpr.val_` to `Expr | unit` in `chicc/ast.chi`, or add JVM-style nullable subtyping. Updating the signature is safer; `returnExpr` is already called with non-Expr in convert_ast.

### 5. `test_types_ops.chi` — codegen produces invalid Lua

`compileModules: generated invalid Lua code for package: chicc/test_runner` (Lua `load()` returns nil).

- chicc emits Lua that fails to parse. The stdlib runner doesn't surface the underlying Lua syntax error.
- **Missing:** investigate the generated Lua (instrument `chi_compile` or save the offending output to disk). This one needs a focused look — could be a single bad emission.

## Runtime test-body failures (chicc compiles the source, but tests assert wrong output)

### 6. `test_cli.chi` — `cliMain([])` returns 0, expected 1

`Expected: 1, got: 0` at `cliMain with no args returns 1`.

- The CLI prints usage and the test expects exit code 1 (failure). chicc's CLI returns 0 (success) when no args are given.
- **Missing:** `chicc/cli.chi` `cliMain` should `return 1` (or any non-zero) on empty arg path. JVM CLI does this.

### 7. `test_emitter_program.chi` — `castVal` is nil in cast emission

`attempt to index local 'castVal' (a nil value)` from emitter code path for `cast` exprs.

- The emitter dereferences `expr.castExpr` (or similar) without nil-check when reached via the test's "dispatches is" path.
- **Missing:** investigate `chicc/emitter.chi`'s `cast` / `is` branch — guard the field access or fix the AST shape that the test constructs.

### 8. `test_inference_ctx.chi` — UFCS for current package returns wrong dot-target tag

`Expected: package_fn, got: local_fn` at `icListCurrentPackageFunctionsForType: finds matching package function`.

- `icListCurrentPackageFunctionsForType` (chicc/inference_context.chi:241) explicitly maps same-package symbols to `localFnDotTarget`, but the test asserts they should be `packageFnDotTarget`.
- The function vs the test disagree about the contract for "current package" UFCS targets. JVM-tested behaviour expects `package_fn`.
- **Missing:** flip the `if symMod == pkgMod && symPkg == pkgPkg` branch to use `packageFnDotTarget`, or update the test (less safe — emitter probably depends on which tag is produced).

### 9. `test_resolve_type.chi` — recursive-type wrapper drops `typeId`

`attempt to index local 'typeId' (a nil value)` at `resolveTypeAndWrapRecursive - simple case delegates to resolveType`.

- `resolveTypeAndWrapRecursive` returns a structure without a `typeId` field for the simple (non-recursive) delegate case.
- **Missing:** the wrapper must always populate `typeId` on its result, even when delegating.

### 10. `test_symbols.chi` — `Symbol` / `FnSymbol` type aliases not found

Multiple `ERROR: Unknown type 'Symbol'` and `Unknown type 'FnSymbol'` at the top of the file.

- chicc's type alias resolution can't find `Symbol`/`FnSymbol` from `chicc/symbols`. They're imported in the test, so the expectation is that the type-alias resolver follows imports.
- **Missing:** type alias lookup should consult `package.loaded['chicc/symbols']._types` for imported names. The same fallback I added for value symbols (`getSymbol` / `cnWalkParseAst`) probably needs a counterpart for type aliases.

### 11. `test_type_writer.chi` — recursive types are not encoded

`Expected: {tag="rec",...,type={tag="typeref",...}}, got: {tag="typeref",...}` at `encode recursive type`.

- The encoder collapses a recursive type to its inner typeref, losing the `rec` wrapper.
- **Missing:** `chicc/type_writer.chi` recursive-case branch should emit the `{tag="rec", var=..., type=...}` envelope rather than just the body.

## Cross-cutting language gaps

The 15 failures collapse into roughly 6 underlying chicc-vs-JVM gaps:

1. **No structural subtyping in unification.** Sum-type widening, record-with-fewer-fields, `unit` as nullable — all rejected. Causes #1, #4, parts of #2.
2. **`any` is a unification variable, not a top type.** Field access on `any` fails when no constraint pins the type. Single source of 5 parser test failures (#3).
3. **Sum-type narrowing only fires post-unification on the original receiver.** The current fix in `chicc/typer.chi` doesn't survive ufResolve collapse. Causes #2.
4. **Type-alias resolution ignores `package.loaded._types`.** Causes #10. Mirrors the value-symbol gap already patched.
5. **Encoder/codegen drops recursive-type frames.** Causes #11 directly and possibly contributes to #5.
6. **Behavioural divergences in CLI / UFCS / cast emission.** Causes #6, #7, #8, #9. Each is a localized bug, not a shared infrastructure gap.

## Recommended order of attack

Fix order by leverage (tests unblocked / amount of compiler change):

1. **#3** — accept `.field` on `any` → unblocks 5 tests with one small typer change.
2. **#10** — type-alias loaded-package fallback → unblocks `test_symbols`.
3. **#1** — sum subtyping in unification → unblocks `test_ast_program`, possibly more.
4. **#4** — widen `returnExpr.val_` to `Expr | unit` → 1 line in ast.chi.
5. **#11** — recursive-type encoder fix.
6. **#2** — re-do sum narrowing earlier in typer (before ufResolve collapses).
7. **#7, #8, #9, #6** — localized bug fixes, do last; quick wins once the typer is sound.
8. **#5** — needs Lua-output debugging instrumentation; lowest leverage, do at the end.

## Reproducing locally

```sh
make chicc.lua                   # build chicc.lua
CHI_HOME=/home/marad/apps/chi make install  # rebuild & install chi binary
JOBS=8 ./run_tests.sh            # run with self-hosted chicc
CHI_BOOTSTRAP=/home/marad/dev/chi/compiler/chi JOBS=8 ./run_tests.sh  # baseline (44/44)
```

For a single failing test with full error detail, use the debug runner pattern in `/tmp/debug_test.chi` (hooks `chi_compile` to print `compileToLua` messages before they get swallowed).
