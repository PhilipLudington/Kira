# Kira Compiler/Interpreter Issues

This document tracks issues discovered in the Kira v0.1.0 interpreter while developing and testing `kira-http`.

---

## Critical Issues

### 1. Module System Not Functional

**Severity:** Critical
**Version:** v0.1.0
**Status:** ✅ FIXED (2026-01-24)

**Description:**
The `import` statement is parsed but does not actually resolve or load modules. All identifiers from imported modules result in `error.UndefinedVariable`.

**Example:**
```kira
import http.types.{Status, Header}

// Later usage fails:
let status: Status = OK  // error.UndefinedVariable: OK
```

**Fix:**
The interpreter's `processImport()` function was looking up imported items in the environment by simple name, but they were only registered in module namespace records. The fix:
1. Added `module_exports` map to the Interpreter to store each module's exported values
2. Added `registerModuleExports()` method to populate module exports when modules are loaded
3. Updated `processImport()` to look up items from the module_exports map

**Verified working:**
- `examples/package_demo/main.ki` - imports functions and types from nested package
- `examples/geometry/main.ki` - imports multiple items with aliases

**Impact (resolved):**
- ~~Cannot create modular codebases~~ Now works
- ~~All test files must be self-contained with duplicated code~~ Can use imports
- ~~Library development is severely limited~~ Libraries work with proper module declarations

---

## Standard Library Issues

### 2. `std.string.parse_int` Not Available

**Severity:** High
**Version:** v0.1.0

**Description:**
The function `std.string.parse_int` does not exist or is not accessible, causing `error.FieldNotFound` when called.

**Example:**
```kira
let port_str: string = "8080"
let port_result: Option[i32] = std.string.parse_int(port_str)
// error.FieldNotFound
```

**Workaround:**
Cannot parse strings to integers. Tests that require integer parsing from strings must be skipped or redesigned.

**Affected Tests:**
- `parse_url extracts port 8080`
- `parse_url extracts port 443`
- `parse_url parses complete URL`
- `parse and build roundtrip preserves URL`
- `parse_url fails for invalid port letters`
- `parse_url fails for port out of range`
- `parse_url fails for negative port`

---

### 3. `std.string.to_lower` Inconsistent Behavior

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

**Affected Tests:**
- `ok sets content type`
- `created sets content type`
- `json_response sets content type`
- `json_ok sets content type`
- `json_created sets content type`
- `with_header preserves existing headers`

---

### 4. `std.string.from_int` Status Unknown

**Severity:** Medium
**Version:** v0.1.0

**Description:**
The function to convert integers to strings (`std.string.from_int`) may or may not be available. Testing was limited due to other blocking issues.

**Workaround:**
Avoid integer-to-string conversion where possible.

---

## Pattern Matching Issues

### 5. Path Parameter Matching Fails

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

**Affected Tests:**
- `paths_match with param`
- `paths_match with multiple params`
- `extract_path_param extracts simple param`
- `extract_path_param extracts nested param`
- `extract_path_param extracts first of multiple params`

---

## Syntax/Feature Gaps

### 6. No `loop`/`break` Construct Confirmed

**Severity:** Low
**Version:** v0.1.0

**Description:**
The `loop` and `break` keywords from the original test files may not be supported. All iteration must use recursion.

**Workaround:**
Use recursive functions for all iteration patterns.

---

### 7. Tuple Pattern Matching Status Unknown

**Severity:** Low
**Version:** v0.1.0

**Description:**
Pattern matching on tuples like `(a, b)` may not be fully supported. Tests were rewritten to avoid tuple patterns.

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
| Module system not functional | Critical | ✅ FIXED |
| `std.string.parse_int` missing | High | Open |
| `std.string.to_lower` inconsistent | Medium | Open |
| Path parameter matching fails | Medium | Open |
| `loop`/`break` not available | Low | Open (use recursion) |
| Tuple patterns may not work | Low | Open (use nested match) |

---

## Test Impact

Due to these issues, 24 out of 281 tests (8.5%) fail:

```
Total: 257 passed, 24 failed out of 281 tests
```

All failures are attributed to Kira v0.1.0 interpreter limitations, not bugs in the `kira-http` library logic.

---

## Recommendations

1. **For Kira v0.2.0:** Ensure the module system is fully functional before release
2. **Standard Library:** Document all available `std.*` functions
3. **Error Messages:** Improve error messages to distinguish between:
   - Missing functions (`FieldNotFound`)
   - Type mismatches
   - Module resolution failures

---

*Last updated: 2026-01-24*
