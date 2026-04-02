# Compilation Speed Optimization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce chicc self-compilation time from ~30 minutes to under 1 minute by eliminating type metadata bloat in generated Lua code.

**Architecture:** Three independent, sequential changes: (1) profiling instrumentation in `compiler.compile()`, (2) per-package alias caching in `__chicc_mkEnv`, (3) nominal type references (`typeref`) in `type_writer.writeLuaTypeImpl()` to replace full structural expansions. Each change is independently testable.

**Tech Stack:** Chi language (compiles to Lua/LuaJIT). Tests via `run_tests.sh` (JVM bootstrap compiler) and `test_golden.sh` (self-hosting compiler). Chi language skill required for all `.chi` edits.

---

### Task 1: Per-Phase Profiling Instrumentation

**Files:**
- Modify: `chicc/compiler.chi:374-595` (the `compile()` function)
- Modify: `chicc/compiler.chi:601-610` (the `compileToLua()` function — add emit timing)
- Test: `tests/test_compiler.chi` (add profiling test)

This task adds `os.clock()` timing around each compilation phase, gated by the `CHI_PROFILE` environment variable so there is zero overhead when disabled.

- [ ] **Step 1: Add profiling state initialization at the top of `compile()`**

In `chicc/compiler.chi`, at the beginning of `compile()` (line 374), insert profiling setup after the function signature, before PHASE 1:

```chi
pub fn compile(source: string, ns: any): CompilationResult {
    // Profiling setup
    embedLua("local __prof_enabled = os.getenv('CHI_PROFILE') ~= nil")
    embedLua("local __prof_t0 = __prof_enabled and os.clock() or 0")
    embedLua("local __prof_parse, __prof_validate, __prof_tables, __prof_names, __prof_convert, __prof_usage, __prof_types, __prof_checks, __prof_emit = 0,0,0,0,0,0,0,0,0")

    // PHASE 1: PARSE
```

- [ ] **Step 2: Add timing markers after each phase**

After PHASE 1 (parse), insert timing capture — right before the `// Extract package definition` comment (line 389):

```chi
    embedLua("if __prof_enabled then __prof_parse = os.clock() - __prof_t0 end")
```

After PHASE 2 (validate imports), right before `// PHASE 3: BUILD COMPILE TABLES` (line 453):

```chi
    embedLua("if __prof_enabled then __prof_validate = os.clock() - __prof_t0 - __prof_parse end")
```

After PHASE 3 (build tables), right before `// PHASE 4: CHECK NAMES` (line 477):

```chi
    embedLua("if __prof_enabled then __prof_tables = os.clock() - __prof_t0 - __prof_parse - __prof_validate end")
```

After PHASE 4 (check names), right before the early return check at line 481:

```chi
    embedLua("if __prof_enabled then __prof_names = os.clock() - __prof_t0 - __prof_parse - __prof_validate - __prof_tables end")
```

After PHASE 5 (convert AST), right before `// PHASE 5.5: MARK USAGE` (line 507):

```chi
    embedLua("if __prof_enabled then __prof_convert = os.clock() - __prof_t0 - __prof_parse - __prof_validate - __prof_tables - __prof_names end")
```

After PHASE 5.5 (mark usage), right before `// PHASE 6: TYPE INFERENCE` (line 510):

```chi
    embedLua("if __prof_enabled then __prof_usage = os.clock() - __prof_t0 - __prof_parse - __prof_validate - __prof_tables - __prof_names - __prof_convert end")
```

After PHASE 6 (type inference), right before the early return check at line 572:

```chi
    embedLua("if __prof_enabled then __prof_types = os.clock() - __prof_t0 - __prof_parse - __prof_validate - __prof_tables - __prof_names - __prof_convert - __prof_usage end")
```

After PHASE 7 (semantic checks), right before `// PHASE 8: BUILD AND RETURN RESULT` (line 588):

```chi
    embedLua("if __prof_enabled then __prof_checks = os.clock() - __prof_t0 - __prof_parse - __prof_validate - __prof_tables - __prof_names - __prof_convert - __prof_usage - __prof_types end")
```

**Simplification:** The cumulative subtraction pattern above is awkward. Instead, use a simpler approach — capture a timestamp after each phase and compute deltas at the end:

Replace the entire profiling approach with timestamp captures:

```chi
pub fn compile(source: string, ns: any): CompilationResult {
    // Profiling setup
    embedLua("local __prof = os.getenv('CHI_PROFILE') ~= nil")
    embedLua("local __ts = {}; if __prof then __ts[0] = os.clock() end")

    // PHASE 1: PARSE
    ...existing parse code...

    embedLua("if __prof then __ts[1] = os.clock() end")

    // Extract package definition
    ...existing code...

    // PHASE 2: VALIDATE PACKAGE AND IMPORTS
    ...existing validate code...

    embedLua("if __prof then __ts[2] = os.clock() end")

    // PHASE 3: BUILD COMPILE TABLES
    ...existing tables code...

    embedLua("if __prof then __ts[3] = os.clock() end")

    // PHASE 4: CHECK NAMES
    ...existing names code...

    embedLua("if __prof then __ts[4] = os.clock() end")

    // (early return if errors — print partial profile before returning)
    ...existing early return...

    // PHASE 5: CONVERT parse AST -> expression AST
    ...existing convert code...

    embedLua("if __prof then __ts[5] = os.clock() end")

    // PHASE 5.5: MARK USAGE
    markUsed(expressions)

    embedLua("if __prof then __ts[6] = os.clock() end")

    // PHASE 6: TYPE INFERENCE
    ...existing type inference code...

    embedLua("if __prof then __ts[7] = os.clock() end")

    // (early return if errors — print partial profile before returning)
    ...existing early return...

    // PHASE 7: SEMANTIC CHECKS
    ...existing checks code...

    embedLua("if __prof then __ts[8] = os.clock() end")
```

- [ ] **Step 3: Add profile reporting to the return paths**

There are three return paths in `compile()`:
1. Early return after name check errors (line 489)
2. Early return after type inference errors (line 579)
3. Normal return (line 594)

Before each return, insert profile output. Create a Lua helper at the top of the file (after the existing embedLua helpers, around line 73):

```chi
embedLua("__chicc_printProfile = function(ts, pkgName) if not ts[0] then return end; local function ms(a,b) return string.format('%.0f', (b-a)*1000) end; local last = 0; for i=1,8 do if ts[i] then last = i end end; local parts = {'parse','validate','tables','names','convert','usage','types','checks'}; local out = '[profile] ' .. (pkgName or '?') .. ':'; for i=1,last do out = out .. ' ' .. parts[i] .. '=' .. ms(ts[i-1],ts[i]) .. 'ms' end; out = out .. ' total=' .. ms(ts[0],ts[last]) .. 'ms'; io.stderr:write(out .. '\\n') end")
```

Then before the early return at line 489 (after name check errors):

```chi
        embedLua("__chicc_printProfile(__ts, packageName)")
        return newCompilationResult(resultMessages, program)
```

Before the early return at line 579 (after type inference errors):

```chi
        embedLua("__chicc_printProfile(__ts, packageName)")
        return newCompilationResult(resultMessages, program)
```

Before the normal return at line 594:

```chi
    embedLua("__chicc_printProfile(__ts, packageName)")
    newCompilationResult(resultMessages, program)
```

- [ ] **Step 4: Add emit timing to `compileToLua()`**

In `compileToLua()` (line 601), wrap the emit call with timing:

```chi
pub fn compileToLua(source: string, ns: any): any {
    val result: any = compile(source, ns)
    val hasErr = hasErrors(result)
    if hasErr {
        luaExpr("{ messages = result.messages, luaCode = nil }") as any
    } else {
        embedLua("local __emit_t0 = os.getenv('CHI_PROFILE') and os.clock()")
        val luaCode = emitProgram(result.program, true)
        embedLua("if __emit_t0 then io.stderr:write('[profile] ' .. (result.program.packageDef.packageName or '?') .. ': emit=' .. string.format('%.0f', (os.clock()-__emit_t0)*1000) .. 'ms\\n') end")
        luaExpr("{ messages = result.messages, luaCode = luaCode }") as any
    }
}
```

- [ ] **Step 5: Run unit tests to verify profiling doesn't break anything**

Run: `./run_tests.sh tests/test_compiler.chi`
Expected: All tests pass (profiling is disabled by default since `CHI_PROFILE` is not set).

- [ ] **Step 6: Test profiling output manually**

Run: `CHI_PROFILE=1 luajit run_chicc.sh compile test.chi -o /tmp/test_out.lua 2>/tmp/profile.txt && cat /tmp/profile.txt`

Expected: One line of output like:
```
[profile] default: parse=Xms validate=Xms tables=Xms names=Xms convert=Xms usage=Xms types=Xms checks=Xms total=Xms
```

- [ ] **Step 7: Commit**

```bash
git add chicc/compiler.chi
git commit -m "feat: add per-phase profiling to compiler, gated by CHI_PROFILE env var"
```

---

### Task 2: Cache `getTypeAlias` Lookups

**Files:**
- Modify: `chicc/compiler.chi:38` (the `__chicc_mkEnv` embedLua string)
- Test: `tests/test_compiler.chi` (existing tests cover this implicitly via `compile()`)

The `getSymbol` function caches all symbols per-package on first access. `getTypeAlias` has no caching — it reads `package.loaded[qualifier]._types[name]` and calls `_tw.decodeType(spec)` on every invocation. This change adds a parallel `aliasCache` that decodes all type aliases for a package on first access, identical to the symbol cache pattern.

- [ ] **Step 1: Add alias cache to `__chicc_mkEnv`**

In `chicc/compiler.chi`, line 38, within the `__chicc_mkEnv` embedLua string, find:

```
local env = {}; local cache = {};
```

Replace with:

```
local env = {}; local cache = {}; local aliasCache = {};
```

- [ ] **Step 2: Rewrite `getTypeAlias` to use the cache**

In the same embedLua string (line 38), find the `getTypeAlias` function:

```lua
function env.getTypeAlias(mod, pkg, name) local qualifier = mod .. '/' .. pkg; local loaded = package.loaded[qualifier]; if loaded == nil or loaded._types == nil then return nil end; local spec = loaded._types[name]; if spec == nil or type(spec) ~= 'string' then return nil end; local ok, decoded = pcall(function() return _tw.decodeType(spec) end); if not ok then return nil end; return { typeId = { moduleName = mod, packageName = pkg, name = name }, aliasType = decoded } end;
```

Replace with:

```lua
function env.getTypeAlias(mod, pkg, name) local qualifier = mod .. '/' .. pkg; local pkgAliases = aliasCache[qualifier]; if pkgAliases == nil then local loaded = package.loaded[qualifier]; if loaded == nil or loaded._types == nil then return nil end; pkgAliases = {}; for aliasName, spec in pairs(loaded._types) do if type(spec) == 'string' then local ok, decoded = pcall(function() return _tw.decodeType(spec) end); if ok then pkgAliases[aliasName] = { typeId = { moduleName = mod, packageName = pkg, name = aliasName }, aliasType = decoded } end end end; aliasCache[qualifier] = pkgAliases end; return pkgAliases[name] end;
```

This mirrors `getSymbol` exactly: on first access for any name from a package, decode ALL type aliases for that package and cache the whole set. Subsequent lookups are instant table reads.

- [ ] **Step 3: Run unit tests**

Run: `./run_tests.sh tests/test_compiler.chi`
Expected: All tests pass. The compile tests exercise `getTypeAlias` indirectly via the import validation path.

- [ ] **Step 4: Run the full unit test suite**

Run: `./run_tests.sh`
Expected: All test files pass.

- [ ] **Step 5: Commit**

```bash
git add chicc/compiler.chi
git commit -m "perf: cache getTypeAlias lookups per-package, matching getSymbol pattern"
```

---

### Task 3: Add `typeref` Encoding to `writeLuaTypeImpl`

**Files:**
- Modify: `chicc/type_writer.chi:92-182` (`writeLuaTypeImpl` function)
- Modify: `chicc/type_writer.chi:185-189` (`encodeType` function — add context parameter)
- Test: `tests/test_type_writer.chi` (add typeref encode tests)

The encoder currently writes full structural expansions for all types. This change makes it emit `{tag="typeref",ids={...}}` for named record/sum/array types that are not the type currently being defined.

To know which type is "currently being defined," the encoder needs context. The emitter calls `encodeType()` in two places:
1. `emitPackageInfo()` — encoding symbol types for `__S_` (no self-reference issue)
2. `emitProgram()` — encoding type alias bodies for `__T_` (self-reference possible)

For `__S_` entries: all named types should use typeref (there's no "self" being defined).
For `__T_` entries: the top-level type being defined should NOT use typeref for itself at the top level, but nested references to OTHER named types should use typeref. However, the top-level call is already the full definition — the issue is if a field of the type references the same type recursively. Recursive types are handled by the `recursive` tag, so in practice the "defining type" exclusion only matters at the outermost call.

**Design decision:** Add an `encodeTypeWithContext` variant that takes an optional "defining TypeId" to exclude from typeref. The emitter's `__T_` loop passes the current alias's TypeId; `__S_` entries pass nil. The existing `encodeType()` becomes a wrapper that passes nil (all named types → typeref). This is the simplest approach requiring minimal changes to the emitter.

- [ ] **Step 1: Add the `writeLuaTypeRef` helper function**

In `chicc/type_writer.chi`, after the `writeFieldList` function (line 90) and before `writeLuaTypeImpl` (line 92), add:

```chi
fn writeTypeRef(sb: StringBuilder, ids: array[TypeId]) {
    sb.append("{tag=\"typeref\",ids=")
    writeTypeIdList(sb, ids, 1)
    sb.append("}")
}
```

- [ ] **Step 2: Add context variable for the "defining type"**

After the `var writeLuaType` forward declaration (line 45), add a module-level variable to hold the current defining TypeId:

```chi
var definingTypeId: TypeId | unit = unit
```

This requires importing the `|` union — but since `TypeId | unit` is already a pattern in Chi, this should work. Import `unit` is implicit. However, `TypeId` is already imported.

Actually, the simplest approach: use a Lua-side variable to avoid type system complications:

```chi
embedLua("local __defining_type_id = nil")
```

Add this right after line 7 (the import of util).

- [ ] **Step 3: Add the typeref check to `writeLuaTypeImpl`**

In `writeLuaTypeImpl`, for the `record`, `sum`, and `array` branches, add a check at the top of each branch: if the type has non-empty `ids` and is NOT the defining type, emit a typeref instead of the full expansion.

For the `record` branch (line 118), replace:

```chi
    } else if tag == "record" {
        sb.append("{tag=\"record\",ids=")
        val ids = typeIds(t)
        writeTypeIdList(sb, ids, 1)
        sb.append(",fields=")
        val fields = typeFields(t)
        writeFieldList(sb, fields)
        sb.append(",typeParams=")
        val tps = typeTypeParams(t)
        writeStringList(sb, tps)
        sb.append("}")
```

with:

```chi
    } else if tag == "record" {
        val ids = typeIds(t)
        val idCount = ids.size()
        val useRef = luaExpr("idCount > 0 and __defining_type_id ~= nil and not (ids[1].moduleName == __defining_type_id.moduleName and ids[1].packageName == __defining_type_id.packageName and ids[1].name == __defining_type_id.name) or (idCount > 0 and __defining_type_id == nil)") as bool
        if useRef {
            writeTypeRef(sb, ids)
        } else {
            sb.append("{tag=\"record\",ids=")
            writeTypeIdList(sb, ids, 1)
            sb.append(",fields=")
            val fields = typeFields(t)
            writeFieldList(sb, fields)
            sb.append(",typeParams=")
            val tps = typeTypeParams(t)
            writeStringList(sb, tps)
            sb.append("}")
        }
```

Wait — this logic is wrong. Let me think more carefully.

The conditions for using typeref are:
1. `ids` is non-empty (it's a named type)
2. It is NOT the type currently being defined (to avoid self-referencing in `__T_` entries)

When `__defining_type_id` is `nil` (i.e., encoding for `__S_`), condition 2 is automatically satisfied — any named type should use typeref.

When `__defining_type_id` is set (encoding for `__T_`), we use typeref only if the type's first id doesn't match the defining id.

Simplified Lua check:

```lua
idCount > 0 and (__defining_type_id == nil or not (ids[1].moduleName == __defining_type_id.moduleName and ids[1].packageName == __defining_type_id.packageName and ids[1].name == __defining_type_id.name))
```

For the `record` branch (line 118), replace:

```chi
    } else if tag == "record" {
        sb.append("{tag=\"record\",ids=")
        val ids = typeIds(t)
        writeTypeIdList(sb, ids, 1)
        sb.append(",fields=")
        val fields = typeFields(t)
        writeFieldList(sb, fields)
        sb.append(",typeParams=")
        val tps = typeTypeParams(t)
        writeStringList(sb, tps)
        sb.append("}")
```

with:

```chi
    } else if tag == "record" {
        val ids = typeIds(t)
        val idCount = ids.size()
        val useRef = luaExpr("idCount > 0 and (__defining_type_id == nil or not (ids[1].moduleName == __defining_type_id.moduleName and ids[1].packageName == __defining_type_id.packageName and ids[1].name == __defining_type_id.name))") as bool
        if useRef {
            writeTypeRef(sb, ids)
        } else {
            sb.append("{tag=\"record\",ids=")
            writeTypeIdList(sb, ids, 1)
            sb.append(",fields=")
            val fields = typeFields(t)
            writeFieldList(sb, fields)
            sb.append(",typeParams=")
            val tps = typeTypeParams(t)
            writeStringList(sb, tps)
            sb.append("}")
        }
```

For the `sum` branch (line 129), replace:

```chi
    } else if tag == "sum" {
        sb.append("{tag=\"sum\",ids=")
        val ids = typeIds(t)
        writeTypeIdList(sb, ids, 1)
        sb.append(",lhs=")
        val lhs = luaExpr("t.lhs") as Type
        writeLuaType(sb, lhs)
        sb.append(",rhs=")
        val rhs = luaExpr("t.rhs") as Type
        writeLuaType(sb, rhs)
        sb.append(",typeParams=")
        val tps = typeTypeParams(t)
        writeStringList(sb, tps)
        sb.append("}")
```

with:

```chi
    } else if tag == "sum" {
        val ids = typeIds(t)
        val idCount = ids.size()
        val useRef = luaExpr("idCount > 0 and (__defining_type_id == nil or not (ids[1].moduleName == __defining_type_id.moduleName and ids[1].packageName == __defining_type_id.packageName and ids[1].name == __defining_type_id.name))") as bool
        if useRef {
            writeTypeRef(sb, ids)
        } else {
            sb.append("{tag=\"sum\",ids=")
            writeTypeIdList(sb, ids, 1)
            sb.append(",lhs=")
            val lhs = luaExpr("t.lhs") as Type
            writeLuaType(sb, lhs)
            sb.append(",rhs=")
            val rhs = luaExpr("t.rhs") as Type
            writeLuaType(sb, rhs)
            sb.append(",typeParams=")
            val tps = typeTypeParams(t)
            writeStringList(sb, tps)
            sb.append("}")
        }
```

For the `array` branch (line 151), replace:

```chi
    } else if tag == "array" {
        sb.append("{tag=\"array\",elem=")
        val elem = luaExpr("t.elementType") as Type
        writeLuaType(sb, elem)
        sb.append(",typeParams=")
        val tps = typeTypeParams(t)
        writeStringList(sb, tps)
        sb.append(",ids=")
        val ids = typeIds(t)
        writeTypeIdList(sb, ids, 1)
        sb.append("}")
```

with:

```chi
    } else if tag == "array" {
        val ids = typeIds(t)
        val idCount = ids.size()
        val useRef = luaExpr("idCount > 0 and (__defining_type_id == nil or not (ids[1].moduleName == __defining_type_id.moduleName and ids[1].packageName == __defining_type_id.packageName and ids[1].name == __defining_type_id.name))") as bool
        if useRef {
            writeTypeRef(sb, ids)
        } else {
            sb.append("{tag=\"array\",elem=")
            val elem = luaExpr("t.elementType") as Type
            writeLuaType(sb, elem)
            sb.append(",typeParams=")
            val tps = typeTypeParams(t)
            writeStringList(sb, tps)
            sb.append(",ids=")
            writeTypeIdList(sb, ids, 1)
            sb.append("}")
        }
```

- [ ] **Step 4: Add `encodeTypeWithContext` function**

After the existing `encodeType` function (line 185-189), add a new public function:

```chi
pub fn encodeTypeWithContext(t: Type, defTypeId: TypeId): string {
    embedLua("__defining_type_id = defTypeId")
    val sb = newStringBuilder()
    writeLuaType(sb, t)
    embedLua("__defining_type_id = nil")
    sb.toString()
}
```

The existing `encodeType` remains unchanged — it encodes with `__defining_type_id = nil`, meaning all named types use typeref. This is correct for `__S_` entries.

- [ ] **Step 5: Write tests for typeref encoding**

In `tests/test_type_writer.chi`, add the following tests before the `summary()` call (line 341). First, add `encodeTypeWithContext` to the import:

Change line 3 from:
```chi
import chicc/type_writer { encodeType, decodeType }
```
to:
```chi
import chicc/type_writer { encodeType, encodeTypeWithContext, decodeType }
```

Then add tests before `summary()`:

```chi
test("encode record as typeref") {
    val r = recordType([newTypeId("chicc", "ast", "Expr")], [{ name: "kind", fieldType: tString }], [])
    val encoded = encodeType(r)
    assertEqual(encoded, "{tag=\"typeref\",ids={{\"chicc\",\"ast\",\"Expr\"}}}")
}

test("encode sum as typeref") {
    val s = sumType([newTypeId("test", "pkg", "Either")], tString, tInt, [])
    val encoded = encodeType(s)
    assertEqual(encoded, "{tag=\"typeref\",ids={{\"test\",\"pkg\",\"Either\"}}}")
}

test("encode array as typeref") {
    val a = arrayType(tInt, [])
    val encoded = encodeType(a)
    assertEqual(encoded, "{tag=\"typeref\",ids={{\"std\",\"lang.array\",\"array\"}}}")
}

test("encode empty-ids record stays structural") {
    val r = recordType([], [{ name: "x", fieldType: tInt }], [])
    val encoded = encodeType(r)
    assertEqual(encoded, "{tag=\"record\",ids={},fields={{\"x\",{tag=\"int\"}}},typeParams={}}")
}

test("encodeTypeWithContext: defining type stays structural") {
    val defId = newTypeId("chicc", "ast", "Expr")
    val r = recordType([defId], [{ name: "kind", fieldType: tString }], [])
    val encoded = encodeTypeWithContext(r, defId)
    assertEqual(encoded, "{tag=\"record\",ids={{\"chicc\",\"ast\",\"Expr\"}},fields={{\"kind\",{tag=\"string\"}}},typeParams={}}")
}

test("encodeTypeWithContext: other named type uses typeref") {
    val defId = newTypeId("chicc", "ast", "Expr")
    val otherType = recordType([newTypeId("chicc", "types", "Type")], [{ name: "tag", fieldType: tString }], [])
    val fnType = functionType([otherType, tString], [], 0)
    val encoded = encodeTypeWithContext(fnType, defId)
    // The otherType inside fnType should be a typeref
    assertEqual(encoded, "{tag=\"fn\",types={{tag=\"typeref\",ids={{\"chicc\",\"types\",\"Type\"}}},{tag=\"string\"}},typeParams={},defaults=0}")
}

test("encode primitive with extra ids stays primitive (no typeref)") {
    val extraId = newTypeId("mymod", "mypkg", "MyAlias")
    val aliased = primitiveType([intTypeId, extraId])
    val encoded = encodeType(aliased)
    assertEqual(encoded, "{tag=\"int\",ids={{\"mymod\",\"mypkg\",\"MyAlias\"}}}")
}
```

- [ ] **Step 6: Run the type_writer tests**

Run: `./run_tests.sh tests/test_type_writer.chi`
Expected: All new tests pass. Some existing tests will need updating (see Step 7).

- [ ] **Step 7: Update existing tests that now produce typerefs**

The following existing tests will break because they produce named types that now encode as typerefs instead of full expansions:

**"encode record type"** (line 60-63): This record has ids `[newTypeId("std", "lang.map", "Map")]`, so it now encodes as a typeref. Update:

```chi
test("encode record type") {
    val r = recordType([newTypeId("std", "lang.map", "Map")], [{ name: "name", fieldType: tString }, { name: "age", fieldType: tInt }], [])
    val encoded = encodeType(r)
    assertEqual(encoded, "{tag=\"typeref\",ids={{\"std\",\"lang.map\",\"Map\"}}}")
}
```

**"encode record with type params"** (line 72-75): Has ids `[newTypeId("std", "lang.map", "Map")]`. Update:

```chi
test("encode record with type params") {
    val r = recordType([newTypeId("std", "lang.map", "Map")], [{ name: "key", fieldType: variableType("K", 0) }], ["K", "V"])
    val encoded = encodeType(r)
    assertEqual(encoded, "{tag=\"typeref\",ids={{\"std\",\"lang.map\",\"Map\"}}}")
}
```

**"encode sum type"** (line 78-81): Has ids `[newTypeId("test", "pkg", "Either")]`. Update:

```chi
test("encode sum type") {
    val s = sumType([newTypeId("test", "pkg", "Either")], tString, tInt, [])
    val encoded = encodeType(s)
    assertEqual(encoded, "{tag=\"typeref\",ids={{\"test\",\"pkg\",\"Either\"}}}")
}
```

**"encode array type"** (line 96-99): `arrayType` sets `ids: [arrayTypeId]`. Update:

```chi
test("encode array type") {
    val a = arrayType(tInt, [])
    val encoded = encodeType(a)
    assertEqual(encoded, "{tag=\"typeref\",ids={{\"std\",\"lang.array\",\"array\"}}}")
}
```

**"encode recursive type"** (line 110-116): The inner record has ids `[newTypeId("test", "pkg", "List")]`, so it becomes a typeref inside the recursive wrapper. Update:

```chi
test("encode recursive type") {
    val v = variableType("X", 0)
    val r = recordType([newTypeId("test", "pkg", "List")], [{ name: "head", fieldType: tInt }, { name: "tail", fieldType: v }], [])
    val rec = recursiveType(v, r)
    val encoded = encodeType(rec)
    assertEqual(encoded, "{tag=\"rec\",var={tag=\"var\",name=\"X\",level=0},type={tag=\"typeref\",ids={{\"test\",\"pkg\",\"List\"}}}}")
}
```

**Roundtrip and decode tests:** These are affected because `typesEqual` compares encoded strings, and decoded types will now have different encoded forms. See Task 5 for how decode tests need to be restructured — those tests depend on the decoder being able to handle typerefs (Task 4).

**For now:** Comment out the roundtrip and decode tests for record/sum/array types that produce typerefs. They will be restored in Task 5 after the decoder is updated. Specifically, comment out:
- "decode record type" (line 169-174)
- "decode empty record" (line 176-181) — this one is FINE, empty ids stay structural
- "decode sum type" (line 183-188)
- "decode array type" (line 204-208)
- "decode recursive type" (line 220-227)
- "roundtrip record" (line 279-283)
- "roundtrip sum" (line 286-290)
- "roundtrip array" (line 300-304)
- "roundtrip recursive" (line 316-322)
- "roundtrip array of records" (line 333-338)

- [ ] **Step 8: Run the type_writer tests again**

Run: `./run_tests.sh tests/test_type_writer.chi`
Expected: All remaining tests pass with the updated expected values.

- [ ] **Step 9: Commit**

```bash
git add chicc/type_writer.chi tests/test_type_writer.chi
git commit -m "feat: encode named record/sum/array types as typeref instead of full expansion"
```

---

### Task 4: Add `typeref` Decoding to `decodeTableImpl`

**Files:**
- Modify: `chicc/type_writer.chi:271-335` (`decodeTableImpl` function)
- Test: `tests/test_type_writer.chi` (add typeref decode tests)

The decoder must handle `{tag="typeref", ids={...}}` by resolving the type from `package.loaded`. This requires access to the loaded module tables at decode time.

**Design:** When decoding a typeref, look up `package.loaded[mod/pkg]._types[name]` and decode that string. Cache resolved typerefs to avoid repeated decoding. This is done in Lua because it needs access to `package.loaded`.

- [ ] **Step 1: Add a typeref resolution cache**

At the top of `type_writer.chi`, after the `embedLua("local __defining_type_id = nil")` line added in Task 3, add:

```chi
embedLua("local __typeref_cache = {}")
```

Also add a public function to clear the cache (useful for testing and when recompiling):

```chi
pub fn clearTyperefCache() {
    embedLua("__typeref_cache = {}")
}
```

- [ ] **Step 2: Add typeref handling to `decodeTableImpl`**

In `decodeTableImpl` (line 271), add a new branch for `tag == "typeref"` before the `else` error branch (before line 331). Find:

```chi
    } else {
        embedLua("error('Unknown type tag: ' .. tostring(tag))")
        tUnit
    }
```

Insert before it:

```chi
    } else if tag == "typeref" {
        val ids = decodeLuaTypeIds(tbl, "ids")
        val firstId = ids[1]
        val mod = firstId.moduleName
        val pkg = firstId.packageName
        val name = firstId.name
        val cacheKey = luaExpr("mod .. '/' .. pkg .. '.' .. name") as string
        val cached = luaExpr("__typeref_cache[cacheKey]") as any
        if cached != unit {
            cached as Type
        } else {
            val qualifier = luaExpr("mod .. '/' .. pkg") as string
            val spec = luaExpr("package.loaded[qualifier] and package.loaded[qualifier]._types and package.loaded[qualifier]._types[name]") as any
            if spec != unit {
                val specStr = spec as string
                val resolved = decodeType(specStr)
                embedLua("__typeref_cache[cacheKey] = resolved")
                resolved
            } else {
                embedLua("error('typeref: cannot resolve type ' .. cacheKey)")
                tUnit
            }
        }
```

- [ ] **Step 3: Write decode tests for typeref**

In `tests/test_type_writer.chi`, add tests for typeref decoding. Since typerefs require `package.loaded` to resolve, we need to set up mock package data. Add before `summary()`:

```chi
test("decode typeref resolves from package.loaded") {
    // Set up a mock package with a type alias
    embedLua("package.loaded['test/mock'] = package.loaded['test/mock'] or {_package={},_types={}}")
    embedLua("package.loaded['test/mock']._types['MyRecord'] = '{tag=\"record\",ids={{\"test\",\"mock\",\"MyRecord\"}},fields={{\"value\",{tag=\"int\"}}},typeParams={}}'")
    val input = "{tag=\"typeref\",ids={{\"test\",\"mock\",\"MyRecord\"}}}"
    val decoded = decodeType(input)
    val tag = luaExpr("decoded.tag") as string
    assertEqual(tag, "record")
    val fieldCount = luaExpr("#decoded.fields") as int
    assertEqual(fieldCount, 1)
}

test("decode typeref caches resolved type") {
    // Uses the same mock from previous test
    embedLua("local __tr_call_count = 0")
    embedLua("package.loaded['test/mock2'] = {_package={},_types={}}")
    embedLua("package.loaded['test/mock2']._types['Cached'] = '{tag=\"record\",ids={{\"test\",\"mock2\",\"Cached\"}},fields={{\"x\",{tag=\"int\"}}},typeParams={}}'")
    // Clear cache to start fresh
    embedLua("__typeref_cache = {}")
    val input = "{tag=\"typeref\",ids={{\"test\",\"mock2\",\"Cached\"}}}"
    val decoded1 = decodeType(input)
    val decoded2 = decodeType(input)
    // Both should return the record type
    val tag1 = luaExpr("decoded1.tag") as string
    val tag2 = luaExpr("decoded2.tag") as string
    assertEqual(tag1, "record")
    assertEqual(tag2, "record")
}
```

- [ ] **Step 4: Run the type_writer tests**

Run: `./run_tests.sh tests/test_type_writer.chi`
Expected: All tests pass including the new typeref decode tests.

- [ ] **Step 5: Commit**

```bash
git add chicc/type_writer.chi tests/test_type_writer.chi
git commit -m "feat: add typeref decoding with package.loaded resolution and caching"
```

---

### Task 5: Restore and Fix Roundtrip and Decode Tests

**Files:**
- Modify: `tests/test_type_writer.chi` (restore commented-out tests, update expectations)

After Tasks 3 and 4, the encoder produces typerefs for named types and the decoder can resolve them. The roundtrip tests need updating: encoding a record with ids produces a typeref string, and decoding that typeref requires `package.loaded` to have the definition. The decode tests for structural formats still work (anonymous records), but named records via typeref need mock data.

- [ ] **Step 1: Restore and update decode tests**

Restore the commented-out decode tests. For tests that decode structural strings (e.g., `{tag="record",...}`), they still work because `decodeTableImpl` handles structural records directly — the decoder doesn't require types to be typerefs. So these can be restored as-is:

Restore "decode record type" (the input string is structural `{tag="record",...}`):
```chi
test("decode record type") {
    val input = "{tag=\"record\",ids={{\"std\",\"lang.map\",\"Map\"}},fields={{\"name\",{tag=\"string\"}},{\"age\",{tag=\"int\"}}},typeParams={}}"
    val decoded = decodeType(input)
    val expected = recordType([newTypeId("std", "lang.map", "Map")], [{ name: "name", fieldType: tString }, { name: "age", fieldType: tInt }], [])
    assertTrue(typesEqual(decoded, expected))
}
```

Wait — `typesEqual` uses `encodeType` to compare, and `encodeType` now produces typerefs for named types. So `encodeType(decoded)` will produce `{tag="typeref",...}` and `encodeType(expected)` will also produce `{tag="typeref",...}`. Both should match. So this test should actually still pass as-is.

Let me reconsider. `typesEqual(a, b)` calls `encodeType(a) == encodeType(b)`. Both `a` and `b` are `recordType([newTypeId("std", "lang.map", "Map")], ...)`. Both will encode as `{tag="typeref",ids={{"std","lang.map","Map"}}}`. So `typesEqual` returns true. **These tests should pass without changes.**

The decode tests decode structural strings into Type objects. Then `typesEqual` compares by encoding both sides — which now both encode as typerefs (since both have ids). So they should still match.

Restore ALL commented-out decode tests unchanged:
- "decode record type"
- "decode sum type"
- "decode array type"
- "decode recursive type"

- [ ] **Step 2: Restore and update roundtrip tests**

Roundtrip tests encode → decode → compare. With typerefs:
1. `encodeType(original)` produces `{tag="typeref",ids={...}}`
2. `decodeType(typeref_string)` must resolve via `package.loaded` — but in the test, there's no mock data for these types

This means roundtrip tests for named types WILL FAIL because decoding a typeref requires the type to be registered in `package.loaded`.

**Fix:** For roundtrip tests with named types, register the type in `package.loaded` before the test, OR use `encodeTypeWithContext` to produce structural output for roundtrip testing.

The cleanest approach: use `encodeTypeWithContext` with the type's own id to get a structural encoding, then decode that, then compare. This tests the structural encode/decode roundtrip without requiring `package.loaded`.

Update the roundtrip tests for named types:

```chi
test("roundtrip record") {
    val tid = newTypeId("std", "lang.map", "Map")
    val original = recordType([tid], [{ name: "name", fieldType: tString }, { name: "age", fieldType: tInt }], [])
    val encoded = encodeTypeWithContext(original, tid)
    val decoded = decodeType(encoded)
    assertTrue(typesEqual(decoded, original))
}

test("roundtrip sum") {
    val tid = newTypeId("test", "pkg", "Either")
    val original = sumType([tid], tString, tInt, [])
    val encoded = encodeTypeWithContext(original, tid)
    val decoded = decodeType(encoded)
    assertTrue(typesEqual(decoded, original))
}

test("roundtrip array") {
    val original = arrayType(tInt, [])
    val tid = arrayTypeId
    val encoded = encodeTypeWithContext(original, tid)
    val decoded = decodeType(encoded)
    assertTrue(typesEqual(decoded, original))
}

test("roundtrip recursive") {
    val v = variableType("X", 0)
    val tid = newTypeId("test", "pkg", "List")
    val r = recordType([tid], [{ name: "head", fieldType: tInt }, { name: "tail", fieldType: v }], [])
    val original = recursiveType(v, r)
    val encoded = encodeTypeWithContext(original, tid)
    val decoded = decodeType(encoded)
    assertTrue(typesEqual(decoded, original))
}

test("roundtrip array of records") {
    val recTid = newTypeId("m", "p", "Point")
    val rec = recordType([recTid], [{ name: "x", fieldType: tFloat }, { name: "y", fieldType: tFloat }], [])
    val original = arrayType(rec, [])
    // Use arrayTypeId as the defining type so array stays structural,
    // but the inner record will still be a typeref.
    // For a true structural roundtrip, we need the record in package.loaded.
    embedLua("package.loaded['m/p'] = package.loaded['m/p'] or {_package={},_types={}}")
    embedLua("package.loaded['m/p']._types['Point'] = '{tag=\"record\",ids={{\"m\",\"p\",\"Point\"}},fields={{\"x\",{tag=\"float\"}},{\"y\",{tag=\"float\"}}},typeParams={}}'")
    val encoded = encodeTypeWithContext(original, arrayTypeId)
    val decoded = decodeType(encoded)
    assertTrue(typesEqual(decoded, original))
}

test("roundtrip higher-order function") {
    val inner = functionType([tInt, tBool], [], 0)
    val outer = functionType([inner, tString], [], 0)
    val encoded = encodeType(outer)
    val decoded = decodeType(encoded)
    assertTrue(typesEqual(decoded, outer))
}
```

- [ ] **Step 3: Run the type_writer tests**

Run: `./run_tests.sh tests/test_type_writer.chi`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add tests/test_type_writer.chi
git commit -m "test: restore and update roundtrip/decode tests for typeref encoding"
```

---

### Task 6: Update Emitter to Use `encodeTypeWithContext` for `__T_` Entries

**Files:**
- Modify: `chicc/emitter.chi:877-884` (type alias encoding in `emitProgram`)
- Test: `tests/test_compiler.chi` (existing `compileToLua` tests)

The emitter's `__T_` loop currently uses `encodeType(aliasType)`. Since `encodeType` now produces typerefs for all named types, the top-level `__T_` definition itself would be a typeref — a circular reference. The fix: use `encodeTypeWithContext` passing the current alias's TypeId so the defining type is expanded structurally while nested named types use typerefs.

The `__S_` entries in `emitPackageInfo` should continue using `encodeType` (no self-reference issue — symbol types are never the same as the type being defined).

- [ ] **Step 1: Update the `__T_` encoding loop in `emitProgram`**

In `chicc/emitter.chi`, the type alias loop at lines 877-884:

```chi
    while ai <= aliasCount {
        val aliasName = luaExpr("prog.typeAliases[ai].typeId.name") as string
        val aliasType = luaExpr("prog.typeAliases[ai].aliasType") as any
        val encoded = luaExpr("require('chicc/type_writer').encodeType(aliasType)") as string
        emit(st, "__T_.$aliasName='$encoded';")
        ai = ai + 1
    }
```

Replace with:

```chi
    while ai <= aliasCount {
        val aliasName = luaExpr("prog.typeAliases[ai].typeId.name") as string
        val aliasType = luaExpr("prog.typeAliases[ai].aliasType") as any
        val aliasTypeId = luaExpr("prog.typeAliases[ai].typeId") as any
        val encoded = luaExpr("require('chicc/type_writer').encodeTypeWithContext(aliasType, aliasTypeId)") as string
        emit(st, "__T_.$aliasName='$encoded';")
        ai = ai + 1
    }
```

- [ ] **Step 2: Run compiler tests**

Run: `./run_tests.sh tests/test_compiler.chi`
Expected: All tests pass.

- [ ] **Step 3: Run full unit test suite**

Run: `./run_tests.sh`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add chicc/emitter.chi
git commit -m "fix: use encodeTypeWithContext for __T_ entries to avoid self-referencing typerefs"
```

---

### Task 7: Update `getTypeAlias` Cache to Handle Typerefs

**Files:**
- Modify: `chicc/compiler.chi:38` (`__chicc_mkEnv` — the `getTypeAlias` function)

Now that `__T_` entries contain typerefs, the `getTypeAlias` decoder must be able to resolve them. The typeref decoder (added in Task 4) already handles this by looking up `package.loaded[qualifier]._types[name]`. However, there's a potential issue: when decoding a type alias that contains a typeref to a type from a different package that hasn't been loaded yet, or a typeref to a type in the same package's `__T_` table.

The decoder in `decodeTableImpl` resolves typerefs via `package.loaded`. Since `getTypeAlias` is called during compilation, all imported packages are already loaded. For same-package references, the `__T_` table is already populated by the time other packages read it.

**However**, the `aliasCache` (from Task 2) now decodes all aliases in a package at once. If alias A references alias B from the same package via typeref, and B hasn't been decoded yet, the typeref resolution will try to decode B recursively. This should work because `decodeType(spec)` reads directly from `_types[name]` — which is a raw string, not a decoded result.

This task verifies the interaction works correctly and adds a safety improvement.

- [ ] **Step 1: Clear typeref cache before batch alias decoding**

In `compiler.chi:38`, in the `getTypeAlias` function (modified in Task 2), add a typeref cache clear before decoding a new package's aliases:

Find in the aliasCache-enabled `getTypeAlias`:
```lua
pkgAliases = {}; for aliasName, spec in pairs(loaded._types) do
```

Insert before it:
```lua
require('chicc/type_writer').clearTyperefCache();
```

So the full function becomes:
```lua
function env.getTypeAlias(mod, pkg, name) local qualifier = mod .. '/' .. pkg; local pkgAliases = aliasCache[qualifier]; if pkgAliases == nil then local loaded = package.loaded[qualifier]; if loaded == nil or loaded._types == nil then return nil end; pkgAliases = {}; require('chicc/type_writer').clearTyperefCache(); for aliasName, spec in pairs(loaded._types) do if type(spec) == 'string' then local ok, decoded = pcall(function() return _tw.decodeType(spec) end); if ok then pkgAliases[aliasName] = { typeId = { moduleName = mod, packageName = pkg, name = aliasName }, aliasType = decoded } end end end; aliasCache[qualifier] = pkgAliases end; return pkgAliases[name] end;
```

- [ ] **Step 2: Run unit tests**

Run: `./run_tests.sh tests/test_compiler.chi`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add chicc/compiler.chi
git commit -m "fix: clear typeref cache before batch alias decoding in getTypeAlias"
```

---

### Task 8: Rebuild Compiler Cache and Run Golden Tests

**Files:**
- No source changes
- Verification: `.cache/chicc/*.lua` sizes, golden tests

This task rebuilds the compiler from the modified sources and runs the golden test suite to verify end-to-end correctness.

- [ ] **Step 1: Delete the old cache**

```bash
rm -rf .cache/chicc/
```

- [ ] **Step 2: Rebuild the cache using the JVM compiler**

```bash
/home/marad/dev/chi/compiler/chi compile.chi
```

This recompiles all 19 modules with the modified type_writer and emitter, producing new `.cache/chicc/*.lua` files and a new `chicc.lua`.

Expected: Successful compilation with no errors.

- [ ] **Step 3: Check compiled file sizes**

```bash
ls -la .cache/chicc/ast.lua .cache/chicc/emitter.lua .cache/chicc/types.lua .cache/chicc/parse_ast.lua
wc -c .cache/chicc/*.lua | tail -1
```

Expected size reductions:
- `ast.lua`: ~2.6 MB → ~25-50 KB (dramatic reduction)
- `emitter.lua`: ~840 KB → ~40-80 KB
- `types.lua`: ~265 KB → ~30-50 KB
- `parse_ast.lua`: ~190 KB → ~25-40 KB
- Total: ~4.2 MB → ~200-400 KB

- [ ] **Step 4: Run the full unit test suite with rebuilt cache**

```bash
./run_tests.sh
```

Expected: All tests pass.

- [ ] **Step 5: Run golden tests**

```bash
./test_golden.sh
```

Expected: All 52 golden tests pass. The golden tests compile and run `.chi` files end-to-end, verifying both compilation output and runtime behavior.

- [ ] **Step 6: Commit any generated file changes (if chicc.lua is tracked)**

```bash
git status
# If chicc.lua changed:
git add chicc.lua
git commit -m "build: regenerate chicc.lua with typeref optimization"
```

---

### Task 9: Profile Before/After and Final Self-Compilation

**Files:**
- No source changes
- Verification: profiling data, self-compilation test

- [ ] **Step 1: Profile compilation of a representative module**

```bash
CHI_PROFILE=1 luajit run_chicc.sh compile chicc/ast.chi -o /tmp/ast_typeref.lua 2>/tmp/profile_ast.txt
cat /tmp/profile_ast.txt
```

Expected: Profile output showing phase timings. The `emit` phase should be dramatically faster than before (generating KB instead of MB of type metadata).

- [ ] **Step 2: Compare output sizes**

```bash
wc -c /tmp/ast_typeref.lua
```

Expected: Dramatically smaller than the previous 2.6 MB.

- [ ] **Step 3: Self-compilation test**

This is the final validation — using the optimized compiler to compile itself:

```bash
CHI_PROFILE=1 luajit run_chicc.sh compile compile.chi 2>/tmp/profile_self.txt
cat /tmp/profile_self.txt
```

Expected: Successful self-compilation with profiling output for each module, total time dramatically reduced from ~30 minutes.

- [ ] **Step 4: Verify self-compiled output matches**

After self-compilation produces a new `chicc.lua`, run golden tests with it:

```bash
./test_golden.sh
```

Expected: All golden tests pass with the self-compiled compiler.
