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

### ~~1. Recursive Interpreter Causes Stack Overflow~~ (FIXED)

**Status:** Fixed (2026-01-25)

**Severity:** ~~Medium~~ → Resolved

**Description:** The Kira interpreter previously used recursive evaluation which caused stack overflow when processing deeply recursive operations.

**Fixes applied:**
1. **Recursion depth tracking**: The interpreter tracks call depth and returns a clean `StackOverflow` error at 1000 depth for non-tail-recursive calls.
2. **Tail-call optimization (TCO)**: Tail-recursive functions now use a trampoline pattern, allowing unlimited recursion depth without consuming stack space.
3. **Iterative Cons pattern matching**: List pattern matching (`Cons(h, t)` patterns) uses iterative traversal instead of recursion.
4. **Iterative Cons binding**: List destructuring in let bindings also uses iterative traversal.

**What's now possible with TCO:**
```kira
// Tail recursion - unlimited depth via TCO
fn countdown(n: i64) -> i64 {
    if n <= 0 { return 0 }
    return countdown(n - 1)  // Tail call - optimized!
}
countdown(100000)  // Works! Returns 0

// Mutual tail recursion also works
fn is_even(n: i64) -> bool {
    if n == 0 { return true }
    return is_odd(n - 1)  // Tail call
}
fn is_odd(n: i64) -> bool {
    if n == 0 { return false }
    return is_even(n - 1)  // Tail call
}
is_even(100000)  // Works! Returns true
```

**Non-tail calls still limited (by design):**
```kira
// Non-tail recursion still limited to 1000 depth
fn factorial(n: i64) -> i64 {
    if n <= 1 { return 1 }
    return n * factorial(n - 1)  // NOT a tail call (multiply happens after)
}
factorial(2000)  // Returns StackOverflow error
```

**TCO implementation details:**
- Detects tail calls in `return` statements (direct function calls being returned)
- Uses trampoline loop pattern instead of actual recursion
- Works with closures (captured environments preserved)
- Works with mutual recursion (operates on function values)

### 2. No Iterative String Building in Parser

**Severity:** Low

**Description:** The JSON parser's `parse_string_contents_builder` function uses recursion for each character, limiting string length. An iterative approach would allow parsing arbitrarily long strings.

**Current implementation:** Each character triggers a recursive call.

**Suggested fix:** Refactor to use a `while` loop internally.

---

## Feature Requests

### ~~1. Tail-Call Optimization~~ (IMPLEMENTED)

**Status:** Implemented (2026-01-25)

**Description:** Tail-call optimization is now implemented using a trampoline pattern. Tail-recursive functions can recurse to unlimited depth without consuming stack space.

**Implementation:**
- Added `TailCallEncountered` error for TCO control flow
- Added `TailCallSignal` struct to hold tail call information
- `evalReturnStatement()` detects direct function calls being returned
- `callFunction()` uses a labeled trampoline loop to handle tail calls iteratively
- Works with closures and mutual recursion

**Verification:**
```kira
fn deep(n: i64) -> i64 {
    if n <= 0 { return 0 }
    return deep(n - 1)
}
deep(100000)  // Works! (10x beyond old limit)
```

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
