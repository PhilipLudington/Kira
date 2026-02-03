# Kira Language Bugs

Bugs encountered in the Kira language compiler and type system.

---

## [x] Bug 1: Type check errors don't fail compilation (CRITICAL)

**Status:** Fixed

**Description:** The TypeChecker collects error diagnostics but never returns an error to fail compilation. This means completely undefined types, missing symbols, and type mismatches are silently ignored - code compiles and runs even with obvious type errors.

**Root Cause:**
- `src/typechecker/checker.zig` line 97: The `check()` function collects diagnostics via `addDiagnostic()` but never checks if any are errors before returning success
- `src/typechecker/unify.zig` line 17: Error types unify with any type (`if (a.isError() or b.isError()) return true;`) for "error recovery", which masks cascading errors
- `src/main.zig` lines 665-672: After `check()` succeeds, only warnings are printed - error diagnostics are completely ignored

**Steps to reproduce:**
```kira
// examples/cross_module_test/test_isolated.ki
module cross_module_test.test_isolated

fn main() -> i64 {
    // NonExistentType doesn't exist ANYWHERE - should fail!
    let p: NonExistentType = NonExistentType { value: 42 }
    return p.value
}
```
```bash
$ kira check examples/cross_module_test/test_isolated.ki
Check passed: examples/cross_module_test/test_isolated.ki

$ kira run examples/cross_module_test/test_isolated.ki
42
```

**Expected:** Compilation should fail with "undefined type 'NonExistentType'"

**Actual:** Code compiles and runs successfully, returning 42

**Impact:**
- **CRITICAL:** Type safety is completely broken
- Undefined symbols silently become error types that match anything
- Users get no feedback about type errors
- Runtime behavior is undefined for code that should never compile

**Fix applied:**
1. Added check at end of `TypeChecker.check()` to return `error.TypeError` if any error diagnostics were collected (`src/typechecker/checker.zig:125`)
2. Added check at end of `Resolver.resolve()` to return `error.UndefinedSymbol` if any error diagnostics were collected (`src/symbols/resolver.zig:178`)
3. Updated `src/main.zig` to create Resolver directly and access its diagnostics for printing (lines 364-377, 645-658, 761-773)
4. Added `formatResolverDiagnostic` function to format resolver diagnostics with source context
5. Added skip for `std` identifier to avoid false positives for built-in stdlib namespace
6. Exported `ResolverDiagnostic` type from `src/root.zig`

**Files modified:**
- `src/typechecker/checker.zig` - Added error check at end of `check()`
- `src/symbols/resolver.zig` - Added error check at end of `resolve()`, skip `std` identifier
- `src/main.zig` - Updated to print resolver diagnostics, added `formatResolverDiagnostic`
- `src/root.zig` - Exported `ResolverDiagnostic`

---

## [x] Bug 2: Cross-module import visibility not enforced

**Status:** Fixed (was blocked by Bug 1)

**Description:** The resolver has code to check visibility when importing symbols, but the error is only added to diagnostics and never surfaced. Combined with Bug 1, private types can be "imported" and used freely.

**Root Cause:**
- `src/symbols/resolver.zig` lines 612-616: Visibility check exists and adds error diagnostic, but then just `continue`s
- The import alias isn't created for private symbols, BUT...
- Due to Bug 1, when the type is later used and not found, the error type silently matches everything

**Code that should enforce visibility:**
```zig
// src/symbols/resolver.zig:612-616
if (!sym.is_public) {
    try self.addError("Cannot import private symbol '{s}'", .{item.name}, item.span);
    continue;  // Import not created, but error never surfaces
}
```

**Steps to reproduce:**
```kira
// module_a.ki
module test.module_a
type PrivateType = { value: i64 }  // No 'pub' keyword
pub type PublicType = { value: i64 }

// main.ki
module test.main
import test.module_a.{ PrivateType }  // Should fail - not public!

fn main() -> i64 {
    let p: PrivateType = PrivateType { value: 42 }
    return p.value
}
```

**Expected:** Compilation fails with "Cannot import private symbol 'PrivateType'"

**Actual:** Compiles and runs (due to Bug 1 masking the error)

**Fix verified:** With Bug 1 fixed, the "Cannot import private symbol" error now surfaces correctly.

Example output:
```
error: Cannot import private symbol 'PrivateType'
  --> examples/cross_module_test/test_private.ki:5:37
   5 | import cross_module_test.module_a.{ PrivateType }
     |                                     ^
```

---

## [x] Bug 3: Cross-module type imports cause code duplication (user-facing symptom)

**Status:** Fixed (root cause was Bug 1 + Bug 2)

**Description:** Users in the Tharn project (`/Users/mrphil/Fun/Tharn`) report that cross-module type imports don't work, forcing them to duplicate type definitions across files.

**Investigation Results:**

This is a **symptom**, not a root cause. The actual issues are:

1. **Bug 1 (Critical):** Type check errors don't fail compilation - users get no error messages
2. **Bug 2:** Visibility errors aren't surfaced - private types silently fail to import
3. **User types missing `pub` keyword:** In Tharn, all types use `type Foo = ...` instead of `pub type Foo = ...`

**Evidence from Tharn project:**
```kira
// /Users/mrphil/Fun/Tharn/runtime/agent.ki
type AgentId = { id: u64 }        // Missing 'pub'!
type AgentState = | Running | ... // Missing 'pub'!
type Agent = { ... }              // Missing 'pub'!
```

**Working examples in Kira use `pub type`:**
```kira
// /Users/mrphil/Fun/Kira/examples/geometry/geometry/shapes.ki
pub type Vec2 = { x: f64, y: f64 }      // Has 'pub'
pub type Rectangle = { origin: Vec2, ... }  // Has 'pub'
```

**The module system IS implemented correctly:**
- Module loader: `src/modules/loader.zig` - loads and registers modules
- Symbol resolver: `src/symbols/resolver.zig` - processes imports, checks visibility
- Type checker: `src/typechecker/checker.zig` - follows import aliases
- Working examples: `examples/geometry/`, `examples/package_demo/`

**Why users think imports are broken:**
1. They try to import a type without `pub`
2. Resolver adds "Cannot import private symbol" error to diagnostics
3. Due to Bug 1, the error is never shown
4. Code compiles but types don't work as expected
5. Users conclude "imports are broken" and duplicate types

**Fix path:**
1. Fix Bug 1 (type errors fail compilation)
2. Verify Bug 2 error surfaces
3. Users will then see clear error messages about missing `pub` keyword
4. Update documentation to emphasize `pub type` requirement for exports

**Affected project:** `/Users/mrphil/Fun/Tharn`
- `runtime/agent.ki` - types need `pub` keyword
- `runtime/tools.ki` - types need `pub` keyword
- All other files with duplicated types can then import properly

---

## Investigation Notes

### Files examined:
| Component | File | Key Lines |
|-----------|------|-----------|
| Type Checker | `src/typechecker/checker.zig` | 97-122 (check function) |
| Type Unification | `src/typechecker/unify.zig` | 15-17 (error type handling) |
| Symbol Resolver | `src/symbols/resolver.zig` | 612-616 (visibility check) |
| Module Loader | `src/modules/loader.zig` | 157-321, 591-661 |
| Main Entry | `src/main.zig` | 501-682 (checkFile) |
| AST Expression | `src/ast/expression.zig` | 282-285 (RecordLiteral) |

### Test files created:
- `examples/cross_module_test/module_a.ki` - defines public and private types
- `examples/cross_module_test/main.ki` - imports public type (works)
- `examples/cross_module_test/test_private.ki` - imports private type (should fail, doesn't)
- `examples/cross_module_test/test_no_import.ki` - uses type without import (should fail, doesn't)
- `examples/cross_module_test/test_isolated.ki` - uses nonexistent type (should fail, doesn't)
- `examples/cross_module_test/test_global_leak.ki` - demonstrates type visibility leak

### Key finding:
The error recovery mechanism (`error types unify with anything`) combined with diagnostics never failing compilation creates a situation where **any type error is silently swallowed**. This is the root cause of the perceived "cross-module import" bug.

---

## [x] Bug 4: Local variable bindings not added to scope (CRITICAL REGRESSION)

**Status:** Fixed

**Severity:** CRITICAL - Blocks all Kira programs using local variables

**Introduced in:** Commits after `b340a97` (v0.11.0), likely in `2b45083` or `02535bb`

**Description:** After the recent changes to make type check and resolve errors fail compilation, local variable bindings (`let` and `var`) are no longer being added to the resolver's scope. Any reference to a locally-bound variable results in "undefined symbol" errors.

**Minimal reproduction:**

```kira
fn my_func() -> i32 {
    let x: i32 = 5
    return x
}

effect fn main() -> void {
    return
}
```

```bash
$ kira check /tmp/test.ki
error: undefined symbol 'x'
  --> /tmp/test.ki:3:12
   3 |     return x
     |            ^

Error: error.TypeCheckError
```

**Expected:** Code compiles successfully - `x` should be in scope after `let x: i32 = 5`

**Actual:** "undefined symbol 'x'" error

**Root Cause:**
The type checker (`src/typechecker/checker.zig`) never entered function scopes when checking function bodies. The resolver entered function scopes, added local bindings, then left. After the resolver finished, the symbol table's `current_scope_id` was back at module/global level. The type checker then called `symbol_table.lookup()` which searched from the current (module) scope — it couldn't find local variables or function parameters because they lived in function scopes that were no longer active.

**Fix applied:**
1. Modified `checkFunctionDecl` to enter a new function scope, add parameters as variable symbols, check the body, then leave scope
2. Modified `checkStatement` for `let_binding` to define the pattern's identifier as a variable in the current scope after type checking
3. Modified `checkStatement` for `var_binding` to define the variable in the current scope after type checking
4. Added `enterScope(.block)` / `leaveScope()` around block-scoped statements (if, for, while, loop, match arms, block) and expressions (match expr arms, if expr branches) to match the resolver's scope handling
5. Added function scope around `test_decl` bodies

**Files modified:**
- `src/typechecker/checker.zig` - All changes in this file

---

### Additional Test Cases

| Test | Code | Result |
|------|------|--------|
| let binding | `let x: i32 = 5; return x` | ❌ undefined symbol 'x' |
| var binding | `var x: i32 = 5; return x` | ❌ undefined symbol 'x' |
| var in effect fn | `effect fn f() { var x: i32 = 5; return x }` | ❌ undefined symbol 'x' |
| no local vars | `fn f() -> i32 { return 5 }` | ✅ works |
| function params | `fn f(x: i32) -> i32 { return x }` | ✅ works |

**Key finding:** Function parameters work correctly, but `let` and `var` bindings inside function bodies do not.

---

### Impact

This regression breaks:
- ALL Kira programs using local variables
- The Kira examples (e.g., `examples/fibonacci.ki`)
- The Kira-Lisp interpreter project (16+ functions affected)
- Any code using `var` for mutable state
- Any code using `let` for local bindings

---

### Root Cause Analysis

The bug was introduced when fixing Bug 1 (type check errors not failing compilation). The changes to `src/symbols/resolver.zig` likely broke the logic that adds local bindings to the current scope.

**Suspected location:** `src/symbols/resolver.zig` - the resolver's handling of `let` and `var` statements

**Investigation steps:**

1. Check `resolve()` method for `Statement.let_binding` and `Statement.var_binding` cases
2. Verify bindings are being added to the current scope via `defineLocal()` or equivalent
3. Check if the `hasErrors()` check at the end of `resolve()` is short-circuiting before bindings are processed
4. Compare resolver behavior between `b340a97` (working) and `02535bb` (broken)

---

### Workaround

**None** - This bug blocks all meaningful Kira development.

Temporary option: Use commit `b340a97` (Kira v0.11.0 before the fix) which still has the silent type error bug but at least allows code to run.

```bash
cd ~/Fun/Kira
git checkout b340a97
zig build
# Use ./zig-out/bin/kira instead of /usr/local/bin/kira
```

---

### Files to Investigate

- `src/symbols/resolver.zig` - Local binding resolution
- `src/typechecker/checker.zig` - Type checking of let/var statements
- `src/main.zig` - Error handling flow changes

---

### Related

- Bug 1: Type check errors don't fail compilation (the fix for this introduced Bug 4)
- Commit `2b45083`: "Fix Bug 1: Type check and resolve errors now fail compilation"
- Commit `02535bb`: Merge PR for cross-module imports

---
