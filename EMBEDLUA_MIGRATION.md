# embedLua → Native Chi — Migration Plan

Goal: remove as much `embedLua` (raw Lua statements) from the chicc compiler as
practical, replacing it with native Chi. `embedLua` that wraps genuinely
irreducible Lua FFI stays — but is documented as such, so what remains is
intentional, not accidental.

Status snapshot (this branch): **chicc `embedLua` calls: 331 → 96 (−235, −71%)**.
All cleanly-migratable cases are done and **fixed-point-verified after every
step**; the remaining 96 are intentional `KEEP` (genuine FFI, perf-critical raw
tables, and the error-handling design spike). See §10 for the final state.

## 0. Final outcome (what actually shipped)

Done, each its own commit, each `make verify`-clean (43/44; the 1 fail is the
worktree golden-dir issue):

| Step | What | embedLua |
|------|------|----------|
| Tier 1 | record field mutation → native `x.field = y` (ast, parse_ast, compiler markUsed, typer, type_writer) | −177 |
| Tier 2a | `table.insert` → `.push` / `.insertAt` | −24 |
| Tier 2b | `mergeImports`/`typeParamNames`/`splitExprs` → native fns; `io.open` probe → `std/io.file.open` | −3 |
| Tier 3 | constraints clear-array → native `clearConstraints` helper | −4 |
| Tier 3 | symbol/type tables (symbols/locals/aliases) → real `std/lang.map` API (also fixed the latent "Map costume" bug) | −10 |
| Tier 3 | `convertImports`/`convertTypeAliases` → native fns | −2 |
| Tier 3 | `collectRequires` → native AST walker reusing `exprChildren` | −1 (big block) |
| Tier 4 | union-find `uf` → `std/lang.map` (measured: ~13.0s vs ~12.8s baseline = noise) | −4 |
| Tier 3 | local-scope symbols, `packageAliasTable`, `importedSymbols` → `std/lang.map` | −5 |

**Perf boundary found (evidence-based KEEP):** converting the `mapType` `lookup`
and `instantiate` `__inst_cache` raw tables to `std/lang.map` measured a **~8–11%
clean-compile regression** (13.8–14.3s vs 12.8s baseline) — these are the hottest
inner-loop substitution/instantiation paths. **Reverted and kept as raw-table
FFI.** The union-find `uf`, by contrast, was negligible (~2%) and was kept
converted. Lesson: `std/lang.map`'s `m.map` indirection + per-access function call
is fine everywhere except the type-substitution hot loop.

> Note: `luaExpr` (raw Lua *expressions*) is a separate, larger surface (~930
> calls) and is **out of scope** here — this plan targets `embedLua` only, per
> the request. Many `luaExpr` reads stay even after an embedLua statement nearby
> is nativised (e.g. reading an `any`-typed Lua table field).

---

## 1. Categories

Every `embedLua` call falls into one of six buckets:

| Cat | Pattern | Native target | Verdict |
|-----|---------|---------------|---------|
| **A** | `x.field = y` — record field mutation | `x.field = y` | **trivial — DONE** |
| **B** | `tbl[key] = v`, `tbl[key] = nil`, `pairs(tbl)` — Lua table as hashmap | `std/lang.map` API (put/get/remove/forEach) | medium, some hot-path |
| **C** | `table.insert(arr, x)` / `(arr, pos, x)` / clear-loop | `arr.push` / `arr.insertAt` / clear helper | easy–medium |
| **D** | `pcall(...)`, `error(...)` — exception control flow | none (no try/catch in Chi) | mostly **keep**; 1 high-value win |
| **E** | `os.*`, `io.*`, `package.loaded`, `require`, `load`, metatables, `string.*` | thin stdlib wrappers or **keep** | mostly **keep** |
| **F** | `__chicc_* = function() … end` — Lua helper definitions | native Chi fn | split: pure-logic vs runtime-bound |

---

## 2. Tier 1 — Record field mutation (DONE ✓)

The single biggest bucket. `embedLua("e.field = value")` used purely to mutate a
record field. Proven safe two ways: (a) `ast.chi` already shipped native setters
(`setExprType`/`setExprTarget`) doing `e.field = t` on union-typed fields; (b) a
pilot converted every site, rebuilt, and `make verify` reached the fixed point.

Also confirmed empirically: **native field assignment works even when the
receiver is typed `any`** (`r.used = true` for `r: any`), so the `markUsed`
walker in `compiler.chi` converted cleanly too.

Converted: `ast.chi` (56), `parse_ast.chi` (87), `compiler.chi` (31 — the
`markUsed` `.used=true` sites + `expr.exprType=`), `typer.chi` (2),
`type_writer.chi` (1). Dead `std/lang` imports were dropped where neither
`embedLua` nor `luaExpr` survived (`parse_ast.chi`), or narrowed to `{ luaExpr }`
(`ast.chi`).

**Pitfall found & fixed:** a non-anchored sweep over-matched
`ns.getPreludeImports = __chicc_replPrelude` (compiler.chi:657/664). That is **not**
a record mutation — `__chicc_replPrelude` is a Lua global; the RHS does not exist
as a Chi name. Reverted to `embedLua`. Lesson: the `ident.ident = ident` shape is
necessary but not sufficient — the RHS must be a real Chi value in scope.

---

## 3. Tier 2 — Easy wins (next; no stdlib edits, no hot path)

Self-contained, mechanical, low risk. Recommended first PR after Tier 1.

### 3a. Array appends → `.push()` — Category C (~28 calls)
`std/lang.array` exports `push`, `pop`, `insertAt`, `removeAt` (confirmed at
`stdlib/std/lang.array.chi`). UFCS resolves `push` with **no import** (existing
native callers `type_writer.chi:236/248/264`, `inference_context.chi:231/258/288`
prove it).

- Array-typed targets — direct: `typer.chi:744` (`rfields`),
  `type_writer.chi:287,302` (`result`).
- `any`-typed targets — cast first (codebase already does this at
  `typer.chi:403/407`): `(msgs as array[any]).push(msg)`. Sites: `checks.chi`
  44/336/416/441/487/593/646, `typer.chi:144,154`, `symbols.chi:344`,
  `compiler.chi` resultMessages/`__chicc_parse_msgs`/`definedTypeAliases` family.
  Keep the message *literal* (`{code=,text=tostring(...),codePoint=nil}`) as a
  `luaExpr` value — only the `table.insert` wrapper becomes `.push`.
- **Do not touch** the `pairs()`-loop blocks at `inference_context.chi:301` and
  `unification.chi:227` — the `table.insert` there is incidental to a
  reflection block (Category B/F).

### 3b. Insert-at-position stragglers — Category C (2 calls)
- `unification.chi:384` `table.insert(queue, pos, nc)` → `queue.insertAt(pos, nc)`.
  Trivial: the identical call already appears 3× in the same function (303/345/376).
- `typer.chi:351,365` `table.insert(term.callParams, 1, x)` →
  `(luaExpr("term.callParams") as array[any]).insertAt(1, dotOp_receiver)`.

### 3c. Pure-logic helper fns → native — Category F (3 fns)
All in `compiler.chi`, all pure list logic, all return drop-in shapes:
- `__chicc_mergeImports` (:48) → `fn mergeImports(a,b): array[any]` (push-concat).
- `__chicc_typeParamNames` (:54) → `fn typeParamNames(params): array[string]`.
- `__chicc_splitExprs` (:60) → `fn splitExprs(exprs): {functions, code}` — the
  cleanest win; callers already read `.functions`/`.code`.

### 3d. One FFI probe → stdlib — Category E (1 call)
- `cli.chi:24` `io.open(libPath,"r") ~= nil` → `open(libPath,"r") != None`
  (`std/io.file.open` returns `Option[File]`). Add `import std/io.file { open }`.

---

## 4. Tier 3 — Contained data-structure changes (medium)

### 4a. The "Map costume" fix — Category B (symbols.chi + friends, ~13 calls)
**Important latent-bug finding.** `symbols.chi` imports `std/lang.map` and builds
`symbols`/`locals`/`aliases` via `emptyMap[…]()`, but every accessor bypasses the
API and indexes the **record** directly (`embedLua("symbols[name] = sym")`,
`luaExpr("symbols[name]")`). Because a Chi record is a plain Lua table, writes
land on the record body alongside `class`/`map`, and **`m.map` stays permanently
empty**. It "works" only by accident.

Migration is therefore also a correctness fix — but it must be **atomic per
container**: flip *all* accessors of one map together, or reads and writes will
target different tables (silent data loss).

- `symbols.chi`: `stAdd/stAddAlias/stGet/stRemove/stHas` (42/47/52/58/63),
  `fstAddLocal/fstGet/fstRemove` (79/88/103), `ttAdd/ttAddByName/ttGet`
  (118/123/128), `resolveType…` (412/427) → `.put/.get/.remove/.has`
  (`getOrDefault` handles the unit sentinel). Retype fields `any` → `Map[…]`.
- `packageAliasTable`/`importedSymbols` (156/157, writes 169/184, reads 213/244)
  — pure string→record maps, no iteration. Easy.
- `ast_converter.chi:964,972` reach into `tables.localTypeTable.aliases[…]` — same
  flip.

### 4b. Other self-contained maps — Category B
- `inference_context.chi` scope `symbols` (20/27/34/53, `pairs` at :59 →
  `forEach`). Construct via `emptyMap`.
- `checks.chi` `cnDefinedNames`/`newNames` (16/35, write 29, read 23, copy 36) —
  it's a name→`true` **set**; prefer `std/lang.set` over map.
- `types.chi` `lookup` (mapType:546/549, bulkReplace 462–467) — local, string-keyed,
  Type values; temp-nil/restore → remove/put.

### 4c. Clear-array idiom — Category C (typer.chi 404/547/624/862, 4 calls)
`for i=1,#constraints do constraints[i]=nil end`. **Aliasing is load-bearing**:
`constraints` is one table threaded by reference through recursive `typeTerm`;
reassigning `constraints = []` makes a *new* table and breaks the parent frame —
**not safe**. No native in-place clear exists. Two safe options:
- Add `pub fn clear[T](arr: array[T]) { embedLua("for i=#arr,1,-1 do arr[i]=nil end") }`
  to `stdlib/std/lang.array.chi`, call `(constraints as array[any]).clear()`.
  Localises the one remaining embedLua to a tested stdlib primitive (consistent
  with how `addLast`/`insertAt` already wrap `table.*`).
- Or, no stdlib edit: `val c = constraints as array[any]; while c.size()>0 { c.removeLast() }`.
- Hot path (incremental typing) — **re-time with `make verify`**, not just unit tests.

### 4d. More pure-logic helpers — Category F
- `__chicc_convertImports` (:66) / `__chicc_convertTypeAliases` (:72) → native,
  reusing existing `newImport`/`newImportEntry`/`newTypeAlias`. Add those three to
  the `import chicc/ast {…}` list (currently only the type names are imported).
- `collectRequires` (`emitter.chi:864`) → native recursive `walk` reusing the
  existing `exprChildren` (`ast.chi:376`) for child enumeration + `std/lang.map`
  for the seen-set. High value: deletes a ~40-line duplicated AST walker. Verify
  generated `require` lines are byte-identical (golden / `make verify`).
- `__chi_repl_fmt_type` (`cli.chi:162`) → native `fn fmtType(t): string`
  (tag switch + `joinToStringWithSeparator`).

---

## 5. Tier 4 — Hot-path / perf-sensitive (do last, measure each)

The type-inference inner loop was deliberately optimised (~30 min → ~6 s, see
`MEMORY` union-find + single-pass mapType + incremental typing). Wrapping these in
`map` calls adds an indirection (`m.map[k]`). Same O(1), likely fine — but
**benchmark `make verify` build time before/after**, do these separately.

- **B, perf:** `unification.chi` union-find `uf` (ufNew/Bind/Find/Resolve/AllBindings),
  `types.chi` `mapType` lookup (:549) + `__inst_cache` (global → local/param),
  `ast_converter.chi` `defaultArgs` **coordinated with** the consumer
  `emitter.chi:197` `pairs(expr.defaultValues)` (cross-file: producer and consumer
  flip together).
- **D, highest-value error win:** convert the *trial probes* — `unify` used only as
  a boolean — to a non-throwing predicate. Add `pub fn canUnify(constraints): bool`
  in `unification.chi` (same algorithm, returns `false` at the 8 `throwMessage`
  leaves instead of throwing). Then `icTrialUnify` (`inference_context.chi:196`,
  called by all 4 UFCS tiers — the hottest pcall) and `checks.chi:622` call it
  natively, deleting 2 `embedLua` pcalls + their `__trial_ok` plumbing. The
  sum-branch speculation (`unification.chi:395/424`) is real backtracking → factor
  `tryUnifyBranch(c, uf): array | unit` (partial bindings on success, `unit` on
  fail) and merge-or-fallback with native `if`. **Must be behaviourally identical**
  including union-find side effects, or UFCS overload selection silently drifts.

---

## 6. KEEP — genuine FFI (do **not** migrate; documented intentional)

- **Category D, top-level guards:** `compiler.chi:356/514/569/585` `pcall` around
  parse/convert/typecheck. They also catch arbitrary LuaJIT runtime crashes and
  bare-string invariant throws — only `pcall` can. Removing them removes the
  compiler's crash guard.
- **Category D, ensure/finally:** `inference_context.chi:103/110`
  `icWithNewLocalScope` — `pcall(f)` then *always* restore `icLocalSymbols`, then
  re-throw. Chi has no `try/finally`; this guarantees scope-stack restoration when
  a typer error unwinds through deep `typeTerm` recursion. The architectural
  lynchpin. Removing it corrupts the scope stack on the first error in a nested
  scope.
- **Category D, invariant throws:** `type_writer.chi:205/372` ("Unsupported type
  tag") — compiler-bug signals, idiomatic as throw + top-level catch.
- **Category E, the substrate:** `messages.chi:9` `setmetatable(_G, …)` chains
  global lookups to `__P_` (per-package exports). This is what lets bare names in
  *every* embedLua/luaExpr body resolve in separate-compilation builds. Load-bearing.
- **Category E, reflection:** all `package.loaded` iteration (`compiler.chi:37`
  `__chicc_mkEnv`, `:653` `__chicc_replPrelude`, `inference_context.chi:301`,
  `symbols.chi:253/260/268`, `type_writer.chi:380`). No native construct enumerates
  loaded modules.
- **Category E, cross-module dispatch:** the ~46 `require('chicc/…')` bodies are
  **circular-import workarounds** (e.g. typer ↔ inference_context ↔ symbols). Chi
  `import` cannot express a cycle. Blocked until cycles are broken (separate
  architectural task), then revisit.
- **Category E, dynamic eval:** `cli.chi:94/101/191/197` `load`+`pcall` (run
  compiled user/REPL code), `type_writer.chi:380` `loadstring('return '..spec)()`
  (type-spec deserialisation).
- **Category E, formatting:** `string.format`/`string.char`/`tostring`/`tonumber`
  in profiling, float-formatting, error-stringification.
- **Category F, runtime-bound:** `__chicc_printProfile` (os.clock/io.stderr/
  string.format + 0-indexed `ts[0]` table Chi arrays can't hold),
  `__deep_copy_type` wrapper (loadstring/package.loaded), `__chi_repl_format`
  (`type()`/package.loaded/string.char), `ufAllBindings` `pairs` (dynamic
  string-keyed union-find + regex/tonumber, perf-critical).

---

## 7. Separate design spikes (NOT part of this cleanup)

These would unlock more removals but are architectural, not mechanical:

1. **Value-based error typer** — make `typeTerm`/`unify`/`icGetTargetType` return
   errors as values (`Type | Message`) or use an abort-style **effect** (chicc's
   first effect; handle-without-resume). Removes nearly all Category-D embedLua in
   the typer *and* the ensure-pcall. Large, invasive, high regression risk in the
   most complex module. Pre-req: unify the three thrown-value shapes (ad-hoc
   `{code,text}` / `Message` / bare string) onto the `Message` record first. Even
   then, a `pcall` stays as a LuaJIT crash guard.
2. **Break import cycles** to replace `require('chicc/…')` with normal imports.
3. **stdlib I/O wrappers** (`writeErr`/`flushErr`/`writeOut`/`flush`/
   `readLineOrEof`) so `cli.chi` REPL I/O and `compiler.chi` profiling drop raw
   `io.*`. Cross-repo: touches `stdlib`, needs a rebuilt `std.chim` under
   `CHI_HOME` before chicc can import it (repos are independent, committed
   separately). REPL `readLineOrEof` must preserve `io.read('*l')`'s `nil`→`unit`
   EOF signal (the `while line != unit` loop depends on it) — `std/io.readLine` is
   **not** a drop-in.

---

## 8. Verification protocol (run after every step)

```
make            # rebuild chicc.lua  (force a clean build: rm chicc.lua && rm -rf .cache)
make test       # expect 43/44 — test_parser_compat fails only because the golden
                # dir is unreachable from a worktree; that 1 failure is the baseline
make verify     # fixed-point self-compile — MUST reach "FIXED POINT REACHED"
```

`make` alone may say "Nothing to be done" (its only prerequisite is `compile.chi`,
not the `chicc/*.chi` sources) — when in doubt `rm -f chicc.lua` first. For
hot-path changes (Tier 4, §4c) compare `make verify` build time, optionally with
`CHI_PROFILE=1`.

---

## 9. Recommended sequencing

1. **Tier 1** — done ✓ (177 calls).
2. **Tier 2** (§3) — one PR: array appends + insert stragglers + 3 pure-logic
   helpers + the `io.open` probe. Mechanical, ~60–90 calls, near-zero risk.
3. **Tier 3a** (§4a) — the symbols.chi map fix, on its own (latent-bug fix, atomic
   per container).
4. **Tier 3b–3d** — remaining contained maps, the clear-array helper, the
   medium helpers (`convertImports`, `collectRequires`, `fmtType`).
5. **Tier 4** — perf-sensitive maps + the trial-probe `canUnify` win, each
   separately, each benchmarked.
6. Leave §6 as documented FFI; treat §7 as independent design work.

Rough remaining reducible surface after §6 is excluded: of the 154 current calls,
~60–90 are Tier 2/3 reducible; the rest are KEEP or gated behind a design spike.

---

## 10. Final state of the remaining 96 `embedLua`

Buckets of what is left (all intentional):

- **~29 — D, error control flow (KEEP / design spike):** the top-level parse/
  convert/typecheck `pcall` guards (also catch LuaJIT crashes), the
  `icWithNewLocalScope` try/finally scope-restore, the `error({code,text})` throws,
  and the trial-probe pcalls (`icTrialUnify`, sum-branch speculation,
  `returnTypeCheck`). The trial probes *could* be nativised via a non-throwing
  `canUnify`/`tryUnifyBranch`, but that needs a second, behaviourally-identical
  copy of the unifier and is the **value-based-error design spike (§7)**, not a
  mechanical edit — deferred.
- **~24 — E, irreducible FFI (KEEP):** `_G` metatable substrate (messages.chi),
  all `package.loaded` reflection (`__chicc_mkEnv`, `__chicc_replPrelude`, the
  loaded-package scans), `require('chicc/…')` cross-module dispatch (blocked by
  import cycles), `load`/`loadstring`, `os.*`/`io.*`, `string.format`/`string.char`,
  `tostring`.
- **~5 — B, hot-path raw tables (KEEP for perf):** `mapType` `lookup` +
  `instantiate` `__inst_cache`. Measured ~8–11% compile regression if wrapped in
  `std/lang.map` (see §0). Legitimate perf-FFI, like stdlib's own map/array impls.
- **~3 — profiling (KEEP):** `__chicc_printProfile` + the `__ts`/`__prof`
  chunk-locals (os.clock/io.stderr/string.format + a 0-indexed table Chi arrays
  can't hold).
- **~3 — B, `defaultValues` (DEFER):** producer (`ast_converter` `defaultArgs`) +
  consumer (`emitter:197` `pairs`) must change together; cross-cutting, low value.
- **remainder — misc (DEFER/KEEP):** `checks.chi` name-set (better as
  `std/lang.set`, but the pairs-copy is awkward), `type_writer` decode chunk-locals
  (`__defining_type_id`, `__typeref_cache` — coupled to the loadstring decode),
  a couple of array-index assignments, `cli.chi` REPL formatter, the mixed
  `rt.ids` reflection block.

Net: every `embedLua` that was a plain field mutation, array append, dynamic-key
map (outside the type-substitution hot loop), or pure-logic helper is now native
Chi. What remains is genuine Lua interop, a perf-critical exception, or work that
belongs to a separate error-handling redesign.
