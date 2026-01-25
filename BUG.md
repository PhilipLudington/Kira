# Kira Compiler/Interpreter Issues

This document tracks issues discovered in the Kira interpreter while developing and testing `kira-http`.

---

## Open Issues

*No open issues.*

---

## Summary

All known issues have been resolved.

---

## Resolved Issues

### `while` and `loop` Constructs Added

**Severity:** Low
**Fixed:** 2026-01-25

**Original Description:**
The `while` and `loop` keywords were not supported. All iteration required recursion or `for` loops.

**Resolution:**
Added `while` and `loop` constructs to the language:

**while loop** - conditional iteration:
```kira
effect fn example() -> () {
    var i: int = 0
    while i < 5 {
        std.io.println(std.string.from_int(i))
        i = i + 1
    }
}
```

**loop** - infinite loop (exit via `break` or `return`):
```kira
fn example() -> () {
    loop {
        std.io.println("iteration")
        break
    }
}
```

**Files modified:**
- `src/lexer/token.zig` - Added `while_keyword` and `loop_keyword` tokens
- `src/ast/statement.zig` - Added `WhileLoop` and `LoopStatement` AST nodes
- `src/parser/parser.zig` - Added parsing functions
- `src/interpreter/interpreter.zig` - Added evaluation functions
- `src/symbols/resolver.zig` - Added resolution handling
- `src/typechecker/checker.zig` - Added type checking
- `src/ast/pretty_printer.zig` - Added pretty printing

---

### Tuple Pattern Matching (MISDIAGNOSIS)

**Severity:** Low
**Fixed:** 2026-01-24

**Original Description:**
Pattern matching on tuples like `(a, b)` was reported as potentially unsupported.

**Resolution:**
Tuple pattern matching is fully functional. All tested cases work:
- Basic patterns: `(a, b)`
- Literal matching: `(1, b)`
- Nested Option types: `(Some(a), Some(b))`
- Mixed patterns: `(Some(a), None)`
- Direct construction: `match (x, y) { ... }`
- 3-tuples: `(a, b, c)`
- Nested tuples: `((a, b), c)`

**Usage:**
```kira
let opt1: Option[int] = Some(10)
let opt2: Option[int] = Some(20)
match (opt1, opt2) {
    (Some(a), Some(b)) => { std.io.println("both some") }
    (Some(a), None) => { std.io.println("first only") }
    (None, Some(b)) => { std.io.println("second only") }
    (None, None) => { std.io.println("neither") }
}
```

---

### `std.string.from_int` Works

**Severity:** Medium
**Fixed:** 2026-01-24

**Description:**
The function was previously marked as "status unknown" due to other blocking issues during testing.

**Resolution:**
Tested and confirmed working. Converts an integer to its string representation.

**Usage:**
```kira
let x: int = 42
let s: string = std.string.from_int(x)
std.io.println(s)  // prints "42"
```

---

### Path Parameter Matching Fails (MISDIAGNOSIS)

**Severity:** Medium
**Fixed:** 2026-01-24

**Original Description:**
Pattern matching for URL path parameters (`:param` syntax) fails in some cases. The test `paths_match("/users/:id", "/users/123")` returns `false` when it should return `true`.

**Root Cause:**
This was NOT a Kira interpreter bug. The issue was in the `kira-http` test file (`tests/test_router.ki`), which incorrectly compared the result of `std.string.char_at()` with a character literal:

```kira
// WRONG - char_at returns Option[char], not char
if std.string.char_at(pattern_seg, 0) == ':' { ... }
```

Since `char_at` returns `Option[char]`, this compares `Some(':')` with `':'`, which is always `false`.

**Fix Options:**

1. Use `starts_with` (recommended, matches main `router.ki` implementation):
```kira
if std.string.starts_with(pattern_seg, ":") { ... }
```

2. Pattern match the Option result:
```kira
let is_param: bool = match std.string.char_at(pattern_seg, 0) {
    Some(c) => { c == ':' }
    None => { false }
}
```

**Note:** The main `router.ki` implementation correctly uses `std.string.starts_with()` and works properly. Only the test file had the bug.

**Location:** Fix needed in `kira-http/tests/test_router.ki`, line 166.

---

### `std.string.to_lower` Inconsistent Behavior (MISDIAGNOSIS)

**Severity:** Medium
**Fixed:** 2026-01-24

**Original Description:**
The function `std.string.to_lower` sometimes causes `error.FieldNotFound` depending on context.

**Root Cause:**
This was a misdiagnosis. The actual issue was that `std.list.head` was not implemented. Users calling `std.list.head(list)` would get `error.FieldNotFound`, and if that code was near `to_lower` calls, it would appear that `to_lower` was the problem.

**Actual Fix:**
Added `std.list.head` and `std.list.tail` functions (see below).

**Note:** `std.string.to_lower` works correctly in all contexts.

---

### `std.list.head` and `std.list.tail` Missing

**Severity:** High
**Fixed:** 2026-01-24

**Description:**
The `std.list` module was missing `head` and `tail` accessor functions, causing `error.FieldNotFound` when trying to access the first element or rest of a list.

**Root Cause:**
The functions were never implemented in the standard library.

**Fix:**
Added `head` and `tail` functions to `src/stdlib/list.zig`:
- `head(list)` - Returns `Option[T]`: `Some(first_element)` if non-empty, `None` if empty
- `tail(list)` - Returns `Option[List[T]]`: `Some(rest)` if non-empty, `None` if empty

**Usage:**
```kira
let list: List[int] = std.list.cons(1, std.list.cons(2, std.list.empty()))

// Get first element
match std.list.head(list) {
    Some(first) => { std.io.println("First: " + to_string(first)) }
    None => { std.io.println("Empty list") }
}

// Get rest of list
match std.list.tail(list) {
    Some(rest) => { /* process rest */ }
    None => { /* list had only one element or was empty */ }
}
```

---

### Improved Error Messages for `FieldNotFound`

**Fixed:** 2026-01-24

**Description:**
Error messages for `FieldNotFound` were previously just "Runtime error: error.FieldNotFound" with no context about which field or method was missing.

**Fix:**
Added error context to the interpreter that shows:
- Which field/method was not found
- Which module/record it was looked up in

**Example:**
```
Before: Runtime error: error.FieldNotFound

After:  Runtime error: error.FieldNotFound
          method 'nonexistent' not found in 'std.list'
```

---

### `std.string.parse_int` Missing

**Severity:** High
**Fixed:** 2026-01-24

**Description:**
The function `std.string.parse_int` did not exist, causing `error.FieldNotFound` when called.

**Root Cause:**
The function was simply not implemented in the standard library.

**Fix:**
Added `parse_int` function to `src/stdlib/string.zig` that:
1. Takes a string argument
2. Trims whitespace
3. Parses the string as a base-10 integer
4. Returns `Option[int]` - `Some(value)` on success, `None` on parse failure

**Usage:**
```kira
let port_str: string = "8080"
let port_result: Option[int] = std.string.parse_int(port_str)
match port_result {
    Some(port) => { /* use port */ }
    None => { /* handle parse error */ }
}
```

---

### Module System Import Resolution

**Severity:** Critical
**Fixed:** 2026-01-24

**Description:**
The `import` statement was parsed but imported identifiers caused `error.UndefinedVariable` at runtime.

**Root Cause:**
The interpreter's `processImport()` function looked up imported items by simple name in the environment, but they were only stored in module namespace records.

**Fix:**
1. Added `module_exports` map to the Interpreter to store each module's exported values
2. Added `registerModuleExports()` method to populate module exports when modules are loaded
3. Updated `processImport()` to look up items from the module_exports map

**Commit:** `364fbbe Fix module system import resolution`

---

## Recommendations

1. **Standard Library:** Document all available `std.*` functions
2. ~~**Error Messages:** Improve error messages to distinguish between missing functions, type mismatches, and module resolution failures~~ ✅ Done

---

*Last updated: 2026-01-25*
*Added: while and loop constructs to the language*
