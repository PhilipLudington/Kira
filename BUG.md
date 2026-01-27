# Kira Language Bugs

Bugs encountered in the Kira language while developing the Lisp interpreter.

---

## [x] Bug 1: `for` loop on empty `List[RecursiveType]` crashes

**Status:** Fixed (commit 85e0cca)

**Description:** When using a `for` loop to iterate over an empty list where the element type is a recursive sum type (like `LispValue` or `IRExpr`), Kira threw a `TypeMismatch` runtime error.

**Root cause:** In `evalForLoop()` at `src/interpreter/interpreter.zig:1612`, the switch statement on the iterable was missing a `.nil` case. Empty lists fell through to the `else` branch which returned `error.TypeMismatch`.

**Fix:** Added `.nil` case to handle empty lists (iterates zero times):
```zig
.nil => {
    // Empty list - nothing to iterate
},
```

---

## [x] Bug 2: HashMap `any` type doesn't round-trip for recursive types

**Status:** Fixed (verified 2026-01-27)

**Description:** When storing a `List[LispValue]` (or other recursive sum type) in a `HashMap` and retrieving it, pattern matching on the retrieved value was reported to fail with `TypeMismatch`.

**Investigation:** Testing confirms this bug no longer reproduces. The HashMap correctly preserves full type information through the `Value` tagged union. Pattern matching on retrieved values works correctly, including nested matches on `List[RecursiveType]`.

**Likely fix:** The iterative Cons handling added in commit `60f1274` may have fixed issues with pattern matching on deeply nested recursive types.

---

## [x] Bug 3: Pattern match extraction of `List[RecursiveType]` fails on subsequent match

**Status:** Fixed (verified 2026-01-27)

**Description:** When extracting a `List[LispValue]` from a pattern match (e.g., matching `LispList(items)`), attempting to pattern match on the extracted `items` variable was reported to fail.

**Investigation:** Testing confirms this bug no longer reproduces. Nested pattern matching works correctly, including:
- Extracting `List[LispValue]` from a variant like `LispList(items)`
- Pattern matching on the extracted `items` with `Cons`/`Nil`
- Further nested matches on the head/tail of the list

**Likely fix:** The iterative Cons handling added in commit `60f1274` replaced recursive pattern matching with an iterative implementation, fixing issues with deeply nested patterns on recursive types.

---

## [x] Bug 4: `if` is a statement, not an expression

**Status:** Workaround in place

**Description:** Kira's `if` statement doesn't return a value, making it impossible to use in expression contexts.

**Workaround:** Use immediately-invoked function expressions (IIFE) with `match`:
```kira
let result: i32 = (fn() -> i32 {
    match condition {
        true => { return 1 }
        false => { return 0 }
    }
})()
```

---

## [x] Bug 5: No command-line argument support

**Status:** Workaround in place

**Description:** Kira doesn't have `std.env.args()` or similar functionality to access command-line arguments.

**Workaround:** ~~Modify source code to switch between modes (REPL, run file, compile).~~

**Fix:** Kira now supports `std.env.args()` which returns `List[string]`. The interpreter uses this for CLI mode selection.

---
