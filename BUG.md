# Project Bugs

## [ ] Bug 1: Kira cross-module type imports cause massive code duplication

**Status:** Open (Blocked by two Kira language bugs — see updates below)

**Description:** Kira's module system cannot properly import types across modules, forcing developers to inline duplicate type definitions in every file that needs them. This affects core types like `Agent`, `AgentState`, `ToolResult`, and related functions.

**Affected files:**
- `runtime/agent.ki` (original definitions)
- `runtime/execloop.ki` (duplicates Agent, AgentState, ToolResult)
- `runtime/tools.ki` (duplicates ToolResult)
- `tools/fs.ki` (duplicates ToolResult)
- `tools/net.ki` (duplicates ToolResult)
- `tools/test.ki` (duplicates ToolResult)

**Steps to reproduce:**
1. Create a type in `runtime/agent.ki`
2. Try to import and use that type in `runtime/execloop.ki`
3. Compilation fails or types are not recognized

**Expected:** Types defined in one module should be importable and usable in other modules.

**Actual:** Types must be copy-pasted into each file, with comments like "NOTE: Types are inlined here to work around Kira cross-module issues."

**Impact:**
- ~200 lines of duplicated code across 6 files
- Bug fixes must be applied in multiple places
- Copies can drift and become inconsistent
- Refactoring is extremely difficult
- Violates DRY principle

**Workaround:** Manually keep all copies in sync. Consider adding a code generation script to produce duplicated sections from a single source.

**Fix needed:** Fix Kira language bug first (see Root Cause Analysis below).

---

### Update (2026-02-12): Response to compiler-team assertion that bug is fixed

Below is the response text prepared for compiler maintainers.

**Subject:** Import resolver still broken in Tharn on Kira v0.11.1 (repro attached)

Hi compiler team,

I re-validated this on February 12, 2026 in Tharn, and the import bug still reproduces.

**Environment:**
- `kira --version`: `Kira Programming Language v0.11.1`
- `klar --version`: `Klar 0.4.0`

**Repro command:**
```bash
cd /Users/mrphil/Fun/Tharn
kira run runtime/test.ki
```

**Actual behavior:**
- Import diagnostics include many `Cannot import private symbol ...`
- Imported names then fail to resolve with `Undefined identifier ...` when used

This indicates imported bindings are still not reliably usable in the importing module, which matches the unresolved resolver issue described above.

**Acceptance criteria still not met:**
1. `import a.{ ... }` should bind imported names for both type and value positions.
2. `pub` imports should resolve successfully (while non-`pub` imports should fail).
3. Import-dependent code paths should compile/run without inlined workarounds.

**Current Tharn status:**
- Workaround duplication is still required in:
  - `runtime/execloop.ki`
  - `tools/fs.ki`
  - `tools/net.ki`
  - `tools/test.ki`

If helpful, I can provide a minimal two-file repro (`a.ki` + `main.ki`) that isolates this from Tharn project complexity.

### Root Cause Analysis (2026-01-31)

Investigation revealed this is a **Kira language bug**, not a Tharn project issue.

**The actual problem:** Kira's type checker doesn't know about the `std` namespace. Even the simplest Kira program fails:

```kira
effect fn main() -> void {
    std.io.println("Hello")
}
```

**Error:** `undefined symbol 'std'`

**Technical details:**

1. **Resolver vs Type Checker inconsistency:**
   - The resolver (`resolver.zig:883`) has special handling to skip errors for `std`:
     ```zig
     if (self.table.lookup(ident.name) == null and !std.mem.eql(u8, ident.name, "std")) {
         try self.addError("Undefined identifier '{s}'", .{ident.name}, expr.span);
     }
     ```
   - The type checker (`checker.zig:376-382`) has NO such exception:
     ```zig
     .identifier => |ident| {
         if (self.symbol_table.lookup(ident.name)) |sym| {
             return try self.getSymbolType(sym, expr.span);
         } else {
             try self.addDiagnostic(try errors_mod.undefinedSymbol(...));
         }
     }
     ```

2. **`std` is only registered at runtime:**
   - The stdlib is registered in the interpreter (`stdlib/root.zig:42-73`)
   - This happens AFTER type checking completes
   - The symbol table never contains `std` during type checking

3. **Even Kira's official examples fail:**
   ```bash
   $ cd ~/Fun/Kira && kira run examples/hello.ki
   error: undefined symbol 'std'
   ```

**Required fix in Kira (`~/Fun/Kira`):**

Option A (recommended): Add namespace type support to the type checker
1. Add `namespace_type` variant to `ResolvedType` in `types.zig`
2. Return namespace type for `std` identifier in `checker.zig`
3. Handle field access on namespace types (std.io, std.list, etc.)
4. Define type signatures for stdlib functions

Option B (simpler): Skip type checking for `std.*` expressions
1. Add special case in `checkExpression` for `std` identifier
2. Return a permissive type that allows any field access/calls

**Kira files to modify:**
- `src/typechecker/types.zig` - Add namespace type
- `src/typechecker/checker.zig` - Handle std identifier and field access

**Once Kira is fixed:** Tharn can remove all duplicated type definitions and use proper imports.

---

### Update (2026-02-09): `std` namespace bug is fixed, but imports still broken

**Tested:** The `std` namespace type checker bug (Option B) has been fixed in Kira.

```bash
$ kira run examples/hello.ki
Hello, Kira!
```

The fix in `checker.zig:409-411` skips the error for `std` and returns a permissive type:
```zig
} else if (std.mem.eql(u8, ident.name, "std")) {
    // Skip error for 'std' - it's a built-in namespace injected at runtime
    return ResolvedType.errorType(expr.span);
}
```

**However, cross-module imports are still broken.** Testing revealed a second, deeper Kira bug:

**Bug A (FIXED): Type checker rejects `std` namespace**
- Status: Fixed via Option B workaround in `checker.zig`

**Bug B (OPEN): Resolver does not register imported symbols into scope**
- Import statements are parsed without errors
- But imported names are never added to the resolver's symbol table
- All imported functions/types fail with `Undefined identifier`
- Even Kira's own `examples/geometry/main.ki` fails with 30+ undefined identifier errors
- Adding `pub` to exported symbols fixes the visibility check but symbols still aren't available

**Test results:**

1. `runtime/test.ki` (has imports without `pub`) fails with "Cannot import private symbol"
2. A test with `pub` types/functions across two modules fails with "Undefined identifier" for all imported symbols
3. `kira run examples/geometry/main.ki` also fails — confirming the resolver bug

**Conclusion:** Two Kira bugs block this issue:
1. ~~Type checker rejects `std` namespace~~ (fixed)
2. Resolver doesn't register imported symbols into scope (still open)

**Required fix in Kira (`~/Fun/Kira`):**
- The resolver needs to actually register imported symbols into the importing module's scope
- Likely in `src/resolver/resolver.zig` — the import handling code parses the statement but doesn't call something like `self.table.define(...)` for each imported symbol
- Additionally, Tharn source files need `pub` on all exported types and functions once imports work

---

### Update (2026-02-12): Compiler team handoff (minimal repro + acceptance criteria)

This section is written for Kira compiler maintainers and is independent of Tharn internals.

**Environment used for verification:**
- Date verified: 2026-02-12
- `kira --version`: `Kira Programming Language v0.11.0`
- `klar --version`: `Klar 0.4.0`

**Observed behavior summary:**
1. Import visibility checks run (private symbols are correctly rejected).
2. Even when symbols are `pub`, imported names are not resolvable in the importing module.
3. This affects imported `fn` and imported `type`.

#### Repro A: private import rejection (expected behavior)

File `a.ki`:
```kira
module a
type Thing = { x: u64 }
```

File `main.ki`:
```kira
module main
import a.{ Thing }
```

Command:
```bash
kira run main.ki
```

Expected/Actual:
- Expected: error about importing private symbol.
- Actual: compiler reports private-symbol import error (this part is correct).

#### Repro B: `pub fn` import resolves as undefined (incorrect behavior)

File `a.ki`:
```kira
module a

pub type Thing = { x: u64 }

pub fn mk(x: u64) -> Thing {
    return Thing { x: x }
}

pub fn get(t: Thing) -> u64 {
    return t.x
}
```

File `main.ki`:
```kira
module main
import a.{ Thing, mk, get }

effect fn main() -> void {
    let t: Thing = mk(7u64)
    let x: u64 = get(t)
    std.io.println("ok")
}
```

Command:
```bash
kira run main.ki
```

Actual diagnostics:
- `Undefined identifier 'mk'`
- `Undefined identifier 'get'`

Expected:
- Program should compile and run.

#### Repro C: `pub type` import resolves as undefined (incorrect behavior)

File `a.ki`:
```kira
module a
pub type Thing = { x: u64 }
```

File `main.ki`:
```kira
module main
import a.{ Thing }

effect fn main() -> void {
    let t: Thing = Thing { x: 7u64 }
    if t.x == 7u64 {
        std.io.println("type-pass")
    }
}
```

Command:
```bash
kira run main.ki
```

Actual diagnostics:
- `Undefined identifier 'Thing'`

Expected:
- Program should compile and run.

#### Likely fault location

`src/resolver/resolver.zig` import-resolution path:
- Import parsing and visibility checks appear to run.
- Imported bindings are likely not inserted into the importing module scope/symbol table.
- Suspected missing step equivalent to defining imported symbol aliases in current lexical/module scope.

#### What must be true for bug to be considered fixed

1. `import a.{ Thing, mk, get }` binds all imported names in module `main` and they resolve in expressions/type positions.
2. Visibility enforcement remains intact:
   - non-`pub` imports fail with clear private-symbol diagnostics
   - `pub` imports resolve successfully
3. Existing examples that rely on imports (for example `examples/geometry/main.ki`) compile and run.
4. Tharn can remove inlined workaround blocks from:
   - `runtime/execloop.ki`
   - `tools/fs.ki`
   - `tools/net.ki`
   - `tools/test.ki`

#### Suggested regression tests in Kira repo

Add resolver/compiler tests for:
- `import pub type` used in type annotation and value construction
- `import pub fn` used in call expression
- mixed import list (`type + fn`) from one module
- private symbol import should fail (negative test)

---
