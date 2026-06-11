# tryUnify (issue #12) — Phase 0: Decisions

## Goal

Remove `pcall`/`error` as control flow from the four trial-unification
sites. A trial asks "do these types unify?" and must get the answer as a
value, not as a caught error.

The four sites:

| # | Site | Uses the result as |
|---|------|---------------------|
| 1 | `chicc/unification.chi:390` — expected-sum branch (try rhs, fall back to lhs) | bindings on success |
| 2 | `chicc/unification.chi:419` — actual-sum branch (try lhs, fall back to rhs) | bindings on success |
| 3 | `chicc/inference_context.chi:197` — `icTrialUnify`, UFCS receiver-vs-first-param probe | bool only |
| 4 | `chicc/checks.chi:622` — return-type compatibility check | bool only |

## Decisions (user-confirmed)

1. **Single-algorithm, value-returning core.** The unifier core is
   rewritten to *return* failure instead of throwing it. `unify` and
   `unifyWithUf` remain public and keep their throwing contract as thin
   wrappers (their callers — typer, compiler error reporting, tests —
   depend on a thrown `Message`). `tryUnify` is the non-throwing facade.
   Behavioural identity is by construction: there is exactly one
   algorithm; only the failure-propagation mechanism changes.
   (Rejected: JVM-style `pcall` wrapper — trivially identical but keeps
   error-as-control-flow and per-failed-probe `Message`+unwind cost on
   the hot path, which is what #12 wants gone.)

2. **Result shape: `tryUnify(constraints): array[Binding] | unit`.**
   Success returns the bindings array (possibly empty — `[] != unit`),
   failure returns `unit`. Bool-only sites test `!= unit`; sum-branch
   sites merge the returned bindings.

   `Binding` is a new alias for what `ufAllBindings` already produces:
   `type Binding = { variable: Type, replacement: Type }`. (Plain
   `type`, not `pub type` — the grammar has no `pub type`, and plain
   aliases are importable cross-package anyway; see Phase 3, F5.)
   (Review feedback: the element type need not be `any` — agreed;
   naming the record also lets `unify`/`ufAllBindings` declare it,
   shrinking gratuitous `any` per the f96b134 direction.)

   **Why `unit` on failure and not the error content** (review
   question): none of the four sites reads the reason — sites 3/4 want
   a bool, sites 1/2 react to failure by queueing the fallback branch.
   Returning `Message` would force every caller to discriminate
   array-vs-record (novel in this codebase, where `T | unit` plus
   `!= unit` is the pervasive idiom — and #7 just made `unit` checks
   strict, so the idiom is sound). The information is NOT lost: the
   core's internal result is `Message | unit`, so if a future consumer
   wants the failure reason (e.g. richer UFCS diagnostics), promoting
   it into a `tryUnifyVerbose`-style signature is a local, additive
   change. Decision: keep `unit`, do not pay for an unconsumed payload.

3. **Failure detail is not dropped in the core.** The core reports the
   failed constraint as the same `Message` the old code threw (built
   eagerly, exactly as today). The throwing wrappers re-throw it
   verbatim, so error texts, codes and code points are unchanged.
   `tryUnify` discards it. (Lazy message construction is a possible
   later optimisation — out of scope; identity first.)

## Out of scope

- Changing sum-branch backtracking semantics (try-rhs-then-lhs order,
  partial-solution merging) — preserved exactly.
- Benchmark infrastructure. A simple before/after clean-compile timing
  is the acceptance "bonus datapoint", nothing more.
- The remaining legitimate `pcall`s in the tree (REPL run, decodeType
  guards, scope try/finally, parse-error catch) — explicitly out, per
  the issue.

## Deferred (recorded, no design impact now)

- Lazy `Message` construction in the core if the perf datapoint shows
  failed probes dominating.

## Self-Review (Phase 0 gate)

- *Complexity not asked for?* No new module, no new error model — the
  language's existing `T | unit` idiom. The only added concept is the
  internal core/facade split, which the issue itself mandates.
- *Deferred-but-load-bearing?* Checked: the `Message | unit` internal
  result convention could read as "unit means error" — naming must make
  success-as-unit unambiguous (Phase 2 concern, flagged for it).
  Callers of thrown errors (`compiler.chi` pcall handlers, tests
  asserting `err.code`) keep working because wrappers re-throw the same
  object — verified against `compiler.chi:643/659` and
  `tests/test_unification.chi`.
- *Alternatives considered:* `{ok, solutions}` record result (rejected:
  non-idiomatic, two fields where the sum type says it in one);
  making `unifyWithUf` itself value-returning publicly (rejected:
  breaks 4+ existing callers for no gain).

## Decision 4 (user-confirmed, Phase 3 / F7): no error backstop

The old `pcall`s incidentally caught **genuine Lua errors** (compiler
bugs: stack overflow on pathological recursive sums, nil-index on
malformed types) and degraded them to "probe failed". This masking is
NOT preserved: `tryUnify` returns `unit` only for unification failures
the core detects; any other error propagates. Consequences, accepted:

- typer-side sites (sum branches, UFCS probes) — an internal error now
  aborts the type-check group via compiler.chi's harness with an ERROR
  message instead of silently rejecting a candidate/branch;
- `checks.chi` (Phase 7) has no handler above it — an internal error
  there crashes the compiler with a raw traceback. Visible-bug-over-
  masked-bug is the point (same philosophy as #7).

This is the single deliberate behaviour change in this excavation;
everything else is preserved 1:1.
