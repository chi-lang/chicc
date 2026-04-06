# Option 2 Implementation Plan: Defer Module-Level embedLua

## Overview

Modify the compiler emitter to defer module-level `embedLua()` calls until after all module symbols are registered. This allows embedLua code to safely reference `__P_` tables that haven't been fully initialized yet.

## Changes Required

### 1. Modify `EmitterState` struct (emitter.chi)
Add a field to collect deferred embedLua code:

```chi
type EmitterState = {
    sb: StringBuilder,
    inFunction: bool,
    functionDepth: int,
    nextTmpId: int,
    nextLoopId: int,
    currentLoopId: int,
    program: Program,
    deferredEmbedLua: array[string]  // NEW
}
```

### 2. Update `newState()` function
Initialize the deferred embedLua array:

```chi
pub fn newState(prog: Program): EmitterState {
    { sb: newStringBuilder(), inFunction: false, functionDepth: 0, nextTmpId: 0, nextLoopId: 0, currentLoopId: 0, program: prog, deferredEmbedLua: [] }  // NEW FIELD
}
```

### 3. Modify `emitFnCall()` function
When embedLua is detected, defer it if at module level (functionDepth == 0):

At line 297 (where `cName == "embedLua"`), replace:
```chi
if cName == "embedLua" {
    val codeParam = expr.callParams[1] as Expr
    val luaCode = codeParam.atomValue
    val cleanCode: string = luaCode.replace("\n", ";")
    emit(st, "$cleanCode;")  // OLD: emit immediately
    return "nil"
}
```

With:
```chi
if cName == "embedLua" {
    val codeParam = expr.callParams[1] as Expr
    val luaCode = codeParam.atomValue
    val cleanCode: string = luaCode.replace("\n", ";")
    
    // Defer module-level embedLua until after all symbols registered
    if st.functionDepth == 0 {
        st.deferredEmbedLua.push(cleanCode)
    } else {
        // Inside function - emit immediately
        emit(st, "$cleanCode;")
    }
    return "nil"
}
```

### 4. Modify `emitProgram()` function
After emitting all expressions, emit the deferred embedLua code.

After line 953 (after the while loop that processes `progExprs`), add:

```chi
    // Emit deferred module-level embedLua code
    // (after all symbols are registered in __S_)
    val deferredCount = st.deferredEmbedLua.size()
    var di = 1
    while di <= deferredCount {
        emit(st, st.deferredEmbedLua[di])
        di = di + 1
    }
```

## Why This Works

1. **Module initialization order:**
   - `__P_`, `__S_`, `__T__` created (lines 914-917)
   - `emitPackageInfo()` registers all symbols in `__S_` (line 919)
   - `collectRequires()` emits imports (line 936)
   - Normal expressions emitted, but module-level `embedLua` deferred
   - **[NEW] Deferred `embedLua` code emitted** — at this point all modules have symbols registered

2. **Safety:**
   - embedLua inside functions still runs immediately (they have functionDepth > 0)
   - Only module-level embedLua is deferred
   - Module-level embedLua can now safely access `__P_` from other modules

3. **Compatibility:**
   - No changes to Chi language syntax
   - No changes to test files
   - No changes to runtime behavior
   - Just changes timing of when module-level embedLua runs

## Testing Plan

1. **Compile:** `make clean && make`
   - Should build successfully

2. **Test:** `make test-lexer`
   - Should now pass (no more write(nil) error)

3. **Verify:** `make verify`
   - Fixed-point verification (compile 3-4 times from scratch)
   - Should succeed and be stable

4. **All tests:** `make test`
   - Run all test files to ensure no regressions

## Files to Modify

1. `/Users/marcin.radoszewski/dev/chi/chicc/chicc/emitter.chi`
   - Lines 8-16: Add `deferredEmbedLua` field to `EmitterState`
   - Lines 18-20: Update `newState()` to initialize it
   - Lines 297-302: Defer module-level embedLua in `emitFnCall()`
   - After line 953: Emit deferred embedLua in `emitProgram()`

## Rollback Plan

If something breaks:
- The changes are isolated to emitter.chi
- Simply revert the 4 changes above
- No other files are affected

## Effort Estimate

- Implementation: 30 mins (4 small, isolated changes)
- Compilation & testing: 30 mins (includes fixed-point verification)
- Debug if needed: 1-2 hours
- **Total: 1-3 hours**

Much smaller and lower-risk than initially thought!
