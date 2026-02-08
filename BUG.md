# Kira Compiler Bugs (v0.11.0)

## [x] Bug 1: Type checker does not register `std` module

**Status:** Fixed

**Description:** The Kira v0.11.0 type checker has no knowledge of the `std` module. Any code referencing `std.*` passes the resolver (which has a special case for "std" in `src/symbols/resolver.zig:883`) but then fails during type checking with `undefined symbol 'std'`. This affects `kira run` and `kira check` equally. Even Kira's own bundled examples fail:

```
$ kira run ~/Fun/Kira/main/examples/hello.ki
error: undefined symbol 'std'
  --> hello.ki:4:5
   4 |     std.io.println("Hello, Kira!")
       ^
Error: error.TypeCheckError
```

**Root cause:** The resolver (`src/symbols/resolver.zig:883`) had a special case to skip `std` from undefined identifier checks, and the interpreter (`src/stdlib/root.zig`) registered `std` at runtime — but the type checker (`src/typechecker/checker.zig:402`) had no corresponding handling. It tried to look up `std` in the symbol table, failed, and emitted `undefined symbol 'std'`.

**Fix:** Added a matching special case in `src/typechecker/checker.zig` at the identifier resolution branch. When `std` is encountered, the type checker returns an error-recovery type without emitting a diagnostic. The error type propagates silently through field access and function calls (both `checkFieldAccess` and `checkFunctionCall` already handle error types), matching the resolver's skip behavior.

**Files modified:**
- `src/typechecker/checker.zig` — Added `else if (std.mem.eql(u8, ident.name, "std"))` branch to skip diagnostic for the built-in `std` namespace

---

## [ ] Bug 2: `var` bindings rejected in pure functions

**Status:** Blocked (Kira compiler behavioral change)

**Description:** Kira v0.11.0 enforces that `var` (mutable) bindings can only appear inside `effect fn` declarations. The error is: `'var' bindings are only allowed in effect functions`. This is a breaking change from the version this project was written against, where `var` was allowed in plain `fn`.

**Steps to reproduce:**
1. Create a file containing: `fn foo() -> i32 { var x: i32 = 1; return x }`
2. Run `kira check <file>`

**Expected:** Pure functions can use local mutable bindings for iteration/accumulation without side effects.

**Actual:** `error: 'var' bindings are only allowed in effect functions`

**Impact on this project:** Affects every source file. Functions that use `var` for local iteration (lexer scanning, list building, accumulation) would need to be changed to `effect fn`, which then cascades to all callers. Alternatively, these functions could be refactored to use pure recursion instead of mutation.

**Notes:** This may be intentional stricter effect tracking rather than a bug. However, the Kira docs (`~/Fun/Kira/docs/README.md`) still show `var` as usable in both `fn` and `effect fn`, suggesting the docs are out of sync with the compiler.

---

## [ ] Bug 3: Built-in conversion functions removed without migration path

**Status:** Open (unblocked by Bug 1 fix)

**Description:** The bare built-in functions `to_string()`, `to_float()`, and `to_i64()` are no longer recognized as identifiers. They were moved to namespaced modules (`std.int.to_string`, `std.float.from_int`, `std.math.trunc_to_i64`).

**Steps to reproduce:**
1. Create a file containing: `fn foo(n: i64) -> string { return to_string(n) }`
2. Run `kira check <file>`

**Expected:** `to_string` converts an integer to a string.

**Actual:** `error: Undefined identifier 'to_string'`

**Impact on this project:** Used extensively in `eval.ki`, `main.ki`, `lexer.ki`, `parser.ki`, and `types.ki` for converting numbers to strings, integers to floats, and i32 to i64. Now that Bug 1 is fixed, these can be migrated to their `std.*` replacements (`std.int.to_string`, `std.float.from_int`).
