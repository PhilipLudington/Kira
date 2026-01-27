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

## [x] Bug 5: std.list.append Does Not Exist

**Status:** Fixed - added `std.list.append(list, elem) -> list`

**Usage:**
```kira
let lst: List[i32] = Cons(1, Cons(2, Nil))
let result: List[i32] = std.list.append(lst, 3)
// result is [1, 2, 3]
```

**Note:** This is an O(n) operation since it must traverse the entire list. For frequent appends, consider building lists with `Cons` (prepend) and reversing at the end.

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
