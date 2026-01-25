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

### 6. ~~String Output Double-Escaping~~ NOT A BUG

**Status:** Investigated and found to be working correctly.

**Details:** `std.io.println` correctly outputs strings without added quotes. Testing confirms:
```kira
let json_str: String = "{\"name\": \"Alice\"}"
std.io.println(json_str)  // Output: {"name": "Alice"}
```

The original report may have confused REPL display formatting (which intentionally shows quotes for clarity) with `println` behavior.

---

### 7. ~~Cross-Module Function Calls Unreliable~~ IMPROVED

**Status:** Error handling improved in `src/main.zig` and `src/interpreter/interpreter.zig`

**Changes Made:**
- Module registration errors are now logged to stderr instead of being silently ignored
- Import processing now properly handles `AlreadyDefined` errors by updating existing bindings
- `registerModuleNamespace` now propagates `OutOfMemory` errors instead of silently failing

**Details:** Previously, errors during module export registration, namespace creation, and import processing were silently caught with `catch {}`. This made debugging cross-module issues nearly impossible. Now these operations log warnings when they fail, making issues visible.

---

## Workarounds Applied (Historical)

| Issue | Workaround Used | Status |
|-------|-----------------|--------|
| `std.string.equals` missing | Use `==` operator instead | Still applies |
| `std.float.to_string` missing | Works in current version | Fixed |
| Cross-module calls | Keep all code in single module | Improved (issue #7) |

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
