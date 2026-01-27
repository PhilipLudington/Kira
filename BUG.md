# Kira Language Bugs

Bugs and limitations discovered while implementing a Lisp interpreter in Kira.

---

## [x] Bug 1: Import Statement Causes Segfault

**Status:** Resolved - not a bug (invalid syntax)

**Original claim:** Import statements cause a segmentation fault.

**Finding:** The syntax `import types from "./types.ki"` is not valid Kira syntax. Correct import syntax is `import module.path.{ items }`. With correct syntax and proper kira.toml configuration, imports work correctly.

**Correct import example:**
```kira
// kira.toml: [modules] mymod = "mymod"
import mymod.utils.{ double }
```

---

## [x] Bug 2: to_string on Pattern-Extracted Values Shows Variant Name

**Status:** Fixed in commit (tail-call optimization bug)

**Root cause:** In the interpreter's tail-call optimization trampoline, builtin functions were called with `args` (original function parameters) instead of `current_args` (updated tail-call arguments).

**Fix:** Changed `interpreter.zig:1097` from `builtin_fn(ctx, args)` to `builtin_fn(ctx, current_args)`.

---

## [ ] Bug 3: Named Variant Fields Not Supported

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

## [ ] Bug 4: Semicolons Not Allowed as Statement Separators

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

## [ ] Bug 5: std.list.append Does Not Exist

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

## [x] Bug 6: std.string.parse_float Does Not Exist

**Status:** Fixed - added `std.string.parse_float(str) -> Option[float]`

**Usage:**
```kira
match std.string.parse_float("3.14") {
    Some(x) => { print("Parsed: " + std.string.from_float(x)) }
    None => { print("Invalid float") }
}
```

**Features:**
- Trims whitespace before parsing
- Supports negative numbers (`"-2.5"`)
- Supports scientific notation (`"1.5e10"`)
- Returns `None` for invalid input
