---
name: compileModules __P__ Initialization Bug
description: Root cause analysis and fix plan for test infrastructure failure
type: project
---

# compileModules __P__ Initialization Bug — Analysis & Fix Plan

## Problem Statement

Running `make test-lexer` fails with:
```
Runtime error: [string "function m1() local __P_ = package.loaded['st..."]:1: 
bad argument #1 to 'write' (string expected, got nil)
```

This occurs when `compileModules()` attempts to load all chicc modules together. The error happens during module loading, before tests even execute.

## Root Cause Analysis

### What is __P__?

In the compiled Lua output, each module creates a package export table:
```lua
local __P_ = package.loaded['chicc/messages'] or {_package={},_types={}};
package.loaded['chicc/messages'] = __P_;
local __S_ = __P_._package;
local __T_ = __P_._types;
```

`__P_` is the package export table for the current module. `__S_` (symbols) points to it, and `__T_` points to the types table.

### The Problematic embedLua

In `chicc/messages.chi` line 9, there's an embedLua that executes at module initialization:

```chi
embedLua("local _prev_mt = getmetatable(_G); local _prev_index = _prev_mt and _prev_mt.__index or nil; 
setmetatable(_G, { __index = function(t, k) 
  local v = __P_[k];  // <-- PROBLEM: __P_ might not be initialized yet
  if v ~= nil then return v end; 
  if type(_prev_index) == 'table' then return _prev_index[k] 
  elseif type(_prev_index) == 'function' then return _prev_index(t, k) end 
end })")
```

This embedLua:
1. Runs **during module initialization** (when the loader() is called)
2. Sets a metatable on `_G` that references `__P_`
3. **Expects `__P_` to already be initialized**

### Timing Issue

In compiled Chi code for a module, the order is:
1. Module loads: `local __P_ = package.loaded['chicc/messages'] or {...}`
2. Other module-level code (including embedLua) executes immediately
3. Functions are defined
4. Exported symbols are registered in `__S_`

If __P__ is `nil` or the metatable references it before __S__ is set up, embedLua code that tries to access `__P_[k]` will fail when the metatable's `__index` is triggered.

### Why It Works in run_chicc.sh But Fails in Tests

**run_chicc.sh environment:**
- Sets up global metatable with dynamic package lookup across chicc/* modules
- Pre-initializes a fallback `__index` that provides context
- Each module loads in order with the global metatable already active

**compileModules environment:**
- Loads and executes each module's Lua in isolation
- Each loader() call runs the compiled module code
- If a module's embedLua triggers before __P__ is fully set up, it fails
- The __P__ metatable setup interferes with subsequent module loads

## Technical Details

### The "write(nil)" Error

The error `bad argument #1 to 'write' (string expected, got nil)` likely comes from:
1. One of the embedLua metatable functions references `__P_[k]`
2. When `__P_` is nil or missing a key, it returns nil
3. Some downstream code receives nil instead of a string
4. That nil is passed to an `io.write()` or similar function somewhere in the Lua runtime

### Affected Modules

All modules with module-level embedLua that reference `__P_`:
- `chicc/messages.chi` (line 9) — metatable setup
- `chicc/inference_context.chi` (line 306) — accesses `__P_.icNs`
- `chicc/emitter.chi` (line 198) — accesses `__P_.luaName`, `__P_.emit`, `__P_.emitExpr`
- `chicc/emitter.chi` (line 865) — accesses `__P_.localPackagePath`, `__P_.emit`
- `chicc/unification.chi` (line 227) — accesses `__P_.ufResolve`
- `chicc/unification.chi` (line 387) — accesses `__P_.unify`
- `chicc/compiler.chi` (line 568) — accesses `__P_.replaceTypes`
- `chicc/compiler.chi` (line 584) — accesses `__P_.replaceTypes`
- `chicc/type_writer.chi` (line 381) — accesses `__P_.decodeTable`

All these attempt to reference symbols from the current or other packages via `__P_` at module load time.

## Fix Strategy

### Option 1: Lazy Metatable Setup (Recommended)
**Approach:** Defer the metatable setup in messages.chi until it's actually needed.

```chi
// Instead of setting metatable at module load time,
// set it on-demand when first referenced

embedLua("""
local _mt_set = false
local function _ensure_mt() 
  if _mt_set then return end
  _mt_set = true
  local _prev_mt = getmetatable(_G)
  local _prev_index = _prev_mt and _prev_mt.__index or nil
  setmetatable(_G, { __index = function(t, k) 
    if __P_ then 
      local v = __P_[k]
      if v ~= nil then return v end
    end
    if type(_prev_index) == 'table' then return _prev_index[k]
    elseif type(_prev_index) == 'function' then return _prev_index(t, k)
    end
  end })
end
_ensure_mt()  -- Call once at module init
""")
```

**Pros:**
- Minimal code change
- Fixes the timing issue
- Still provides the expected behavior

**Cons:**
- Still creates metatable overhead
- Doesn't address the root architectural issue

### Option 2: Initialize __P__ Earlier
**Approach:** Ensure `__P__` is fully initialized before any embedLua code runs.

**Where:** In the emitter (or typer), when generating module initialization code:
1. Initialize __P__ first
2. Initialize __S__ and __T__
3. Then run any module-level code

**Pros:**
- More correct semantically
- Prevents similar issues in future modules
- Better separation of concerns

**Cons:**
- Requires changes to the compiler's emitter
- Bigger architectural change
- Needs careful sequencing

### Option 3: Remove Package Lookup Metatable
**Approach:** Don't use `__P__` metatable; instead require explicit imports.

```chi
// Remove the embedLua metatable setup entirely
// Rely on normal Lua package.loaded mechanism

// To access cross-module symbols:
// import chicc/inference_context { icNs, icPkg, ... }
```

**Pros:**
- Cleanest solution
- Explicit dependencies
- No initialization order issues

**Cons:**
- Requires large refactor of chicc modules
- Changes FFI usage patterns significantly
- High effort

### Option 4: Fix compileModules Module Loading
**Approach:** Modify `__compile_modules` in std/lang.chi to provide better initialization context.

```lua
-- In __compile_modules, before calling loader():
local __P_ = {_package={}, _types={}}
package.loaded[pkg] = __P__
local loader = load(luaCode)
if loader then loader() end
```

**Pros:**
- Fixes it at the source
- Helps all modules, not just messages.chi
- Isolated fix in one place

**Cons:**
- Must ensure __P__ structure matches what modules expect
- Need to verify it works with all module types

## Recommended Implementation Path

**Phase 1: Quick Fix (Option 4)**
1. Modify `__compile_modules` in `std/lang.chi` to pre-initialize `__P__` for each package
2. Test with `make test-lexer`
3. Verify fixed-point compilation still works

**Phase 2: Root Cause Fix (Option 2)**
1. Modify compiler emitter to ensure `__P__` initialization happens first in generated code
2. Remove reliance on metatable setup in module-level code
3. Test all modules

**Phase 3: Long-term (Option 3)**
1. Gradually remove `__P__` metatable pattern
2. Make cross-module symbols explicit via imports
3. Reduce FFI usage overall

## Files to Modify

### Short-term
- `/Users/marcin.radoszewski/dev/chi/stdlib/std/lang.chi` — Fix __compile_modules

### Medium-term
- `chicc/emitter.chi` — Fix module initialization code generation
- Various chicc/*.chi files — Remove module-level embedLua metatable setup

### Long-term
- Overall FFI reduction (separate effort tracked in language_gaps.md)

## Testing Strategy

1. **Unit test:** Create standalone test that uses compileModules on chicc modules
2. **Integration test:** Run `make test-lexer` and verify tests pass
3. **Regression test:** Ensure `make verify` (fixed-point) still works
4. **All modules:** Test with multiple test files (lexer, parser, etc.)

## Success Criteria

- [ ] `make test-lexer` passes all tests
- [ ] `make test` passes for all test files
- [ ] `make verify` confirms fixed-point compilation
- [ ] No regressions in compiler functionality
- [ ] No changes needed to chicc source (ideally)

## Current Status

- **Issue discovered:** 2026-04-06 (make test-lexer branch)
- **Root cause identified:** __P__ initialization timing in compileModules
- **Option 4 attempted:** Pre-initialize __P__ in __compile_modules before loader()
- **Option 4 result:** UNSUCCESSFUL - error persists

### Why Option 4 Failed

Testing showed the error occurs even when:
1. __P__ is pre-initialized before loader() 
2. Module-level embedLua in messages.chi is disabled
3. run_chicc.sh is used instead of bootstrap compiler

This indicates the problem is NOT the initial __P__ table creation, but rather:
- One of the OTHER modules with module-level embedLua (inference_context, emitter, unification, compiler, type_writer) is trying to access cross-module __P_ references
- These references expect __P_ tables to be fully populated (with symbols) BEFORE the embedLua code runs
- Serial module loading + serial embedLua execution violates this assumption
- Multiple modules have circular or interdependent embedLua code that references symbols from OTHER modules that haven't been initialized yet

### Architectural Issue

The core problem: **compileModules is incompatible with the current design of embedLua usage in chicc modules**.

- `__compile_modules` loads modules serially: m1(), m2(), m3(), ...
- Each module's embedLua executes immediately when its loader() runs
- But embedLua code in later modules may reference symbols in __P_ of EARLIER modules that haven't been fully initialized yet
- The test for "is __P_ initialized" needs to check not just that __P_ exists, but that __P_._package is fully populated with all exported symbols

### Real Solution Required: Option 2

Need to modify the **compiler emitter** to delay embedLua execution until after all module symbol exports are registered:

```lua
-- Instead of: embedLua code runs at module load time
-- Do this: defer embedLua until end of all modules
function m1() ... __S_.symbol = ... end; m1()
-- Register all exports first, then:
executeAllPendingEmbedLua()
```

This requires changes to `chicc/emitter.chi` to generate module initialization code that:
1. Loads modules sequentially
2. Registers ALL __S_ exports for all modules
3. THEN executes any module-level embedLua that depends on cross-module references

- **Status:** Awaiting Option 2 implementation (requires compiler changes)

---

## References

- **chi/stdlib:** `/Users/marcin.radoszewski/dev/chi/stdlib/std/lang.chi` (lines 64-68)
- **chicc/messages.chi:** `/Users/marcin.radoszewski/dev/chi/chicc/chicc/messages.chi` (line 9)
- **run_tests.sh:** `/Users/marcin.radoszewski/dev/chi/chicc/run_tests.sh` (uses compileModules)
- **Error tracking:** Make test output shows `Runtime error: [string "function m1() ...`
