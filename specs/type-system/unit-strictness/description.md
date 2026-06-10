---
id: a703e858-443b-45ba-9656-99c86f0f2d3c
title: Unit strictness in unification
type: product
version: 1
status: draft
created_at: "2026-06-10T11:30:00+02:00"
updated_at: "2026-06-10T11:30:00+02:00"
---
# Unit Strictness in Unification

## Overview

`unit` represents the absence of a value. It is **not** a silent inhabitant
of other types: a value may be absent only where its type says so, by
including `unit` as a sum variant (`T | unit`, aliased as `Option[T]` in
`std/lang.option`).

This is the ML/Option model, not the Java null model. There is no implicit
nullability anywhere in the type system.

## Behavior

During unification, `unit` is an ordinary primitive type:

- `unit` vs `unit` — unifies.
- `unit` vs a sum type — unifies **only** when one of the sum's variants
  unifies with `unit` (resolved through normal sum branching). So
  `int | unit` accepts `unit`; `int | string` does not.
- `unit` vs a record, array, function, or other primitive — `TYPE_MISMATCH`,
  in both directions.
- A type variable unifies with `unit` like with any other type.

Consequences users see:

```chi
var o: int | unit = unit   // OK — the type admits absence
val x: int | string = unit // TYPE_MISMATCH
val r = { x: 1 }
r == unit                  // TYPE_MISMATCH — r's type never admits unit,
                           // so the comparison is statically meaningless
```

Equality (`==`, `!=`) unifies the types of both operands, so comparing a
value against `unit` requires the value's type to admit `unit`. To test
for absence, type the value as `T | unit`.

## Why

A relaxation existed historically (self-hosted compiler, PR #2): the
unifier silently accepted `unit` against any record, recursive type, or
sum, justified as "matching the JVM bootstrap's nullable semantics". The
justification was a misdiagnosis — the JVM bootstrap's unifier
(`Unification.kt`) has no such rule and rejects these pairs. The
relaxation also made `Option[T]` meaningless (absence was ambient
everywhere) and let genuinely ill-typed programs (`int | string := unit`)
defer their failure to a runtime `nil` in generated Lua, far from the
cause.

The relaxation was removed in issue #7. Nothing in the compiler or its
test suite relied on it; only the tests asserting the relaxation itself
had to change.
