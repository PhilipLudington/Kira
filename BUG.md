# Kira Language Bugs and Limitations

Bugs and limitations discovered while implementing a Lisp interpreter in Kira.

---

## Fixed Bugs

### ~~1. Import Statement Causes Segfault~~ (RESOLVED)

**Status:** Not reproducible - the original report used invalid syntax.

**Original claim:** Import statements cause a segmentation fault.

**Finding:** The syntax `import types from "./types.ki"` is not valid Kira syntax. Correct import syntax is `import module.path.{ items }`. With correct syntax and proper kira.toml configuration, imports work correctly.

**Correct import example:**
```kira
// kira.toml: [modules] mymod = "mymod"
import mymod.utils.{ double }
```

---

### ~~2. `to_string` on Pattern-Extracted Values Shows Variant Name~~ (FIXED)

**Status:** Fixed in commit (tail-call optimization bug)

**Root cause:** In the interpreter's tail-call optimization trampoline, builtin functions were called with `args` (original function parameters) instead of `current_args` (updated tail-call arguments).

**Fix:** Changed `interpreter.zig:1097` from `builtin_fn(ctx, args)` to `builtin_fn(ctx, current_args)`.

---

## Limitations

### 3. Named Variant Fields Not Supported

**Severity:** Low (design limitation)

**Description:** Sum type variants cannot have named fields, only positional fields.

**What doesn't work:**
```kira
type LispLambda = | Lambda(params: List[string], body: LispValue, env: Env)
```

**What works:**
```kira
type LispLambda = | Lambda(List[string], LispValue, Env)
```

**Impact:** Reduces code readability when variants have multiple fields of the same type.

---

### 4. Semicolons Not Allowed as Statement Separators in Blocks

**Severity:** Low (design choice)

**Description:** Cannot use semicolons to separate multiple statements on the same line within blocks.

**What doesn't work:**
```kira
{ x = 1; y = 2; return x + y }
```

**What works:**
```kira
{
    x = 1
    y = 2
    return x + y
}
```

---

## Standard Library Issues

### 5. `std.list.append` Does Not Exist

**Severity:** Medium (missing functionality)

**Description:** There is no function to append an element to the end of a list.

**Workaround:** Use `Cons` to prepend, then reverse:
```kira
fn list_append[T](lst: List[T], item: T) -> List[T] {
    return std.list.reverse(Cons(item, std.list.reverse(lst)))
}
```

**Impact:** O(n) operation for what should be a common list operation. Consider adding `append` or documenting that lists are head-oriented.

---

### 6. `std.string.parse_float` Does Not Exist

**Severity:** Medium (missing functionality)

**Description:** There is no standard library function to parse a string into a floating-point number.

**Available:** `std.string.parse_int` exists and works.

**Impact:** Cannot parse float literals from user input without implementing custom parsing.

---

## Summary Table

| # | Issue | Type | Severity | Status |
|---|-------|------|----------|--------|
| 1 | Import segfault | Bug | ~~Critical~~ | RESOLVED (invalid syntax) |
| 2 | to_string shows variant name | Bug | ~~Medium~~ | FIXED |
| 3 | No named variant fields | Limitation | Low | Open |
| 4 | No semicolon separators | Limitation | Low | Open |
| 5 | No list append | Stdlib | Medium | Open |
| 6 | No parse_float | Stdlib | Medium | Open |

---

## Environment

- **Kira version:** `/usr/local/bin/kira`
- **Platform:** macOS (Darwin 24.6.0)
- **Date discovered:** 2026-01-26
- **Date updated:** 2026-01-26
