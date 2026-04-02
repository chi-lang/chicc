# Compilation Speed Optimization — Design Spec

**Date:** 2026-04-02  
**Branch:** `feat/incremental-module-compilation`  
**Problem:** chicc native binary takes ~30 minutes to compile itself. The Kotlin compiler does the same work in 16 seconds (112x faster).

## Root Cause Analysis

The dominant bottleneck is **type metadata bloat** in generated Lua code. The type serializer (`type_writer.writeLuaTypeImpl`) writes fully structural type expansions into `__S_` (symbol) and `__T_` (type alias) tables — every function's type signature is serialized by recursively inlining all referenced types with zero deduplication.

### Impact by module

| Module | Source | Compiled Lua | Expansion | Metadata % |
|--------|--------|-------------|-----------|------------|
| ast.chi | 17 KB | **2.6 MB** | 155x | 96.4% |
| emitter.chi | 35 KB | 840 KB | 24x | 93.3% |
| types.chi | 23 KB | 265 KB | 11x | ~85% |
| parse_ast.chi | 20 KB | 190 KB | 9x | ~80% |

The total compiled output (`chicc.lua`) is dominated by multi-megabyte type metadata strings that must be:
1. **Generated** — string-building 2.6 MB of type metadata for `ast.chi` alone
2. **Loaded** — LuaJIT must parse these enormous Lua source strings
3. **Decoded** — `type_writer.decodeType()` calls `loadstring('return ' .. spec)()` for every cross-module symbol lookup, parsing the bloated strings back into Lua tables

### Why ast.chi is the worst case

- `Expr` type: 50 fields, self-recursive, cross-references `Type` (13 fields from `chicc/types`)
- 97 functions in the module, 85 reference `Expr` in their signatures
- Each `Expr` serialization: ~18 KB (6 nested `Type` expansions at ~1.8 KB each)
- 150 full expansions across all functions: 150 x 18 KB = 2.7 MB

### Secondary performance issues

| Issue | Severity | Details |
|-------|----------|---------|
| While-loop closures | Moderate | Every `while` creates 2 closures for condition/bound. ~460 closures across all files. |
| `getTypeAlias` not cached | Moderate | In `compiler.chi:38`, `getSymbol` caches per-package but `getTypeAlias` decodes every time |
| `decodeType` uses `loadstring` | Moderate | Each call compiles a fresh Lua chunk — expensive for large type strings |

## Scope

Three changes, implemented in order. Each is independently testable and valuable.

### Change 1: Per-phase profiling instrumentation

Add `os.clock()` timing around each phase in `compiler.compile()`, gated by a flag so it has zero overhead when disabled.

**Where:** `compiler.chi`, function `compile()` (line 374)  
**Mechanism:** Embedded Lua using `os.clock()` before/after each of the 8 phases plus emit. Print timing to stderr when `CHI_PROFILE` environment variable is set, or when a `--profile` flag is passed.

**Output format:**
```
[profile] module_name: parse=12ms validate=1ms tables=5ms names=3ms convert=8ms types=45ms checks=2ms emit=120ms total=196ms
```

**Why first:** We need data to validate our hypotheses and measure improvement. Without profiling, we're guessing.

### Change 2: Cache `getTypeAlias` lookups

In `compiler.chi:38`, the `__chicc_mkEnv` factory, `getTypeAlias` decodes the type string on every call. Add a per-package alias cache parallel to the existing symbol cache.

**Where:** `compiler.chi`, line 38, the embedded `__chicc_mkEnv` function  
**Change:** Add `local aliasCache = {}` alongside `local cache = {}`. In `getTypeAlias`, check `aliasCache[qualifier]` first; if missing, decode all type aliases for that package at once and cache them.

**Expected impact:** Eliminates redundant `loadstring` calls during type inference. Moderate speedup for modules with many cross-package type references.

### Change 3: Nominal type references in serialized metadata

This is the main optimization. Instead of fully expanding named types structurally, emit a compact reference.

**Where:** `type_writer.chi`, function `writeLuaTypeImpl()` (line 92)  
**Change:** When serializing a type that has a `TypeId` (the `ids` field on records, sums, arrays, primitives), emit:

```lua
{tag="typeref",ids={{"chicc","ast","Expr"}}}
```

instead of the full 18 KB structural expansion.

**When to use typeref:** A type should be emitted as a typeref when ALL of:
1. It has a non-empty `ids` field (it's a named type defined somewhere)
2. It is NOT the type currently being defined in a `__T_` entry (to avoid circular references in the definition itself)
3. Its tag is `record`, `sum`, or `array` — NOT `primitive` (primitives are already ~30 bytes)
4. The type has fields/structure worth abbreviating (i.e., the structural expansion would be significantly larger than the typeref)

**When to expand fully:** 
- Primitive types (`int`, `string`, `bool`, `float`, `unit`, `any`) — already tiny (~30 bytes each)
- Anonymous record types (no `ids`) — no name to reference
- The type being defined in the current `__T_` entry (top-level definition must be structural)
- Types inside a `__T_` definition that are from the same package and same `__T_` table (to avoid circular lookup)

**Decoder changes:** `type_writer.decodeTable()` must handle `{tag="typeref", ids=...}`. Resolution:
1. Look up the type in the current module's `__T_` table
2. If not found, look it up from `package.loaded[qualifier]._types[name]`
3. Cache resolved typerefs to avoid repeated decoding

**Expected size reduction:**

| Module | Before | After (estimated) | Reduction |
|--------|--------|-------------------|-----------|
| ast.lua | 2.6 MB | ~25 KB | ~99% |
| emitter.lua | 840 KB | ~40 KB | ~95% |
| types.lua | 265 KB | ~30 KB | ~89% |
| parse_ast.lua | 190 KB | ~25 KB | ~87% |
| **Total chicc.lua** | **~4.2 MB** | **~200 KB** | **~95%** |

This directly reduces:
- Time spent in `encodeType()` (string building drops from MBs to KBs)
- Time spent in `loadstring` during `decodeType()` (parsing KBs instead of MBs)
- LuaJIT source loading time (parsing the compiled `.lua` files)
- Memory pressure throughout compilation

## Verification Strategy

**Do NOT recompile the entire compiler** as a routine test. Instead:

1. **Unit tests first:** Run existing test suite (`./run_tests.sh`) — especially `test_type_writer.chi`, `test_emitter.chi`, `test_compiler.chi`
2. **Targeted compilation:** Compile individual small `.chi` files with the modified compiler and verify output correctness
3. **Golden tests:** Run `./test_golden.sh` — 52 tests that verify end-to-end compilation output
4. **Size verification:** Check `.cache/chicc/*.lua` file sizes after each change
5. **Profiling data:** Use Change 1's profiling to measure before/after on a few representative modules
6. **Full self-compilation:** Only as a final validation step, once all tests pass

## Out of Scope

- While-loop closure optimization (separate change, smaller impact)
- `setmetatable` elimination (requires runtime changes)
- `chi_tostring` on string literal elimination (trivial impact)
- Incremental compilation cache improvements
- Self-compilation bug fixes (Bug 6)

## Risk

**Low risk for Change 1** (profiling) — additive, gated by flag.

**Low risk for Change 2** (alias caching) — mirrors existing symbol caching pattern.

**Medium risk for Change 3** (typeref) — changes the type serialization format. Existing compiled cache files will be incompatible and need to be regenerated. Key risk: the decoder must correctly resolve typerefs across module boundaries, including recursive types and type parameters. The existing test suite (`test_type_writer.chi`, `test_emitter.chi`, `test_compiler.chi`, golden tests) provides good coverage.
