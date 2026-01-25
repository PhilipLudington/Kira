# Kira Compiler/Interpreter Issues

This document tracks issues discovered in the Kira interpreter while developing and testing `kira-http`.

---

## Open Issues

### 1. `std.string.to_lower` Inconsistent Behavior

**Severity:** Medium
**Version:** v0.1.0

**Description:**
The function `std.string.to_lower` sometimes causes `error.FieldNotFound` depending on context. It appears to work in some files but not others, possibly related to how the function is called or the surrounding code structure.

**Example:**
```kira
let name: string = "Content-Type"
let lower: string = std.string.to_lower(name)  // Sometimes fails with error.FieldNotFound
```

**Workaround:**
Avoid case-insensitive comparisons, or use direct string equality where possible.

---

### 2. `std.string.from_int` Status Unknown

**Severity:** Medium
**Version:** v0.1.0

**Description:**
The function to convert integers to strings (`std.string.from_int`) may or may not be available. Testing was limited due to other blocking issues.

**Workaround:**
Avoid integer-to-string conversion where possible.

---

### 3. Path Parameter Matching Fails

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

### 4. No `loop`/`break` Construct

**Severity:** Low
**Version:** v0.1.0

**Description:**
The `loop` and `break` keywords are not supported. All iteration must use recursion or `for` loops.

**Workaround:**
Use recursive functions for infinite loop patterns.

---

### 5. Tuple Pattern Matching Limited

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
| `std.string.to_lower` inconsistent | Medium | Open |
| `std.string.from_int` unknown | Medium | Open |
| Path parameter matching fails | Medium | Open |
| `loop`/`break` not available | Low | Use recursion |
| Tuple patterns limited | Low | Use nested match |

---

## Resolved Issues

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
2. **Error Messages:** Improve error messages to distinguish between:
   - Missing functions (`FieldNotFound`)
   - Type mismatches
   - Module resolution failures

---

*Last updated: 2026-01-24*
*Added: std.string.parse_int implementation*
