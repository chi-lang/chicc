# Excavation: tryUnify (issue #12)

Replace `pcall`/`error` control flow at the four trial-unification sites
with a value-returning unifier core.

| Artifact | Content |
|----------|---------|
| [00-decisions.md](00-decisions.md) | Phase 0 — strategy (value-returning core), result shape (`array[Binding] \| unit`), decision 4: no error backstop (the one deliberate behaviour change) |
| [01-architecture.md](01-architecture.md) | Phase 1 — modules (Core, Throwing Facade, Probing Facade), edge table, state ownership, inherited warts kept as contract |
| [03-signature-fit.md](03-signature-fit.md) | Phase 3 — adversarial review, findings F1–F8 + resolutions |
| tests | Phase 4 — `tests/test_unification.chi`, "tryUnify contract" section (commit e22f69d) |
| bodies | Phase 5 — `chicc/unification.chi` (unifyCore + facades), `chicc/inference_context.chi` (icTrialUnify), `chicc/checks.chi` (return check) |

## Perf datapoint (acceptance bonus)

Clean self-compile (`rm -rf .cache && ./run_chicc.sh compile.chi`,
LuaJIT, same machine, 3 runs each):

- before (throwing probes): 5.76 / 5.94 / 5.92 s
- after (value-returning core): 5.99 / 5.80 / 6.06 s

No measurable difference — failed-probe unwind cost does not dominate
this workload. The change stands on design grounds (no error-as-control-
flow, single algorithm), not on performance.

## Deferred / follow-up candidates

- Lazy `Message` construction in the core (F8) — only if a future
  profile shows failed probes dominating.
- Inherited warts (01-architecture): `ufAllBindings` string-parse merge
  + `pairs()` nondeterminism + `ufBind` silent overwrite; unmemoised
  probe recursion on pathological recursive sums.
