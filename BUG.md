# Kira Compiler Bugs (Active) - Verified 2026-02-11

This file tracks currently unresolved compiler/type-checker issues.
Fixed items are retained briefly under "Recently Fixed" for traceability.

Environment used for verification:
- Kira source tree: `/Users/mrphil/Fun/Kira`
- Project checked: `/Users/mrphil/Fun/kira-lisp`
- Compiler version: `Kira Programming Language v0.11.0`
- Verification date: 2026-02-11

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

## [ ] Bug B: `kira-lisp` still fails type-check with tuple/exhaustiveness/condition cascades

Status: open. The high-noise constructor and stdlib signature mismatches are fixed, but project type-checking still fails in remaining categories.

### Current behavior

Commands:
```sh
/Users/mrphil/Fun/Kira/zig-out/bin/kira check /Users/mrphil/Fun/kira-lisp/src/main.ki
/Users/mrphil/Fun/Kira/zig-out/bin/kira check /Users/mrphil/Fun/kira-lisp/src/eval.ki
```

Observed error families:
- `non-exhaustive match: missing patterns ...` (notably tuple/list matching paths)
- `if condition must be a boolean expression` (remaining sites)
- `for loop requires an iterable`
- `type mismatch` on tuple/number/list sites
- effect checking errors (`cannot call effect function from pure function`)

No segmentation fault reproduced in this run.

### Why this remains open

`kira check` is still not usable end-to-end for `kira-lisp`; remaining errors may include real program bugs plus checker false positives. Additional narrowing is required to separate the two.

### Suggested next investigation

1. Isolate tuple-pattern + tuple-subject flow in `match (name_list, value_list)` paths; these appear to trigger downstream cascades.
2. Investigate exhaustiveness diagnostics for tuple and list composite matches in `src/typechecker/pattern_compiler.zig`.
3. Confirm condition typing after upstream tuple/match fixes (several `if` errors appear to be secondary).
4. Re-check effect-system diagnostics in `kira-lisp` to distinguish intended strictness vs regressions.

---

## Quick Triage Priority

1. **Bug B / tuple match + binding typing** - highest impact on project checkability.
2. **Bug B / exhaustiveness false positives** - high; causes cascading noise.
3. **Bug B / remaining condition/effect diagnostics** - high; may hide true type errors.
