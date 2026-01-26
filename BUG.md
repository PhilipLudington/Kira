# Kira Language Bugs, Limitations & Feature Requests

Issues discovered while developing the kira-json library.

---

## Bugs

### ~~1. Multi-byte Unicode String Indexing Bug~~ (FIXED)

**Status:** Fixed (2026-01-25)

**Severity:** High

**Description:** When parsing JSON strings containing raw multi-byte Unicode characters (emoji, CJK, Arabic, etc.), the parser crashed with "index out of bounds" errors. The indexing treated multi-byte UTF-8 characters as single bytes.

**Fix:** Updated all string operations to use `std.unicode.Utf8View` for proper codepoint iteration:
- `interpreter.zig`: `evalIndexAccess` now iterates by codepoint
- `interpreter.zig`: `evalForLoop` now iterates by codepoint for strings
- `string.zig`: `stringLength` returns codepoint count (not byte count)
- `string.zig`: `stringCharAt` returns nth codepoint (not nth byte)
- `string.zig`: `stringSubstring` uses codepoint indices
- `string.zig`: `stringIndexOf` returns codepoint index

**Verification:**
```kira
std.string.length("🎉")           // Returns 1 (was 4)
std.string.length("世界")         // Returns 2 (was 6)
"a🎉b"[1]                         // Returns '🎉' (was invalid byte)
std.string.substring("Hello, 世界!", 7, 9)  // Returns "世界"
```

---

## Limitations

### ~~1. Recursive Interpreter Causes Stack Overflow~~ (PARTIALLY FIXED)

**Status:** Partially fixed (2026-01-25)

**Severity:** Medium → Low

**Description:** The Kira interpreter previously used recursive evaluation which caused stack overflow when processing deeply recursive operations.

**Fixes applied:**
1. **Recursion depth tracking**: The interpreter now tracks call depth and returns a clean `StackOverflow` error at 1000 depth instead of crashing.
2. **Iterative Cons pattern matching**: List pattern matching (`Cons(h, t)` patterns) now uses iterative traversal instead of recursion, allowing pattern matching on arbitrarily large lists.
3. **Iterative Cons binding**: List destructuring in let bindings also uses iterative traversal.

**Current limits:**
- User recursive functions are limited to ~1000 call depth (configurable via `max_recursion_depth`)
- Lists can now be pattern-matched regardless of size (fixed)
- External parsers may still have their own recursion limits

**What's fixed:**
```kira
// This now works - iterative pattern matching
fn sum_list(lst: List[i64]) -> i64 {
    match lst {
        Nil => { return 0 }
        Cons(h, t) => { return h + sum_list(t) }
    }
}
// Can handle lists with 100+ elements without crashing
```

**What gives a clean error:**
```kira
// Deep recursion now gives StackOverflow error instead of crashing
fn deep(n: i64) -> i64 {
    if n <= 0 { return 0 }
    return deep(n - 1)
}
deep(2000)  // Returns error.StackOverflow with message

// Output: Runtime error: error.StackOverflow
//         maximum recursion depth (1000) exceeded
```

**Remaining workarounds:**
- Keep user recursion depth under 1000 calls
- Use iterative patterns with `while` loops for very deep recursion

**Feature request:** Consider tail-call optimization for recursive functions to remove depth limits entirely.

### 2. No Iterative String Building in Parser

**Severity:** Low

**Description:** The JSON parser's `parse_string_contents_builder` function uses recursion for each character, limiting string length. An iterative approach would allow parsing arbitrarily long strings.

**Current implementation:** Each character triggers a recursive call.

**Suggested fix:** Refactor to use a `while` loop internally.

---

## Feature Requests

### 1. Tail-Call Optimization

**Priority:** Medium (was High - mitigated by depth tracking)

**Description:** Many functional patterns rely on tail recursion. Without TCO, these patterns hit the recursion depth limit (1000 calls) for deep recursion.

**Note:** The immediate crash issue has been mitigated by recursion depth tracking (2026-01-25). Programs now get a clean `StackOverflow` error instead of crashing. However, TCO would still be beneficial to remove depth limits entirely.

**Use case:** The JSON library's recursive list operations (`list_length`, `parse_array_elements`, etc.) would benefit from unlimited recursion depth.

### 2. Iterative List Operations in Standard Library

**Priority:** Medium

**Description:** Provide iterative versions of common list operations that don't consume stack space proportional to list length.

**Functions needed:**
- `std.list.length_iter` - count elements without recursion
- `std.list.fold_iter` - fold without recursion
- `std.list.map_iter` - map without recursion

### 3. String Iteration by Grapheme Cluster

**Priority:** Medium

**Description:** String iteration now works correctly by Unicode codepoint (fixed 2026-01-25). However, grapheme cluster iteration is still needed for proper text segmentation (e.g., combining characters, emoji with modifiers).

**Implemented:**
- ✅ `std.string.chars(s)` → `List[char]` - get codepoints
- ✅ `std.string.char_at(s, index)` → `Option[char]` - get codepoint at index
- ✅ String indexing `s[i]` - returns codepoint at index
- ✅ For-loop `for c in s` - iterates by codepoint

**Still needed:**
- `std.string.graphemes(s)` → `List[string]` - get grapheme clusters

### 4. ~~Larger Default Stack Size~~ (RESOLVED)

**Status:** Resolved via depth tracking (2026-01-25)

**Description:** Previously requested to increase stack size to allow more recursion. This is now handled by explicit recursion depth tracking with configurable limits. The default limit of 1000 provides a good balance between usability and safety.

The `max_recursion_depth` constant in `interpreter.zig` can be adjusted if needed.

---

## Environment

- **Kira version:** (as installed at /usr/local/bin/kira)
- **Platform:** macOS Darwin 24.6.0
- **Date discovered:** 2026-01-25
