# Kira Language Bugs Encountered

These are bugs in the Kira programming language that were encountered while implementing the Lisp interpreter and compiler.

**Last verified:** 2026-01-27

---

## [x] Bug 1: `for` loop crashes on empty `List[RecursiveType]`

**Status:** Fixed

**Description:** When using a `for` loop to iterate over an empty list where the element type is a recursive sum type (like `LispValue` or `IRExpr`), Kira throws a `TypeMismatch` runtime error.

---

## [x] Bug 2: `if` is a statement, not an expression

**Status:** Fixed

**Description:** Kira's `if` construct is a statement and does not return a value. Now fixed - `if` works as an expression.

---

## [x] Bug 3: No command-line argument support

**Status:** Fixed

**Description:** Kira now provides `std.env.args()` to access command-line arguments.

---

## [x] Bug 4: Multi-line string literals not supported

**Status:** Fixed

**Description:** Kira now supports multi-line string literals.

---

## [x] Bug 5: `std.env.args()` returns list that doesn't support pattern matching

**Status:** Fixed

**Description:** The list returned by `std.env.args()` works with `for` loops but fails with pattern matching on `Cons`/`Nil`. The error was `MatchFailed`.

**Root cause:** `std.env.args()` was returning a `.array` value type instead of a proper linked list with `.cons`/`.nil` tags. Pattern matching only handles `.cons`/`.nil`, while `for` loops handle both `.array` and `.cons`/`.nil`.

**Fix:** Modified `src/stdlib/env.zig` to build a proper `Cons`/`Nil` linked list instead of returning an array.
