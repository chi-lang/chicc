# Work State: Compilation Speed Optimization

**Date:** 2026-04-02
**Branch:** Current working tree (commits on top of `b4c3f1f`)
**Plan:** `docs/superpowers/plans/2026-04-02-compilation-speed-optimization.md`
**Design spec:** `docs/superpowers/specs/2026-04-02-compilation-speed-optimization-design.md`

## Goal

Reduce chicc self-compilation time (~30min) by eliminating type metadata bloat. The type serializer writes fully structural type expansions into `__S_`/`__T_` tables with zero deduplication. `ast.chi` expands from 17KB to 2.6MB (155x, 96.4% metadata). The `Expr` type serializes ~18KB each occurrence, expanded 150+ times.

Three changes were planned:
1. Per-phase profiling (done)
2. Cache `getTypeAlias` (done)
3. Nominal type references — "typeref" encoding (done, but self-compilation fails)

## Completed Tasks (all committed)

| Commit | Description |
|--------|-------------|
| `4ffa4a8` | Per-phase profiling in `compiler.chi`, gated by `CHI_PROFILE` env var |
| `9de6738` | Cache `getTypeAlias` lookups per-package in `__chicc_mkEnv` |
| `6580252` | Typeref encoding — record/sum/array branches emit `{tag="typeref",ids={...}}` |
| `6674877` | Typeref decoding — resolves from `package.loaded[qualifier]._types[name]` with caching |
| `a390a52` | Restored roundtrip/decode tests for typeref encoding |
| `2b07c4b` | Emitter uses `encodeTypeWithContext` for `__T_` entries |
| `73733f6` | Clear typeref cache before batch alias decoding in `getTypeAlias` |

## Uncommitted Changes (bug fixes found during self-compilation)

These changes are in the working tree but NOT committed. They fix bugs discovered when running the self-compilation script.

### 1. `chicc/compiler.chi` (2 areas)

**a) TypeId injection after resolveTypeAndWrapRecursive (line 484):**
```chi
embedLua("local rt = resolved; if rt.tag == 'recursive' then rt = rt.innerType end; if rt.ids then if rt.tag == 'primitive' then table.insert(rt.ids, typeId) else table.insert(rt.ids, 1, typeId) end end")
```
- **Why:** After `resolveTypeAndWrapRecursive`, the resolved type doesn't carry its own typeId in `ids`. Without this, `__T_` entries have `ids={}` and can't be encoded as typerefs.
- **Primitive vs non-primitive:** Primitives append (keeping well-known typeId at `ids[1]`, e.g., `stringTypeId`), non-primitives prepend.

**b) `compileToLua` type fixes (line 630-636):**
- Removed `: any` annotation from `val result = compile(source, ns)` (was causing `hasErrors(result)` to fail)
- Added `as Program` cast on `result.program`

### 2. `chicc/type_writer.chi` (4 areas)

**a) Sum encoding always structural with empty ids (lines 144-161):**
- Sums ALWAYS encode structurally with `ids={}` instead of checking for typeref
- **Why:** JVM compiler adds `optionTypeId` to `T|unit` sum types but chicc doesn't. This caused `__S_` entries (JVM-inferred, with optionTypeId) to produce typerefs resolving to `Option[T]` while `__T_` entries (chicc-resolved, without optionTypeId) had bare `T|unit`. Type mismatch during self-compilation.

**b) Array encoding always structural (lines 167-178):**
- Arrays ALWAYS encode structurally — `arrayTypeId` has no `__T_` entry (`std/lang.array` doesn't export a type alias for `array`), so typeref resolution would fail. Also, element type would be lost.

**c) Recursive branch emits typeref for inner type (lines 190-211):**
- When inner type has ids that aren't the defining type, emit the WHOLE rec as a typeref using inner's ids
- **Why:** Prevents double-wrapping. Without this, you'd get `{tag="rec",var=...,type={tag="typeref",...}}` which resolves the typeref to the full `rec(var, record)`, creating nested `rec(var, rec(var, record))`.

**d) Typeref decoding moved to Lua wrapper (line 379-380):**
- Typeref handling was moved from a Chi `else if tag == "typeref"` branch in `decodeTableImpl` to a Lua wrapper around `decodeTable`
- **Why:** Adding a new branch to `decodeTableImpl`'s deeply-nested if-else chain caused the JVM compiler's type checker to produce a `Type | Type` union error on the return type. The Lua wrapper intercepts `tag == 'typeref'` before delegating to `__origDecodeTable`.
- Uses `__P_.decodeTable` (not local `decodeTable`) because Chi compiles `var decodeTable` to the package table.

**e) Sum decoding always uses empty ids (lines 334-344):**
- Matches the encoding change: always decode sums with `ids={}` to normalize JVM vs chicc semantics.

### 3. `tests/test_type_writer.chi`

- `encode sum type` test (line 81): expects full structural encoding with `ids={}` instead of typeref
- `encode array type` test (line 99): expects full structural encoding instead of typeref

### 4. `chicc.lua`

Rebuilt via JVM compiler with all the above changes. This is the compiler used for self-compilation.

## RESOLVED: Self-Compilation TYPE_MISMATCH

### The fix

**Option C (unifier fix) + deep copy** — two changes:

1. **`chicc/unification.chi`**: Added `isSum(actual)` case. The unifier handled `isSum(expected)` (try matching actual against either sum branch) but had NO case for `isSum(actual)` (require expected to match ALL sum branches). When the type checker built `sum(sum(... | branch_type) | branch_type)` from if-else branches and tried to unify it against a non-sum expected type, it fell through to TYPE_MISMATCH. The fix decomposes `actual = A | B` into two constraints: `unify(expected, A)` and `unify(expected, B)`.

2. **`chicc/type_writer.chi`**: Deep copy with cycle detection on typeref cache hit. Each typeref resolution returns a fresh type tree so the type checker's reference equality shortcircuit (`a == b` in `typeEquals`) doesn't cause constraint generation to collapse distinct branch types.

### Why the original analysis was partially wrong

The work_state identified typeref cache identity as THE root cause and recommended shallow copy (Option A). Investigation showed:
- Shallow copy was insufficient (inner fields still shared)
- Deep copy alone was insufficient (the decoded types were structurally identical between JVM and self-compiled — `typeEquals` returned true in all cross-comparisons)
- The real issue was that `__S_` entries with typeref encoding produced `rec(var, record)` for value types where JVM produced bare `record` (unfolded), AND the unifier couldn't handle `isSum(actual)` regardless

The `isSum(actual)` case is the **essential fix**. Deep copy is a **defense-in-depth** measure for the type inference engine.

### Self-compilation results

| Module | JVM-compiled | Self-compiled | Reduction |
|--------|-------------|--------------|-----------|
| ast.chi | 2.7 MB | 50 KB | 98% |
| types.chi | 265 KB | 43 KB | 84% |
| parse_ast.chi | 190 KB | 54 KB | 72% |
| **Total chicc.lua** | **4.5 MB** | **583 KB** | **87.1%** |

All 52 golden tests pass with the self-compiled `chicc_new.lua`.

## Next Steps

1. **Commit all changes** — unifier fix, type_writer typeref encoding/decoding, compiler fixes
2. **Replace chicc.lua with chicc_new.lua** — use the self-compiled compiler going forward
3. **Profile compilation speed** — measure whether the 87% size reduction translates to faster compilation
