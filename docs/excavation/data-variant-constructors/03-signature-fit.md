# Variant (`data`) constructors — signature-fit review (Phase 3)

Adversarial trace of the Phase 2 signatures against the *actual* declared
surface in `chicc/chicc/*.chi` + `runtime/chi_runtime.lua`. The goal is not to
agree with the architecture but to find where the declared types cannot carry
what the next stage needs. No fixes are proposed; gaps are listed at the end.

Conventions: `file:fn` references are to the real declared signatures read for
this review. "Sum `Shape`" / "record `Circle`" mean `Type` values with
`tag == "sum"` / `tag == "record"`.

---

## What the signatures actually are (ground truth)

- `lowerVariantTypes(parseProg: any, pkg: any, tables: any): array[Expr]`
  (`ast_converter.chi:945`). Stub returns `[]`. All three params are `any`.
  Called once from `convertProgram` (`ast_converter.chi:995`), result spread
  as the *prefix* of `converted` (line 999), i.e. ctor decls run before code.
- `createVariantExpr(fields: array[ExprField], variantName: string, section): Expr`
  (`ast.chi:156`). Produces a `create_record` Expr with `variantName` set;
  identical otherwise to `createRecordExpr`.
- `variantNameOf(t: Type): string | unit` (`types.chi:132`). `t.tag == "record"
  && t.ids.size() > 0 ? t.ids[1].name : unit`.
- Parse-side payload (`parse_ast.chi`): `ParseVariantTypeDefinition =
  { typeName, typeParameters, constructors, section }` (line 170);
  `VariantConstructor = { isPublic, name, fields, section }` (176);
  `FormalField = { isPublic, name, typeRef, section }` (91).
  **No `pvt*`/`vc*`/`ff*` accessor functions exist in `chicc/*.chi`** — the only
  `pvtName`/`vcFields` helpers live in `tests/test_parser_types.chi:323-330` as
  local `luaExpr("v.typeName")` shims. So `lowerVariantTypes` reads these via raw
  `.field` access on `any` (or its own `luaExpr`), exactly like the rest of the
  converter already does for `FormalArgument` (`ast_converter.chi:359-362`).

---

## Scenario A — `Circle(2)` construction

Source: `data Shape = Circle(r: int) | Rect(w: int, h: int)` then `Circle(2)`.

Trace:

1. **Parse → lowering.** `convertProgram` (`ast_converter.chi:951`) reads
   `parseProg.variantTypes : array[any]` (each elem a `ParseVariantTypeDefinition`)
   and hands the whole `parseProg` to `lowerVariantTypes`. Lowering must iterate
   `parseProg.variantTypes`, and per decl read `.typeName` ("Shape"),
   `.typeParameters` (here `[]`), `.constructors` (two `VariantConstructor`s).
2. **Lowering → Represent (type table).** For ctor `Circle`, lowering reads
   `.fields : array[FormalField]` = `[{name:"r", typeRef:<int ref>}]`. It must
   resolve each `FormalField.typeRef` via
   `resolveType(tt, [], typeRef, level): Type` (`symbols.chi:289`) → `tInt`.
   Then build the nominal record:
   `recordType(ids, [{name:"r", fieldType:tInt}], [])` (`types.chi:74`) where
   **`ids` must be non-empty** — `[ newTypeId(mod, pkg, "Circle") ]` — so
   `variantNameOf` later answers "Circle". This record must be registered under
   the name `"Circle"` in `tt.aliases` (the only registry `resolveType` reads —
   `symbols.chi:311` `ttGet`). The `Shape` sum is
   `sumType([], circleRec, rectRec, [])` (`types.chi:80`) (or `sumCreate`),
   registered under `"Shape"`.
3. **Lowering → converted program.** Per ctor, lowering must produce
   `nameDeclarationExpr(isPub, "Circle", false, funcType, fnBody, sec)`
   (`ast.chi:198`) where `fnBody = fnExpr([param r], unit, body, sec)`
   (`ast.chi:208`) and `body = createVariantExpr([newExprField("r", read r)],
   "Circle", sec)` (`ast.chi:156`). The `funcType` is
   `functionType([tInt, shapeSum], [], 0)` (`types.chi:68`) — params then return.
   It must also `addLocalSymbol("Circle", false, isPub, funcType, pkg, tables)`
   (`ast_converter.chi:68`) so the call site resolves.
4. **Typer.** `Circle(2)` is a `fn_call` (`typer.chi:342`). Callee
   `variable_access "Circle"` → `icGetTargetType` (`inference_context.chi:121`)
   instantiates the registered symbol's `funcType`. Call builds
   `functionType([tInt, fresh], [], 0)` and constrains it equal to the callee
   type (`typer.chi:407`); `fnCallResult` unifies to the return = sum `Shape`.
   The ctor *body* `create_record` is typed at `typer.chi:261-276` →
   `recordType([], fields, [])` — **empty `ids`** — and constrained against the
   declared return sum `Shape` via the fn's return constraint (`typer.chi:327`).
5. **Emitter.** `Circle(2)` → `emitFnCall` → calls the emitted `Circle`
   function whose body is the `create_record`. `emitCreateRecord`
   (`emitter.chi:638`) emits `local tN={r=...}; setmetatable(tN,
   record_meta_table);` and **ignores `expr.variantName` entirely** (no read of
   `variantName`/`exprVariantName` anywhere in `emitter.chi`).

Findings (A):

- **A1 — the `ids`/alias-transparency collision is real, and lands in the
  typer, not the emitter.** `resolveType` for a `TypeNameRef` returns
  `alias.aliasType` *by value* (`symbols.chi:313-314`): type aliases are
  transparent. The architecture (OQ1) needs `Circle` to resolve to a record
  *with non-empty `ids`*. That is internally consistent — nothing forces an
  alias's stored type to have empty `ids`. BUT: the *body* of the constructor is
  typed by `typer.chi:276` which hard-codes `recordType([] ...)`. So the
  value produced by `Circle(2)` has the **empty-`ids`** record type, while the
  *name* `Circle` resolves to the **non-empty-`ids`** record type. These two are
  `typeEquals` (record equality ignores `ids` — `types.chi:203-219`) and unify
  (unification record branch iterates `expected.fields` only, never `ids` —
  `unification.chi:357-386`), so type-checking passes. The consequence is purely
  that **the runtime tag must be set at construction, from the
  `create_record.variantName`, not derived from the value's inferred type** —
  because the value's inferred type has no `ids`. The `variantName` field on the
  Expr is therefore load-bearing and `emitCreateRecord` not reading it is the gap
  (expected: Phase 5 body), but the *signature* is sufficient: `exprVariantName`
  exists.

- **A2 — `lowerVariantTypes` cannot call `convertFuncWithNameImpl`; it must
  duplicate the function-building tail.** `convertFuncWithNameImpl`
  (`ast_converter.chi:420`) is wall-to-wall parse-AST accessors:
  `node.paName()`, `node.paFormalArguments()`, `node.paReturnTypeRef()`,
  `node.paFuncBody()`, and per-arg `luaExpr("arg.typeRef")`. A synthesised
  constructor has **no `ParseAst` node** — its inputs are a `VariantConstructor`
  + the already-built sum `Type`. To reuse `convertFuncWithName` lowering would
  have to fabricate a fake `ParseFuncWithName` `ParseAst` (build a
  `ParseAst`-shaped table with a `ParseBlock` body whose single statement is a
  `ParseCreateRecord`) — and even then `ParseCreateRecord` lowers to
  `createRecordExpr` (`ast_converter.chi:306-319`), which **drops the
  `variantName`** (there is no parse node carrying it). So fabricating a parse
  node cannot produce a `createVariantExpr` body. Conclusion: `lowerVariantTypes`
  must hand-assemble `newFnParam` + `fnExpr` + `nameDeclarationExpr` +
  `addLocalSymbol` itself, duplicating ~10 lines of the `convertFuncWithName`
  tail. The "key reuse insight" in the architecture (reuse
  `convertFuncWithNameImpl`) does **not** hold at the signature level. This is a
  design-friction finding, not a missing signature — the constructors
  (`fnExpr`, `nameDeclarationExpr`, `newFnParam`, `addLocalSymbol`) are all
  reachable; they just have to be called directly.

- **A3 — no `tInt` etc. on the emitted `create_record` fields is fine, but the
  param read path is unspecified.** The ctor body needs
  `variableAccessExpr(localTarget("r"), sec)` as the field value, and `"r"` must
  be a local in the fn's `FnSymbolTable`. `addLocalSymbol` with
  `currentFnSymbolTable != unit` routes to `fstAddLocal` (`ast_converter.chi:69`);
  but `lowerVariantTypes` runs in `convertProgram` at top level where
  `currentFnSymbolTable == unit`, so it must set up a `FnSymbolTable` for the
  synthetic fn exactly like `convertFuncWithNameImpl` does
  (`ast_converter.chi:489-492`). Another slice of duplicated machinery (see A2).

---

## Scenario B — `s is Circle` (discrimination)

Trace:

1. **Convert.** `ParseIs` → `isExpr(inner, checkedType, sec)` (`ast.chi:299`).
   `checkedType = resolveType(tt, vars, node.paTypeRef(), level)`
   (`ast_converter.chi:286`). For the `TypeNameRef "Circle"`, `resolveType`
   (`symbols.chi:294-318`) → `ttGet("Circle")` → `alias.aliasType`. **This is the
   exact record-with-non-empty-`ids` that lowering must have registered.** If
   lowering registered it, `checkedType` is `record{ids=[Circle], r:int}`. If it
   did not (current stub), `ttGet` returns `unit` → `resolveType` prints
   `ERROR: Unknown type 'Circle'` and returns `tAny` (`symbols.chi:316-317`).
2. **Typer.** `is` (`typer.chi:897-901`) types the inner value and returns
   `tBool`; it does **not** touch `checkedType`. So `checkedType` flows untyped
   straight to the emitter — good, no loss.
3. **Emitter.** `emitIs` (`emitter.chi:727`) reads
   `checkedType.tag` and `checkedType.ids[1].name` (`emitter.chi:734-736`). For a
   variant this is `tag=="record"`, name `"Circle"`. But the current `emitIs`
   record branch emits `chi_is_record($value)` (`emitter.chi:768-769`) — true for
   *every* record, which is precisely the bug (OQ3). The new branch must key on
   `variantNameOf(checkedType)` and emit `chi_is_variant($value,"Circle")`.

Findings (B):

- **B1 — `checkedType` is correct *iff* B-step-1 registration happened; there is
  no second source.** `emitIs` reads `ids[1].name` directly
  (`emitter.chi:736`) and never consults the type table. So the *only* way
  `emitIs` can distinguish `Circle` from `Rect` is if `resolveType` already
  embedded the name in `ids`. This pins down a hard requirement on
  `lowerVariantTypes`: the registered alias type's `ids[1].name` must equal the
  source variant name verbatim. The signature `recordType(ids, ...)` carries
  this; the risk is purely that lowering forgets to populate `ids` (then `is`
  silently degrades to `chi_is_record`, reintroducing the bug with no error).

- **B2 — static-equal short-circuit will fire wrongly for variants.** `emitIs`
  has an early return: if `valueTag == checkedTag` and the tag is non-primitive,
  it returns the literal `"true"` (`emitter.chi:739-747`). For `s is Circle`,
  `s` has type sum `Shape` (tag `"sum"`) and `checkedType` is `record`
  (tag `"record"`) — tags differ, so the short-circuit does *not* fire here.
  But for a value already typed as a variant record (e.g. inside a branch after
  `as`, or `Circle(2) is Circle`), `valueTag == checkedTag == "record"` →
  returns `"true"` unconditionally, never reaching the variant branch. The
  `emitIs` *signature* (it only gets the `Expr`) is enough to fix this, but the
  existing control flow is hostile: the variant check must be hoisted **above**
  the same-tag short-circuit, otherwise `record is OtherVariant` mis-emits
  `true`. This is a body-level hazard the signature does not prevent.

---

## Scenario C — `s as Circle` then `c.r` (cast + field access)

Trace:

1. **Convert.** `ParseCast` → `castExpr_(inner, targetType, sec)`
   (`ast_converter.chi:278-282`); `targetType = resolveType(... "Circle")` =
   the registered record-with-`ids`.
2. **Typer (cast).** `typer.chi:598-603`: types the inner expr, then returns
   `term.targetType` *verbatim*. So `(s as Circle).exprType` = the registered
   `Circle` record (with `ids` and with the `r:int` field). No unification of
   the cast result against the source — unchecked passthrough, as designed.
3. **Typer (field access `c.r`).** `field_access` (`typer.chi:409-466`):
   receiver `c` resolves to the `Circle` record; `effectiveReceiverType.tag ==
   "record"` (`typer.chi:439`), it finds field `r` (`:449`), emits a constraint
   `record{r: fresh} = receiverType` and returns `fresh` → unifies to `int`.
   **Field access type-checks** because the cast's target type carried the
   fields. Good.
4. **Emitter (cast).** `emitCast` (`emitter.chi:596`) reads source/target
   `ids[1].name`. For target `Circle` (record) it falls through all the
   string/int special cases and returns `value` unchanged (passthrough) —
   correct for an unchecked variant cast. No emitter change strictly needed for
   `as`; the architecture says the same.

Findings (C):

- **C1 — the design works here *because* `resolveType` returns the alias type
  by value with its fields intact.** The cast result type is the registered
  `Circle` record, so `.r` resolves structurally. This is the one scenario where
  every signature lines up with no adaptation. The only dependency is again C-1
  ⇒ B-1 ⇒ A-2: lowering must register `Circle` with **both** the non-empty `ids`
  *and* the structural fields. A single `recordType([CircleId], [{r:int}], [])`
  satisfies all three readers (`variantNameOf`, `emitIs`, field access). No
  signature gap.

- **C2 — `instantiate` on the constructor symbol could strip nothing but is a
  latent worry.** `icGetTargetType` instantiates the symbol's `funcType`
  (`inference_context.chi:130`). `instantiate`/`instantiateInner`
  (`types.chi:700`/`628`) rebuilds records via `recordType(t.ids, ...)`
  (`types.chi:675`) — `ids` preserved. So the sum return type's branch records
  keep their `ids` through instantiation. Confirmed non-issue, but only because
  every reconstruction path in `types.chi` threads `t.ids`; if any new code path
  rebuilds with `[]` the nominal tag is silently lost.

---

## Scenario D — ERROR: `data Box[T] = Wrap(value: T)` (generic variant, out of scope)

Trace:

1. **Parse.** Parser accepts type params: `ParseVariantTypeDefinition.typeParameters
   = [{name:"T"}]` (the parser test `test_parser_types.chi:438-440` exercises
   `Container[T]`). So a generic `data` decl arrives in `parseProg.variantTypes`
   fully formed.
2. **Lowering.** `lowerVariantTypes(parseProg, ...)` is the **only** place that
   inspects `variantTypes`. Nothing downstream looks at `typeParameters` for
   variants. So the unsupported-generics diagnostic has exactly one possible
   owner: `lowerVariantTypes`. The edge table (architecture) already assigns
   "type params present → unsupported" to *Lower*. Consistent.
3. **What happens if lowering does NOT check (the danger).** If lowering ignores
   `typeParameters` and proceeds: it would resolve `FormalField.typeRef` for
   `value: T`. `T` is a `TypeNameRef "T"` (or `TypeParameterRef`). In
   `resolveType` (`symbols.chi:294-319`), `T` is matched against
   `typeSchemeVars`; `lowerVariantTypes` builds that list itself. If it passes
   `[]` (no scheme vars), `T` is neither a known primitive nor in `tt.aliases`
   → prints `ERROR: Unknown type 'T'` and returns `tAny` (`symbols.chi:316-317`).
   The ctor would then be registered as `Wrap(value: any) -> Box` and **compile a
   wrong program silently** (modulo the stray ERROR print, which is not a hard
   failure — `resolveType` returns `tAny` and keeps going).

Findings (D):

- **D1 — the stub signature lets generics through with no diagnostic and a
  miscompile.** `lowerVariantTypes(...): array[Expr]` has **no error channel**.
  The rest of the compiler raises errors either by `embedLua("error({code=...})")`
  (e.g. `inference_context.chi:127`) or by `typerErr(...)` (`typer.chi:927`), or
  degrades via `println("ERROR: ...")` + fallback (`symbols.chi:316`). Returning
  `array[Expr]` gives lowering no structured way to signal "unsupported". The
  owner is correct (Lower), but the **return type cannot express failure** — the
  body must reach for `embedLua("error(...)")` out-of-band, which the signature
  neither documents nor requires. This is the one place where the stubbed
  signature is *insufficient to carry the needed info to the next stage*: there
  is no "this decl is rejected" value, so a forgetful body silently miscompiles
  (D-the-danger above). Whether that is acceptable depends on the project's error
  convention (degrade-and-print vs hard `error`), but the signature does not pin
  it.

- **D2 — `typeParameters` is read-once and unguarded by type.** Because it is
  `array[any]` on an `any`-typed `parseProg`, nothing type-level distinguishes
  "0 params (OK)" from ">0 params (reject)". The guard is a hand-written
  `.size() > 0` the body must remember to write.

---

## Scenario E — overlapping shapes `data Temp = Celsius(degrees: int) | Fahrenheit(degrees: int)`

Both ctors have identical structural shape (`{degrees: int}`). The whole point
of the nominal `ids` is to tell them apart.

Trace:

1. **Lowering** registers `Celsius` = `recordType([CelsiusId], [{degrees:int}], [])`
   and `Fahrenheit` = `recordType([FahrenheitId], [{degrees:int}], [])`. Both have
   `tag=="record"`, identical `fields`. They differ **only** in `ids[1].name`.
2. **Typer.** `typeEquals(Celsius, Fahrenheit)` (`types.chi:180`) → record branch
   (`:203-219`) compares **only field name+type**, ignores `ids` → returns
   `true`. Likewise `unification` record branch ignores `ids`
   (`unification.chi:357`). So **to the type system the two variants are the same
   type.** Sum dedup is the sharp edge: `sumCreate` (`types.chi:354`) builds the
   `Temp` sum by `typeExistsInArray` dedup using `typeEquals` (`:362`,`:371`).
   Since `Celsius typeEquals Fahrenheit`, **`sumCreate` would collapse the two
   into one branch** — `Temp` would become a single-branch "sum" =
   just `Celsius` (the first). If lowering uses `sumCreate`, `Fahrenheit` is
   silently dropped from the union type. If it uses raw `sumType`
   (`types.chi:80`, no dedup), both branches survive.
3. **Runtime discrimination.** Independent of the type-level collapse: at
   runtime each ctor sets its own metatable name (A1), and `emitIs` keys on
   `variantNameOf == "Celsius"` vs `"Fahrenheit"` → `chi_is_variant(v,"Celsius")`
   vs `chi_is_variant(v,"Fahrenheit")`. So *runtime* discrimination is correct
   end-to-end **regardless** of the type-level collapse, as long as A1 is honored.

Findings (E):

- **E1 — `sumCreate` vs `sumType` choice is load-bearing and the signatures do
  not force the right one.** `types.chi` exposes both `sumType` (no dedup, line
  80) and `sumCreate` (dedup via `typeEquals`, line 354). For structurally-equal
  variants, `sumCreate` collapses them and `Temp` loses a branch at the type
  level. The architecture's edge table says "compose the data type as the `sum`
  of them (`sumType`, types.chi:80)" — it names `sumType`, which is the safe one.
  But nothing in the *signature* of `lowerVariantTypes` enforces that; a body
  that reaches for the "smart" `sumCreate` (as `resolveType`'s SumTypeRef path
  does *not* — it uses plain `sumType` at `symbols.chi:378`) would mis-type
  overlapping variants. Latent footgun, owned by Lower.

- **E2 — `typeEquals` ignoring `ids` means a value typed as `Celsius` is
  assignable where `Fahrenheit` is expected.** `f(c: Fahrenheit)` called with a
  `Celsius` value type-checks (records unify ignoring `ids`). For *this issue*
  that is harmless (the repro never cross-assigns), and matches the "field access
  is structural, discrimination is nominal/runtime" design. But it means the
  nominal identity exists **only** at runtime + in `emitIs`/`variantNameOf`; the
  type system provides zero nominal safety. Worth stating explicitly because it
  is the flip side of the design that makes B/C/E's runtime path work without
  typer changes.

---

## Concrete signature gaps found

1. **`lowerVariantTypes(...): array[Expr]` has no failure channel (D1).** There
   is no value to express "this `data` decl is rejected" (generic variant,
   duplicate ctor name, unresolved field type). The owner is correctly *Lower*,
   but the return type cannot carry a rejection, so the body must signal
   out-of-band (`embedLua("error(...)")` or `println`+degrade) — undocumented by
   the signature, and a forgetful body silently miscompiles a generic `data`
   (D-danger).

2. **No `pvt*`/`vc*`/`ff*` accessors exist in compiler source** (only in the
   test file). `lowerVariantTypes` must read `ParseVariantTypeDefinition` /
   `VariantConstructor` / `FormalField` via raw `.field` / `luaExpr` on `any`.
   Not strictly a *missing* signature (the records are plain), but the typed
   accessor surface the architecture implies ("`.fields : array[FormalField]`")
   does not exist as callable functions — consistent with the rest of the
   converter, just worth noting it is all `any`-typed field poking.

3. **The "reuse `convertFuncWithNameImpl`" insight does not hold (A2/A3).** That
   function is driven entirely by `ParseAst` accessors (`paName`,
   `paFormalArguments`, `paFuncBody`, …) and its create-record path goes through
   `createRecordExpr`, which drops `variantName`. A synthetic constructor has no
   `ParseAst` and needs a `createVariantExpr` body, so `lowerVariantTypes` must
   re-implement the function-symbol-table setup + `fnExpr` +
   `nameDeclarationExpr` + `addLocalSymbol` tail by hand. No signature is
   missing — they are all individually callable — but the headline reuse is a
   duplication in practice.

4. **`addLocalSymbol(name, isMut, isPub, symType, pkg, tables)` is sufficient to
   register the ctor name (no gap).** At `convertProgram` top level
   `currentFnSymbolTable == unit`, so it routes to `ctDefineSymbol` with the full
   `funcType` (`ast_converter.chi:73-77`), and `Circle(2)` resolves as a
   package-level fn call via `getSymbol` → `ctGetLocalSymbol`. Confirmed adequate.

5. **`variantName` on `Expr` is load-bearing and currently unread (A1/A2).** The
   ctor body's record type is typed with empty `ids` (`typer.chi:276`), so the
   *value*'s inferred type cannot supply the runtime tag — only
   `createVariantExpr`'s `variantName` can. The accessor `exprVariantName`
   exists, but `emitCreateRecord` does not read it yet (expected: Phase 5 body).
   No signature gap; flagged so the Phase 5 body does not instead try to derive
   the tag from `expr.exprType` (which is tagless).

6. **No runtime helpers exist yet (`chi_is_variant`, `chi_variant_meta`).**
   `runtime/chi_runtime.lua` has `record_meta_table` (line 123) and
   `chi_is_record` (line 42) but nothing variant-specific. Expected (Phase 5),
   listed for completeness — the emitter signatures (`emitIs`, `emitCreateRecord`)
   can already emit calls to not-yet-defined Lua names, so this is a runtime gap,
   not a Chi-signature gap.

### Body-level hazards the signatures do not prevent (not gaps, but flagged)

- **B2:** `emitIs`'s same-tag short-circuit (`emitter.chi:739-747`) returns
  `"true"` for `record is record` before any variant check — the variant branch
  must be hoisted above it or `record is OtherVariant` mis-emits `true`.
- **E1:** `lowerVariantTypes` must use `sumType` (no dedup), **not** `sumCreate`,
  or structurally-identical variants (Scenario E) collapse to one branch.
- **C2/E2:** nominal identity lives only at runtime + `variantNameOf`/`emitIs`;
  `typeEquals`/`unification` ignore `ids`, so the type system gives no nominal
  safety and every record-reconstruction path must keep threading `t.ids` or the
  tag is lost.

---

## Self-Review (main agent, post-review)

**Verdict: signatures hold — no return to Phase 2.** The one flagged signature gap (D1, no failure channel on `lowerVariantTypes`) is resolved by the codebase's existing convention, not a type change: conversion errors are thrown as `error({code,text})` and caught by the `pcall` around `convertProgram` (compiler.chi:595-605), then surfaced as a clean message. `array[Expr]` is the right return type; rejection is out-of-band by throw, identical to `icGetTargetType`'s UNRECOGNIZED_NAME.

**Pass-through check (Phase 3 gate question).** No trace showed a redundant pass-through layer. The closest was typer `is`/`cast` returning `tBool`/`targetType` without touching the value's type — but that is load-bearing (it lets `checkedType`/`targetType` reach the emitter untransformed, which the variant branches depend on), not dead forwarding.

**Disposition of findings:**
- A2/A3 (reuse insight doesn't hold) → architecture "Key reuse insight" corrected: hand-assemble the fn tail; pieces reusable, orchestrator not.
- D1 (failure channel) → documented as throw-based in architecture; no code change.
- A1, B2, E1, C2/E2 (body hazards) → captured verbatim as the "Phase 5 implementation hazards" checklist in 01-architecture.md so bodies can't silently regress them.
- Gap 2 (no pvt*/vc* accessors) → accepted: `lowerVariantTypes` reads parse records via raw `.field`/`luaExpr`, consistent with the rest of the converter.
- Gap 6 (runtime helpers absent) → expected Phase 5 work, listed in the hazards checklist.

These hazards directly shape the Phase 4 contract tests: include `Circle(2) is Circle` / `(s as Circle) is Rect` (forces B2), and the overlapping-shape `Temp` case (forces E1).
