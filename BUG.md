# Kira Compiler/Interpreter Issues

This document tracks issues discovered in the Kira interpreter while developing and testing `kira-http`.

---

## Open Issues

### 1. `std.string.from_int` Status Unknown

**Severity:** Medium
**Version:** v0.1.0

**Description:**
The function to convert integers to strings (`std.string.from_int`) may or may not be available. Testing was limited due to other blocking issues.

**Workaround:**
Avoid integer-to-string conversion where possible.

---

### 2. Path Parameter Matching Fails

**Severity:** Medium
**Version:** v0.1.0

**Description:**
Pattern matching for URL path parameters (`:param` syntax) fails in some cases even when the implementation appears correct. The `std.string.char_at` function works, but the overall matching logic fails assertion tests.

**Example:**
```kira
// This should return true but returns false:
paths_match("/users/:id", "/users/123")
```

**Investigation Notes:**
- `split_path` function works correctly (verified by unit tests)
- `segments_match` recursive function appears correct
- Issue may be related to how character comparison or string operations work

---

### 3. No `loop`/`break` Construct

**Severity:** Low
**Version:** v0.1.0

**Description:**
The `loop` and `break` keywords are not supported. All iteration must use recursion or `for` loops.

**Workaround:**
Use recursive functions for infinite loop patterns.

---

### 4. Tuple Pattern Matching Limited

**Severity:** Low
**Version:** v0.1.0

**Description:**
Pattern matching on tuples like `(a, b)` may not be fully supported.

**Example:**
```kira
// May not work:
match (opt1, opt2) {
    (Some(a), Some(b)) => { ... }
    _ => { ... }
}
```

**Workaround:**
Use nested match statements instead of tuple patterns.

---

## Summary

| Issue | Severity | Status |
|-------|----------|--------|
| `std.string.from_int` unknown | Medium | Open |
| Path parameter matching fails | Medium | Open |
| `loop`/`break` not available | Low | Use recursion |
| Tuple patterns limited | Low | Use nested match |

---

## Resolved Issues

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

*Last updated: 2026-01-24*
*Added: std.list.head and std.list.tail implementation, improved error messages*
