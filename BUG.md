# Kira Language Limitations Affecting Production Readiness

This document lists Kira interpreter/stdlib bugs and missing features that prevent the JSON library from being fully production-ready.

## Resolved Issues

### 1. ~~Missing `std.math.trunc_to_i64`~~ FIXED

**Status:** Implemented in `src/stdlib/math.zig`

**Usage:** `std.math.trunc_to_i64(float_value)` - Truncates float to integer (towards zero).

---

### 2. ~~Missing `std.char.from_i32`~~ FIXED

**Status:** Implemented in `src/stdlib/char.zig`

**Usage:** `std.char.from_i32(code_point)` - Returns `Option[Char]`. Returns `None` for invalid Unicode code points.

---

### 3. ~~Missing `std.char.to_i32`~~ FIXED

**Status:** Implemented in `src/stdlib/char.zig`

**Usage:** `std.char.to_i32(char)` - Returns the integer code point of a character.

---

### 4. ~~Segmentation Fault on Exit~~ FIXED

**Status:** Fixed by making `Symbol.deinit()` a no-op in `src/symbols/symbol.zig`

**Details:** Memory is now managed entirely by the arena allocator. Debug builds may show "leaked" warnings from GPA, but the program exits cleanly without segfault.

---

### 5. ~~Multi-line Cons Parsing Fails~~ FIXED

**Status:** Fixed by adding `skipNewlines()` calls in `parseArguments()` in `src/parser/parser.zig`

**Usage:** Multi-line function arguments now work correctly:
```kira
let list: List[Int] = std.list.cons(
    1,
    std.list.cons(2, empty)
)
```

---

## Non-Blocking Issues

### 6. String Output Double-Escaping

**Impact:** `std.io.println` wraps strings in quotes, making JSON output harder to read.

**Example:**
```
Input:  {"name": "Alice"}
Output: "{\"name\": \"Alice\"}"
```

**Status:** Needs further investigation.

---

### 7. Cross-Module Function Calls Unreliable

**Impact:** Imported functions sometimes produce `FieldNotFound` at runtime despite correct `pub` exports.

**Workaround:** The library is structured as a single module to avoid this issue.

**Status:** Needs further investigation with a reproducible test case.

---

## Workarounds Applied

| Issue | Workaround Used |
|-------|-----------------|
| `std.string.equals` missing | Use `==` operator instead |
| `std.float.to_string` missing | Works in current version (was fixed) |
| Cross-module calls | Keep all code in single module |

---

## Feature Requests

These are not bugs but would improve the library:

1. **Hash map type** — Would improve object field lookup from O(n) to O(1)
2. **String builder** — Would improve serialization performance
3. **Character iteration** — `std.string.chars(s) -> List[char]` would simplify parsing

---

## References

- Full issue details: `docs/kira-interpreter-issues.md`
- JSON library: `src/json.ki`
- Test suite: `tests/test_json.ki`
