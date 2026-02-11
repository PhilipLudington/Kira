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

## [ ] Bug B: `kira-lisp` still fails type-check with remaining checker instability

Status: open. The two high-noise `Cons`/`std.map.contains` issues are fixed, but project type-checking still fails on other categories.

### Current behavior

Commands:
```sh
/Users/mrphil/Fun/Kira/zig-out/bin/kira check /Users/mrphil/Fun/kira-lisp/src/main.ki
/Users/mrphil/Fun/Kira/zig-out/bin/kira check /Users/mrphil/Fun/kira-lisp/src/eval.ki
```

Observed error families:
- `variant not found in matched type`
- `non-exhaustive match: missing patterns ...`
- `if condition must be a boolean expression` (remaining sites)
- `for loop requires an iterable`
- `type mismatch` on tuple/number/list sites
- effect checking errors (`cannot call effect function from pure function`)

No segmentation fault reproduced in this run.

### Why this remains open

`kira check` is still not usable end-to-end for `kira-lisp`; remaining errors may include real program bugs plus checker false positives. Additional narrowing is required to separate the two.

### Suggested next investigation

1. Isolate first `variant not found in matched type` in `kira-lisp` and minimize.
2. Investigate exhaustiveness diagnostics after constructor fixes to ensure no stale pattern-space assumptions.
3. Audit remaining stdlib bool-return APIs used in `if` conditions beyond `std.map.contains`.
4. Re-check effect-system diagnostics in `kira-lisp` to distinguish intended strictness vs regressions.

---

## Quick Triage Priority

1. **Bug B / variant resolution in matches** - highest impact on project checkability.
2. **Bug B / exhaustiveness false positives** - high; causes cascading noise.
3. **Bug B / remaining condition/effect diagnostics** - high; may hide true type errors.
