# Kira Compiler Bugs (Active) - Verified 2026-02-12

This file tracks currently unresolved compiler/type-checker issues.
Fixed items are retained briefly under "Recently Fixed" for traceability.

Environment used for verification:
- Kira source tree: `/Users/mrphil/Fun/Kira`
- Project checked: `/Users/mrphil/Fun/kira-lisp`
- Compiler version: `Kira Programming Language v0.11.0`
- Verification date: 2026-02-12

---

## Recently Fixed (2026-02-11)

### [x] Fix A1: `Cons(head, tail)` pattern arity for `List[T]`

Status: fixed in local build (`/Users/mrphil/Fun/Kira/zig-out/bin/kira`).

Repro file:
```ki
fn head(xs: List[i32]) -> i32 {
    match xs {
        Cons(h, t) => { return h }
        Nil => { return 0 }
    }
}
```

Command:
```sh
./zig-out/bin/kira check /tmp/kira_bug4_cons.ki
```

Actual now:
```text
Check passed: /tmp/kira_bug4_cons.ki
```

---

### [x] Fix A2: `std.map.contains(...)` typed as `bool`

Status: fixed in local build (`/Users/mrphil/Fun/Kira/zig-out/bin/kira`).

Repro file:
```ki
fn has_key(m: HashMap, k: string) -> bool {
    if std.map.contains(m, k) {
        return true
    }
    return false
}
```

Command:
```sh
./zig-out/bin/kira check /tmp/kira_bug4_mapbool.ki
```

Actual now:
```text
Check passed: /tmp/kira_bug4_mapbool.ki
```

---

### [x] Fix A3: `Cons(1, Nil)` no longer degrades to `List[error]`

Status: fixed in local build; regression test added in `src/typechecker/checker.zig`.

Command:
```sh
./zig-out/bin/kira check /tmp/repro_cons_nil_poly.ki
```

Actual now:
```text
error: type mismatch: expected 'List[string]', found 'List[i32]'
```

This confirms `Cons(1, Nil)` preserves head-driven element typing.

---

### [x] Fix A4: stdlib signature alignment for `std.string`/`std.map`/`std.fs` in checker

Status: fixed in local build (`/Users/mrphil/Fun/Kira/zig-out/bin/kira`).

Implemented checker-side signature updates for:
- `std.string.substring -> Option[string]` (was treated as `string`)
- `std.string.parse_int -> Option[i64]`
- `std.string.parse_float -> Option[f64]`
- `std.string.starts_with/ends_with/contains -> bool`
- `std.string.chars -> List[char]`
- `std.string.index_of -> Option[i64]`
- `std.map.get -> Option[...]` (placeholder inner type)
- `std.fs.write_file/remove/append_file -> Result[void, string]`
- `std.fs.exists/is_file/is_dir -> bool`

Project impact:
- Removed initial `variant not found in matched type`/`Some`/`None` false positives triggered by mismatched stdlib return typing.
- Reduced `kira-lisp` error count significantly, especially in `src/eval.ki`.

---

### [x] Fix A5: tuple constructor-product exhaustiveness in pattern compiler

Status: fixed in local build (`/Users/mrphil/Fun/Kira/zig-out/bin/kira`).

Issue addressed:
- Tuple matches over finite constructor domains (e.g. `(List[T], List[U])` with `Nil/Cons` combinations)
  were incorrectly reported as non-exhaustive unless a wildcard arm was present.

Fix:
- `src/typechecker/pattern_compiler.zig` now performs finite constructor-product coverage for tuple elements
  (List top-level `Cons/Nil`, Option `Some/None`, Result `Ok/Err`, and finite sum types).
- Added regression test: `tuple exhaustiveness with finite constructors`.

Project impact:
- Removed false positives like:
  - `non-exhaustive match: missing patterns for _ or (_, ...) tuple pattern`
    at `kira-lisp/src/eval.ki:96`.

---

### [x] Fix A6: for-loop binding propagation + expression-block arm typing

Status: fixed in local build (`/Users/mrphil/Fun/Kira/zig-out/bin/kira`).

Issues addressed:
- For-loops dropped iterable element types when creating pattern bindings, causing loop-bound vars
  to degrade to inferred/error placeholders and triggering false
  `if condition must be a boolean expression`.
- `match`/`if` expression block arms were always typed as `void`, causing downstream
  `expected ... found 'void'` mismatches.

Fix:
- `src/typechecker/checker.zig` now passes inferred iterable element type into
  `addPatternBindings` for `for` loops.
- Added `checkBlockExpressionType` and used it for `match`/`if` expression block arms,
  typing them from the tail expression statement when present.
- Added regression test: `match expression block arm uses tail expression type`.

Project impact:
- `/Users/mrphil/Fun/kira-lisp/src/eval.ki` now type-checks successfully.
- Removed prior `void`-typed match-expression cascades in `/Users/mrphil/Fun/kira-lisp/src/main.ki`.

---

### [x] Fix A7: integer-width checker regressions in stdlib + binary operators

Status: fixed in local build (`/Users/mrphil/Fun/Kira/zig-out/bin/kira`).

Issues addressed:
- Checker typed `std.string.length`, `std.list.length`, and `std.char.to_i32` as `i32`, while project code consumed them as `i64`.
- Binary operators required exact primitive equality for comparisons/equality, causing false errors on mixed integer widths (e.g., `i64 > i32`).

Fix:
- Updated checker stdlib signatures:
  - `std.string.length -> i64`
  - `std.list.length -> i64`
  - `std.char.to_i32 -> i64`
- Added mixed-integer compatibility in binary type checking for:
  - arithmetic result typing (integer promotion)
  - comparison operators
  - equality operators
- Added regression tests in `src/typechecker/checker.zig`:
  - `stdlib: std.string.length returns i64`
  - `stdlib: std.char.to_i32 returns i64`
  - `binary comparison allows mixed integer widths`

Verification:
```sh
zig build test
zig build
/Users/mrphil/Fun/Kira/zig-out/bin/kira check /Users/mrphil/Fun/kira-lisp/src/eval.ki
/Users/mrphil/Fun/Kira/zig-out/bin/kira check /Users/mrphil/Fun/kira-lisp/src/main.ki
```

Current outcomes:
- `eval.ki` -> **passes**
- `main.ki` -> now fails only with:
  - `non-exhaustive match: missing patterns for LispRecursiveLambda`
  - `cannot call effect function from pure function`

These remaining diagnostics are currently consistent with source-level semantics, not reproduced checker regressions.
