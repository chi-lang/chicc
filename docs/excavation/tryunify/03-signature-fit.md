# tryUnify (issue #12) — Phase 3: Signature-fit review (adversarial)

Reviewed signatures (stubs in `chicc/unification.chi`):

```chi
type Binding = { variable: Type, replacement: Type }                  // line 24
fn unifyCore(constraints: array[any], uf: any): Message | unit       // line 271
pub fn tryUnify(constraints: array[any]): array[Binding] | unit      // line 281
```

Consumers after rewiring: the two sum branches inside the core
(today `unification.chi:417` / `:446`), `inference_context.chi:197`
(`icTrialUnify`), `checks.chi:622` (return-type check). Throwing facades:
`unify` (`unification.chi:476`), `unifyWithUf` (`unification.chi:287`,
body moves into `unifyCore`).

Verdict up front: the signatures are *consumable* at all four sites with
at most one cast each, and the `!= unit` idiom typechecks (verified
against the typer's `==`/`!=` rule, see S2 step 5). But the file as
stubbed cannot express the architecture's Core → tryUnify call edge at
all (F1), the unit-polarity design has two silent-miscompile failure
modes that the type system cannot catch (F2, F3), and the "never
throws" contract on `tryUnify` is false in exactly the case where the
only handler was the `pcall` this refactor deletes (F7 — `checks.chi`
runs with **no** handler above it).

---

## Scenario S1 — successful expected-sum probe, bindings merged into session UF

Setup: compiling non-function top-level code; a constraint
`Constraint(expected = A | B, actual = B')` reaches the core, where `B'`
unifies with `B` (the rhs) after binding one type variable `t1`.

Call chain (post-rewiring):

1. `compiler.chi:643` (embedLua harness, inside `pcall`) →
   `_unif.unifyWithUf(codeConstraints, uf)`.
   Value at boundary: `codeConstraints` is a raw Lua table built by
   `typer.typeTerm` pushes — declared `array[any]` at the facade,
   actually an array of `Constraint` records. `uf` is the session
   union-find (`Map` from `ufNew`), declared `any`. Fine — FFI caller,
   no declared types to lie about.
2. `unification.chi:unifyWithUf` (facade) → `unifyCore(constraints, uf)`.
   Passed: `(array[any], any)`. Returns `Message | unit`. The facade
   must write `if r != unit { throwMessage(r as Message) }` — note the
   **cast**: `throwMessage(msg: Message)` does not accept the sum, so
   the narrowing is on the facade author, unchecked at runtime.
3. Inside `unifyCore`, the expected-sum branch (today's line 407 block):
   builds `rhsConstraints: array[any]` containing one
   `Constraint(expected.rhs, actual)` — rhs first, per the preserved
   asymmetry — and calls `tryUnify(rhsConstraints)`.
   Passed: `array[any]` holding one `Constraint`. **See F1: this call
   cannot be written as the file is ordered** — `unifyCore` (line 271)
   would forward-reference `tryUnify` (line 281), and the reverse order
   forward-references `unifyCore`; this is genuine mutual recursion,
   which Chi only supports via the `var`-rebinding pattern
   (precedent: `checks.chi:510-511` forward-declares `rtWalkExpr` as a
   `var` for exactly this reason).
4. `tryUnify` → `unifyCore(constraints, ufNew())`.
   Passed: `(array[any], fresh Map)`. Core returns `unit` (success).
5. `tryUnify` success path → `ufAllBindings(freshUf)`.
   Declared return of `ufAllBindings` is `array[any]`
   (`unification.chi:230`), so `tryUnify` must end with
   `ufAllBindings(uf) as array[Binding]` — an unchecked cast asserting
   the shape of tables built entirely inside `embedLua`
   (`unification.chi:233`: hand-rolled `{tag='var', ...}` variable plus
   `replacement`). See F4.
   Returned to the core: `array[Binding] | unit`, runtime value = Lua
   array of `{variable, replacement}` tables. Replacements were
   `ufResolve`d **against the fresh UF only** — session bindings are
   invisible to the resolution (today's behaviour, wart #1, preserved;
   noting it because the `Binding` type makes the value look more
   authoritative than it is: `replacement: Type` may still contain
   variables that are bound in the *session* UF).
6. Back in the sum branch: `if probe != unit { val bindings = probe as
   array[Binding]; ... }` — one narrowing cast (Chi sums need explicit
   `as` after the unit test; `probe is array[Binding]` is not usable —
   no runtime element-type check exists). After the cast the merge loop
   is clean Chi: `bindings.size()`, `bindings[si].variable: Type`,
   `bindings[si].replacement: Type`, `ufBind(uf, v, r)` — signature
   `ufBind(uf: any, variable: Type, t: Type)` fits with zero further
   adaptation. The four `luaExpr` unpacks of the old code
   (`unification.chi:421,426-427`) genuinely disappear. **This is the
   one place the new signatures pay off as advertised.**
   Silent-overwrite semantics of `ufBind` on already-bound session
   variables: preserved wart, unchanged.

Boundary summary: 2 casts (`as Message` in the facade, `as
array[Binding]` in the branch) + 1 internal cast in `tryUnify`. No
repacking. One impossible call edge (F1).

---

## Scenario S2 — failed UFCS receiver probe

Setup: `typer.chi:469` resolves `recv.foo(...)`; a candidate `foo` has
first parameter `string`, receiver is `int`.

1. `typer.chi:469` → `icListLocalFunctionsForType(fieldName,
   finalReceiverType)`. Values: `(string, any)` — receiver is an `any`
   holding a `Type` table. Unchanged.
2. `inference_context.chi:210` → `icTrialUnify(sym, receiverType)`,
   `(any, any)`. Unchanged.
3. `icTrialUnify` (line ~197 after rewiring) →
   `tryUnify([newConstraint(firstParam, receiverType, unit, [])])`.
   - `newConstraint(expected: any, actual: any, section: any,
     history: array[any])` absorbs `firstParam: Type`,
     `receiverType: any`, `unit`, `[]` with no casts.
   - The array literal infers `array[Constraint]`; parameter is
     `array[any]` — unifies (expected element `any` skips). No cast.
   - Requires `import chicc/unification { tryUnify, newConstraint }` —
     `inference_context.chi` currently imports **nothing** from
     `chicc/unification` (it uses `embedLua` + `require` at line 197).
     No import cycle results: `unification.chi` imports only
     `types`/`map`/`messages`/`source`. The legacy `require` idiom can
     die here; nothing forces keeping it.
4. `tryUnify` → `unifyCore(constraints, fresh uf)` → core hits the
   primitive/primitive mismatch arm → builds
   `typeMismatch("string", "int", unit)` (a full `Message` record with
   interpolated text, **eagerly**, for a probe whose only consumer
   wants a bool — F8) → returns it as `Message`.
5. `tryUnify` failure path: `Message` ⇒ returns `unit`. Polarity
   inversion happens here: core-`nil` → array, core-table → `nil`. See
   F2.
6. `icTrialUnify`: `val r = tryUnify(...)` then `r != unit` → `false`.
   Typecheck of `!= unit` on a declared sum: verified against
   `typer.chi:865-866` — `==`/`!=` emits the constraint
   `Constraint(lhsType, rhsType)`; with `lhs = array[Binding] | unit`,
   `rhs = unit` the expected-sum branch probes rhs (`unit` vs `unit`)
   and succeeds. So the bool-only consumption compiles natively — the
   decision doc's claim holds, though note there is **no existing
   precedent in chicc** of comparing a *declared* sum to `unit` (every
   current `!= unit` in the tree is on an `any`); this site will be the
   first, which is a thing for tests to pin, not a blocker.
7. Candidate silently rejected; the discarded `Message` (reason) is
   unrecoverable at this site — accepted in 00-decisions §2.

No unnecessary unpack/repack. Adaptation cost: one new import line.
The probe result type mentions `Binding`, an alias private to
`unification.chi` — harmless here because `r` is only compared to
`unit`, and aliases are transparent; if a consumer ever needed the
name, non-`pub` aliases are de-facto importable anyway (see F5).

---

## Scenario S3 — unification failure propagating to compiler.chi's pcall harness

Setup: top-level code constrains `int` against `string`; no sums
involved on the failing path.

1. `compiler.chi:643` `pcall(function() ... _unif.unifyWithUf(
   codeConstraints, uf) ... end)`.
2. `unifyWithUf` → `unifyCore(constraints, session uf)`.
3. Core processes the queue, binds whatever precedes the failure
   (those bindings **stay** in the session UF — declared contract,
   matches today's post-throw state), hits primitive mismatch, returns
   `typeMismatch("int", "string", cp): Message`.
   `cp` flows through `sectionToCodePoint(section: any): any` — its
   `any` return feeds `typeMismatch(..., cp: {line,column} | unit)`;
   an `any`-into-sum coercion the current code already does. Unchanged
   lie, unchanged blast radius.
4. Facade: `r != unit` → `throwMessage(r as Message)` →
   `error(msg)` with a **table** payload — Lua adds no
   position-prefix to non-string errors, so the object arrives
   verbatim.
5. `compiler.chi:644-652`: `pcall` yields `(false, Message-table)`;
   `type(__chicc_tc_err) == 'table' and __chicc_tc_err.code ~= nil` →
   true → pushed into `resultMessages` unmodified; `typerSetUf(nil)`
   at line 646 discards the half-mutated session UF. Byte-identical
   with today **iff** the core builds the same constructor call at the
   same program point — which holds as long as queue processing order
   is untouched (in scope, preserved).

Error ownership is clear on this path. The danger is not this scenario
itself but its *near miss*: between steps 2 and 4 there is now a
return-value relay where there used to be a non-droppable throw. If
the facade (or any future internal caller) invokes `unifyCore` in
statement position and forgets the `!= unit` check, the program
compiles, all success-path behaviour is identical, and failures become
silent acceptance — see F3. `tests/test_unification.chi:105/133/192/...`
(`pcall(unify, ...)` + `err.code` asserts) guard the `unify` →
`unifyWithUf` → core chain, so *that* facade omission would be caught;
nothing guards future direct core callers.

---

## Scenario S4 — return-type check probe failing, in a handler-free phase

Setup: `fn f(): int { return "x" }` reaches Phase 7.

1. `compiler.chi:690` → `returnTypeCheck(expressions, resultMessages)`
   — **no `pcall` anywhere above this frame** (the only harnesses in
   `compiler.chi` are at lines 430, 588, 643, 659; Phase 7 sits after
   all of them; `cli.chi`'s pcalls wrap chunk execution, not
   compilation).
2. `checks.chi:587+` `rtWalkExpr` "return" arm → builds
   `constraint = newConstraint(expRet, actualType, section, [])` where
   `expRet: any`, `actualType: any` hold `Type` tables — `any`-typed
   args flow into `any`-typed parameters, no casts; the current
   `luaExpr("{}") as any` + push dance (lines 620-621) collapses to
   `tryUnify([constraint])`. Native consumption: yes, comfortably —
   this site is *easier* in the new style than the old.
3. `tryUnify` → core → `Message` → `unit`; `unifyOk = r != unit` →
   `false`; checker synthesizes its **own**, less precise
   `typeMismatch` from tags (lines 625-646) and pushes it. The core's
   richer `Message` is discarded — today's behaviour, fine.
4. **The hostile case**: the core, while probing, raises a genuine Lua
   error rather than returning a `Message` — e.g. stack overflow from
   the unmemoised core→tryUnify→core recursion on a pathological
   recursive sum (architecture wart #2 explicitly preserves the
   recursion depth), or a nil-index on a malformed `Type` table.
   Today, `pcall` at `checks.chi:622` catches **anything** — overflow
   and bugs degrade to "types don't match", a diagnostic is pushed,
   compilation continues. After rewiring there is **no handler on this
   path at all**: the error unwinds through `tryUnify` (which has no
   `pcall` — its "Never throws" comment cannot be honoured for
   non-`Message` errors), through `returnTypeCheck`, through
   `compileInternal`, and kills the compiler process with a raw Lua
   traceback. See F7.

---

## Findings

### F1 — The Core → tryUnify edge is unwritable as stubbed (mutual recursion)

`unifyCore` (line 271) must call `tryUnify` (line 281) in its sum
branches; `tryUnify` must call `unifyCore`. Chi has no forward
declarations — whichever is defined first forward-references the other,
and the cycle is irreducible. The language's only escape is the
`var`-rebinding pattern (skill rule; living precedent at
`checks.chi:510-511`, and `parser.chi:58` shows even `pub var` function
slots exist). Every resolution contradicts something already signed
off: (a) `var tryUnify: (array[any]) -> array[Binding] | unit` changes
the stubbed `pub fn` into a mutable slot; (b) keeping both as `fn` and
having the sum branches self-recurse into `unifyCore(branchConstraints,
ufNew())` + inline `ufAllBindings` erases the architecture diagram's
"Core → Probing Facade" edge (01-architecture.md line 42) and
duplicates the probe logic the facade was supposed to own. The stubs
and the architecture cannot both be true; Phase 2 silently assumed a
call topology the language forbids for plain `fn`s.

### F2 — unit-means-success is indistinguishable from an accidental nil

At the `unifyCore` boundary, "success" and "a Chi-level `unit` that
snuck in" are the same Lua `nil`. There is no runtime or type-level
discrimination — a caller **cannot** tell them apart, by construction.
Concrete vectors inside the core body: (a) every failure arm of the old
code is a `throwMessage(...)` call in *statement* position (lines 320,
335, 342, 355, 394, 467, 470); the mechanical rewrite is
`return <Message>`, and **forgetting the `return`** leaves the Message
in discarded-expression position — the loop continues and the function
falls off its `while` into an implicit `unit`. Result: that mismatch
class is silently *accepted*, compiler-wide, and nothing but a test
that pins each error arm will notice. (b) The polarity inversion inside
`tryUnify` (core `nil` ⇒ return array; core table ⇒ return `nil`) also
typechecks if written **backwards** — both branches inhabit
`array[Binding] | unit` (returning `unit` on success and bindings on
failure is type-correct). The signature provides zero protection in
either direction; the stub comments (lines 264-270, 276-280) are the
only guardrail, and comments don't fail builds.

### F3 — `unifyCore`'s `Message | unit` is confusable with old `unifyWithUf`'s implicit unit, and discarding it is legal

Old `unifyWithUf(c, uf)` returns `unit` always — "returned at all"
means success, and the whole codebase calls it in statement position
(`typer.chi:872` does exactly this mid-typing). New `unifyCore(c, uf)`
has the same shape, same arguments, same `unit` in the success case —
but its `unit` means something only if the caller *checked*. Chi
permits discarding any expression value in statement position, so
`unifyCore(constraints, uf)` as a bare statement compiles cleanly and
swallows failures: the facade then returns normally, `ufAllBindings`
hands back a partial solution, `replaceTypes` patches the AST with it,
and `compiler.chi` reports zero errors for an ill-typed program. The
two names differ by one word and their call expressions are textually
interchangeable; nothing in the signatures prevents the substitution.
Existing thrown-error tests (`test_unification.chi`) cover only the
public `unify` path.

### F4 — `ufAllBindings` still says `array[any]`: the `Binding` chain starts with an unchecked cast over embedLua output

00-decisions §2 explicitly promised that naming `Binding` "lets
`unify`/`ufAllBindings` declare it". The stub did not do this:
`ufAllBindings: array[any]` (line 230) and `unify: array[any]`
(line 476) are unchanged, while the comment at lines 21-23 claims
`Binding` is "as returned by ufAllBindings". So `tryUnify` must launder
the type with `ufAllBindings(uf) as array[Binding]` — a cast asserting
the shape of values constructed entirely inside an `embedLua` string
(line 233: variables hand-rolled via `key:match('(.+):(%d+)')`,
`pairs()` order). The declared `array[Binding]` on `tryUnify` is
therefore exactly as trustworthy as that one Lua string — a type
assertion, not a checked fact. Additionally `Binding.replacement: Type`
over-promises: for probe results it is resolved only against the fresh
UF and may still contain session-bound variables (S1 step 5). Comment
and signatures are mutually inconsistent within one stub file.

### F5 — `Binding`'s declared visibility is fiction (both ways)

00-decisions §2 calls `Binding` "a new **public** alias"; the stub
declares it without `pub` — and the grammar cannot express `pub type`
at all (`parser.chi:1611-1616` dispatches on bare `TK_TYPE`;
`parseTypeAliasImpl:1262` starts at `TK_TYPE`, no `TK_PUB` branch). In
the other direction, non-`pub` aliases are de-facto importable
cross-package anyway (`tests/test_typer.chi:3` imports the non-`pub`
`Constraint` and uses it). Net: the declaration can neither honour the
decision doc's "public" nor actually hide anything. Consumers of the
four sites happen not to need the name (bool sites compare to `unit`;
sum branches are same-file), so this is a documentation/decision lie
rather than a functional break — but the decision record and the code
disagree about a `pub` that the language cannot even parse.

### F6 — Sum narrowing requires the `!= unit` + `as` two-step; `is` is unavailable

`probe is array[Binding]` cannot work (no runtime generic check), so
the only correct consumption pattern is `!= unit` then a trusting
`as array[Binding]`. This is the codebase idiom and is fine — but note
it makes the F2(b) polarity bug *invisible at the use site too*: a
backwards `tryUnify` returning `[]` on failure still passes
`!= unit` and merges zero bindings, turning "branch failed, try
fallback" into "branch succeeded vacuously" — the fallback branch is
then never queued. A vacuous-success probe is the single worst silent
failure this design admits, and no signature catches it.

### F7 — `tryUnify`'s "Never throws" is unkeepable, and the deleted pcalls were the only backstop for non-Message errors

The comment contract (line 277-279) can only be honoured for failures
the core *detects and returns*. Genuine Lua errors — stack overflow
from the preserved unmemoised probe recursion, nil-index on malformed
types, bugs — now propagate. Handler inventory after rewiring:
sites 1/2/3 (sum branches, `icTrialUnify`) ultimately sit under
`compiler.chi:643/659` `pcall`s, so a crash that today is *absorbed as
probe failure* (candidate rejected / fallback tried, compilation
proceeds) becomes a whole-group type-check abort with an `ERROR`
message — an observable behaviour change in pathological cases, which
contradicts 01-architecture wart #2's claim that "only the failure
transport differs": the transport *was* the overflow backstop.
Site 4 (`checks.chi:622`, Phase 7 via `compiler.chi:690`) has **no
handler at any level** — the same class of error today degrades to a
pushed diagnostic and after the change kills the chicc process with a
raw traceback. No facade, no harness, nothing owns this error.

### F8 — Eager Message construction on the hot probe path is baked into the signature

`unifyCore: Message | unit` forces the core to *build* the full
`Message` (string interpolation in `typeMismatch`, `sectionToCodePoint`)
before `tryUnify` throws it away — for every failed UFCS candidate of
every method call. Recorded and deferred in 00-decisions §3/Deferred;
listed here because issue #12's stated motivation is hot-path cost, and
the chosen internal signature retains the allocation half of that cost
while removing only the unwind half. Not a blocker; a known accepted
debt that the signature, as declared, cannot later shed without
changing `unifyCore`'s return type again.

---

## What fits cleanly (for balance, briefly)

- All four call sites consume the new signatures with at most one cast
  and no repacking; the sum-branch merge loop sheds four `luaExpr`
  unpacks (S1 step 6).
- `!= unit` on the declared sum typechecks via the typer's `==`/`!=`
  rule (S2 step 6) — first such use in the tree; needs a pinning test.
- `array[Constraint]` literals pass into `constraints: array[any]`
  without casts at both bool sites.
- Adding `import chicc/unification { tryUnify, newConstraint }` to
  `inference_context.chi` creates no import cycle.
- The thrown-`Message`-verbatim path to `compiler.chi:643/659` is
  preserved exactly (S3), and existing `err.code` tests guard it.

---

## Resolutions (main agent, post-review)

- **F1 — RESOLVED, architecture amended.** Sum branches probe by
  self-recursion: `ufNew()` + `unifyCore(branchConstraint, probeUf)` +
  merge `ufAllBindings(probeUf)` on success. No mutual recursion, no
  `var` slot, no type degradation. The Core → Probing Facade edge is
  gone from `01-architecture.md`; `tryUnify` is a pure consumer-facing
  facade. The probe choreography exists in three small copies (two sum
  branches + `tryUnify`) — accepted; a shared helper would reintroduce
  the forward-reference problem.
- **F2/F3/F6 — ACCEPTED HAZARDS, mitigated in Phases 4–5.** The type
  system cannot catch polarity inversions or discarded results; tests
  must. Phase 4 test contract therefore REQUIRES: (a) one test per
  failure arm of the core (each error code) asserted through BOTH
  facades — thrown via `unify`, `unit` via `tryUnify`; (b) polarity
  pinning — `tryUnify` success returns bindings (including the
  empty-array case), failure returns `unit`; (c) a sum-fallback test
  where the first-probed branch fails and the fallback succeeds
  (kills the vacuous-success bug F6); (d) a pinning test for
  `tryUnify(...) != unit` — first declared-sum-vs-unit comparison in
  the tree. Phase 5 self-review adds a grep check: `unifyCore` is
  called only by the two facades and the two sum branches, never in
  bare statement position.
- **F4 — RESOLVED.** `ufAllBindings` and `unify` now declare
  `array[Binding]`; `Binding`'s comment states that `replacement` is
  resolved only against the binding's own union-find. Compile gate
  re-run: green.
- **F5 — RESOLVED.** Decision doc no longer claims a `pub` the grammar
  cannot parse.
- **F7 — DECIDED by the user: no backstop.** Genuine Lua errors
  (compiler bugs) propagate instead of degrading to probe failure —
  the single deliberate behaviour change of this excavation, recorded
  as decision 4 in `00-decisions.md`. 01-architecture's "only the
  transport differs" claim is thereby scoped to Message-class failures.
  (Rejected alternative: a backstop `pcall` inside `tryUnify`
  preserving the masking.)
- **F8 — ACCEPTED DEBT, already deferred in 00-decisions.** Note:
  `unifyCore` is private, so shedding the eager-Message cost later is a
  file-local signature change, not an API break.

## Self-Review (Phase 3 gate)

- *Pass-through steps across traces:* `unify` = `ufNew` + core +
  `ufAllBindings` and `tryUnify` = the same with a different failure
  mapping — both are one-screen facades owning a distinct contract, not
  redundant layers. No step in S1–S4 fetches the same data twice; the
  only repeated work is the eager Message build (F8, recorded).
- *Reconsidered:* collapsing `tryUnify` into "call `unify` under one
  pcall" (rejected — F7 shows pcall semantics are precisely the thing
  under discussion; and it would keep error-objects on the hot path);
  making `unifyCore` public for future direct probes (rejected — F3
  shows bare-statement misuse is the main hazard; privacy is the cheapest
  guard we have).
- *Simplification applied:* none beyond F1's own simplification (the
  facade-routing through the core was itself the over-engineering;
  self-recursion is the simpler design and the language agreed).
