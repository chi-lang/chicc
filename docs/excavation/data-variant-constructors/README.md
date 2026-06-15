# data variant constructors (issue #14)

Excavation artifacts for making `data` variant constructors work end-to-end in
the self-hosted compiler (`chicc`). The issue repro now compiles and runs:

```chi
data Shape = Circle(r: int) | Rect(w: int, h: int)
fn area(s: Shape): int {
    if s is Circle { val c = s as Circle; c.r * c.r * 3 }
    else           { val r = s as Rect;   r.w * r.h }
}
println(area(Circle(2)))   // 12
println(area(Rect(3, 4)))  // 12
```

## Artifacts

- [`01-architecture.md`](01-architecture.md) — Phase 1 module diagram + edge
  table + state ownership, with the Phase 0 decisions, resolved open questions,
  the Phase 5 implementation-hazard checklist, and per-phase self-reviews.
- [`03-signature-fit.md`](03-signature-fit.md) — Phase 3 adversarial trace of 5
  scenarios through the signatures, the gaps found, and their disposition.
- Tests: [`tests/test_variants.chi`](../../../tests/test_variants.chi) (Phase 4,
  committed before bodies).

## Outcome

- **Implemented:** construction, `is`/`as` discrimination (nominal metatable
  tag), structural field access, single- and multi-constructor `data`,
  structurally-overlapping variants.
- **Rejected with a clear diagnostic (out of scope):** generic variants
  (`data Box[T]`) and recursive variants (`data List = Cons(.., tail: List)`).

## Deferred follow-ups

- Flow-narrowing after `is` (so `as` is unnecessary in a guarded branch) — issue #22.
- Recursive variant types — needs `recursive`-type wrapping like type aliases;
  currently rejected (follow-up issue pending).
- Exhaustiveness checking; checked `as` (runtime tag-mismatch error).

## Design decisions (Phase 0)

1. Scope: full repro end-to-end.
2. Runtime representation: per-variant metatable carrying the variant name
   (`chi_variant_meta`), cloning `record_meta_table`.
3. Type identity: hybrid — nominal discriminator (the record `name`), structural
   field access.
