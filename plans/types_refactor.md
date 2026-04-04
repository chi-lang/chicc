# Refactor: Eliminate massive import lists via proper typing and UFCS

## Problem

Many files have enormous import lists from `chicc/parse_ast`, `chicc/types`, and `chicc/ast` because accessor functions are called directly (`paTag(node)`) instead of via UFCS (`node.paTag()`). UFCS auto-resolution only works when the receiver has a concrete type — currently the `pa*` and `tr*` accessors take `any`, defeating auto-resolution.

## Goal

Change accessor function signatures to use their real types, convert call sites to UFCS, and remove the now-unnecessary imports. Constructor functions (called directly to create values) stay imported.

## Part 1: `chicc/parse_ast` — `pa*` accessors

### 1a. Change `pa*` signatures from `any` to `ParseAst`

In `chicc/parse_ast.chi` (lines 517-567), change all `pa*` functions:

```chi
// Before:
pub fn paTag(p: any): string { luaExpr("p.tag") }

// After:
pub fn paTag(p: ParseAst): string { luaExpr("p.tag") }
```

All ~50 `pa*` functions follow this pattern. Change `p: any` → `p: ParseAst` for every one.

### 1b. Convert call sites to UFCS

In every file that imports `pa*` functions, convert direct calls to UFCS:

```chi
// Before:
val tag = paTag(node)
val name = paName(node)

// After:
val tag = node.paTag()
val name = node.paName()
```

**Files to update:**
- `chicc/ast_converter.chi` — heaviest user (~all pa* functions)
- `chicc/parser.chi` — uses paTag, paSection, paBody, etc.
- `tests/test_parser_expr.chi` — paTag, paLongValue, paOp, etc.
- `tests/test_parser_stmts.chi` — paTag, paName, paBody, etc.
- `tests/test_parser_control.chi` — paTag, paCondition, paForVars, etc.
- `tests/test_parser_effects.chi` — paTag, paName, paEffectCases, etc.
- `tests/test_parser_interp.chi` — paTag, paStringValue, paParts, etc.
- `tests/test_parse_ast.chi` — paTag, paLongValue, paName, etc.

### 1c. Remove `pa*` from import lists

After converting to UFCS, remove all `pa*` functions from the import lines. Keep constructor imports (`parseLongValue`, `newFormalArgument`, etc.) and type imports (`ParseAst`, `PackageDefinition`, etc.).

## Part 2: `chicc/parse_ast` — `tr*` accessors

### 2a. Change `tr*` signatures from `any` to `TypeRef`

In `chicc/parse_ast.chi` (lines 71-82), change all `tr*` functions:

```chi
// Before:
pub fn trTag(tr: any): string { luaExpr("tr.tag") }

// After:
pub fn trTag(tr: TypeRef): string { luaExpr("tr.tag") }
```

The `TypeRef` type already exists at line 7 of parse_ast.chi.

### 2b. Convert call sites to UFCS

```chi
// Before:
val tag = trTag(ref)

// After:
val tag = ref.trTag()
```

**Files to update:**
- `chicc/symbols.chi` — uses trTag, trName, trTypeParameters, etc.
- `tests/test_parser_types.chi` — uses all tr* functions
- `tests/test_parse_ast.chi` — uses trTag, trName, etc.

### 2c. Remove `tr*` from import lists

Remove all `tr*` functions from import lines in the files above.

## Part 3: `chicc/types` — accessor and predicate functions

### 3a. No signature changes needed

These already take `Type` as their first parameter:

```chi
pub fn typeTag(t: Type): string { ... }
pub fn isPrimitive(t: Type): bool { ... }
pub fn typeIds(t: Type): array[TypeId] { ... }
// etc.
```

### 3b. Convert call sites to UFCS

```chi
// Before:
val tag = typeTag(t)
if isPrimitive(t) { ... }
val ids = typeIds(t)

// After:
val tag = t.typeTag()
if t.isPrimitive() { ... }
val ids = t.typeIds()
```

Functions to convert (all take `Type` as first param):
- Accessors: `typeTag`, `typeIds`, `typeTypes`, `typeTypeParams`, `typeDefaults`, `typeFields`, `typeLhs`, `typeRhs`, `typeElementType`, `typeName`, `typeLevel`, `typeVariable`, `typeInnerType`, `typeBody`, `typeTypesCount`, `typeFieldsCount`
- Predicates: `isPrimitive`, `isFunction`, `isRecord`, `isSum`, `isArray`, `isVariable`, `isRecursive`
- Operations on Type: `typeEquals` (takes two Types — first param is receiver), `typeChildren`, `replaceVariable`, `occursIn`, `occursInExcludingSumBranches`, `unfoldRecursive`, `instantiate`, `sumListTypes`

**Files to update:**
- `chicc/type_writer.chi` — heaviest user
- `chicc/unification.chi` — heavy user
- `chicc/typer.chi` — heavy user
- `chicc/symbols.chi`
- `chicc/checks.chi`
- `chicc/inference_context.chi`
- All `tests/test_types*.chi`, `tests/test_unification.chi`, `tests/test_typer.chi`, `tests/test_inference_ctx.chi`, `tests/test_resolve_type.chi`, `tests/test_type_writer.chi`, `tests/test_compiler.chi`

### 3c. Remove accessor/predicate imports

After converting to UFCS, remove those functions from import lines. Keep:
- Type names: `Type`, `TypeId`, `RecordField`
- Constructors: `primitiveType`, `functionType`, `recordType`, `sumType`, `sumCreate`, `arrayType`, `variableType`, `recursiveType`, `polyType`, `mapType`, `newTypeId`
- Well-known instances: `tAny`, `tUnit`, `tBool`, `tInt`, `tFloat`, `tString`, `anyTypeId`, `unitTypeId`, `boolTypeId`, `intTypeId`, `floatTypeId`, `stringTypeId`, `optionTypeId`

## Part 4: `chicc/ast` — `expr*` and `setExpr*` accessors

### 4a. No signature changes needed

These already take `Expr` as their first parameter:

```chi
pub fn exprKind(e: Expr): string { ... }
pub fn setExprType(e: Expr, t: Type | unit) { ... }
```

### 4b. Convert call sites to UFCS

```chi
// Before:
val kind = exprKind(e)
setExprType(e, someType)

// After:
val kind = e.exprKind()
e.setExprType(someType)
```

**Files to update:**
- `chicc/ast.chi` — internal uses (exprChildren uses expr* accessors)
- `chicc/ast_converter.chi` — uses setExprType
- `chicc/typer.chi` — uses setExprType, setExprDotTarget
- `chicc/checks.chi` — uses exprChildren
- `tests/test_ast.chi` — uses exprKind, exprAtomValue, exprChildren
- `tests/test_typer.chi` — uses exprExprType, exprKind, setExprType
- `tests/test_checks.chi` — uses exprExprType
- `tests/test_compiler.chi` — uses exprKind, exprExprType, exprUsed, setExprUsed

### 4c. Remove `expr*`/`setExpr*` from import lists

Keep type names (`Expr`, `Program`, `DotTarget`, `Target`, `FnParam`, `ExprField`) and constructors (`atomExpr`, `fnCallExpr`, `localTarget`, etc.).

## Execution order

Do parts 1-4 independently or sequentially. Each part is self-contained:
1. Change signatures (if needed)
2. Convert call sites to UFCS
3. Remove imports
4. Compile and test after each part

## Verification

After each part:
```bash
chi compile compile.chi          # compiler still builds
./run_tests.sh                   # all 44 tests pass
```
