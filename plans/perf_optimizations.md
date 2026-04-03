# Performance Optimizations for Chi Self-Hosted Compiler

Port the algorithmic improvements from the Kotlin bootstrap compiler to `chicc/`.

**Goal:** Eliminate O(N²) and O(S×T) bottlenecks in the type inference pipeline.

## Status

- [x] Task 1: tryUnify() — non-exception method resolution probing (already done via pcall)
- [x] Task 2: Union-Find for variable bindings in unify() — replace O(N²) queue rebuild
- [x] Task 3: Single-pass mapType() — replace O(S×T) multi-pass substitution
- [x] Task 4: Incremental UnionFind threading through Typer — avoid redundant mid-typing solves

## Task 2: Union-Find in unify()

**File:** `chicc/unification.chi`

**Problem:** When a variable is solved, the entire remaining constraint queue is rebuilt
via `constraintWithReplacedVariable()` in a linear loop (lines ~154-177). With N variables
this is O(N²).

**Solution:** Introduce a union-find structure. Instead of eagerly substituting through the
queue, store bindings in the union-find and resolve each constraint lazily at dequeue time.

**Changes:**
- Add union-find functions (bind, find with path compression, resolve for deep type traversal)
- Rewrite the main `unify()` loop: resolve constraints through union-find instead of rebuilding queue
- Return solutions via `allBindings()` at the end

**Reference:** `compiler/src/main/kotlin/gh/marad/chi/core/types/UnionFind.kt` and
the rewritten `Unification.kt` in the Kotlin compiler.

## Task 3: Single-pass mapType()

**File:** `chicc/types.chi`

**Problem:** `mapType()` (lines ~454-466) iterates over the solution list and calls
`replaceVariable()` once per solution, doing a full type-tree traversal each time.
With S solutions and type tree of size T, this is O(S×T).

**Solution:** Build a lookup map from all solutions, then do a single traversal of the
type tree, replacing all variables in one pass.

**Changes:**
- Add a `bulkReplaceVariables(type, solutionMap)` function that traverses the type once
- Rewrite `mapType()` to build a map and call `bulkReplaceVariables`

**Reference:** `BulkVariableReplacer` in the Kotlin compiler's `VariableReplacer.kt`.

## Task 4: Incremental UnionFind threading through Typer

**Files:** `chicc/typer.chi`, `chicc/compiler.chi`

**Problem:** Three sites in the typer call `unify(constraints)` mid-typing on the
*entire* accumulated constraint list (FieldAccess, NameDeclaration, ForLoop). Each call
re-solves all previously accumulated constraints.

**Solution:** Thread a shared union-find through the typing process. Mid-typing solves
become incremental — only new constraints are processed, and results accumulate in the
shared union-find.

**Changes:**
- Add `unify()` overload that accepts a pre-existing union-find
- Pass union-find through `typeTerm` / `typeTerms` calls
- Mid-typing solve sites use incremental unify + `uf.resolve()` instead of full re-solve + `mapType()`
- `compiler.chi` creates shared union-find per compilation unit

**Reference:** Task 5 in the Kotlin compiler — `Typer.kt` and `Compiler.kt` changes.
