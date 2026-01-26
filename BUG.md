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

### 1. Recursive Interpreter Causes Stack Overflow

**Severity:** Medium

**Description:** The Kira interpreter uses recursive evaluation which causes stack overflow when processing deeply recursive operations. This limits the practical size of data structures that can be processed.

**Observed limits:**
- Strings longer than ~1500 characters cause stack overflow during parsing
- Arrays with more than ~50 elements cause stack overflow when counting with `list_length`
- Deeply nested function calls (recursive helpers) hit stack limits quickly

**Reproduction:**
```kira
// This crashes with stack overflow
let long_string: string = repeat_string("x", 2000)
let input: string = std.string.concat("\"", std.string.concat(long_string, "\""))
let result: Result[Json, JsonError] = parse(input)
```

**Workaround:**
- Keep data structures small
- Avoid deep recursion in user code
- Use iterative patterns with `while` loops instead of recursive functions

**Feature request:** Consider tail-call optimization or trampolining for recursive functions.

### 2. No Iterative String Building in Parser

**Severity:** Low

**Description:** The JSON parser's `parse_string_contents_builder` function uses recursion for each character, limiting string length. An iterative approach would allow parsing arbitrarily long strings.

**Current implementation:** Each character triggers a recursive call.

**Suggested fix:** Refactor to use a `while` loop internally.

---

## Feature Requests

### 1. Tail-Call Optimization

**Priority:** High

**Description:** Many functional patterns rely on tail recursion. Without TCO, these patterns cause stack overflow for moderate-sized inputs.

**Use case:** The JSON library's recursive list operations (`list_length`, `parse_array_elements`, etc.) would benefit significantly.

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

### 4. Larger Default Stack Size

**Priority:** Low

**Description:** Consider increasing the default stack size for the interpreter to allow more recursive depth before overflow.

---

## Environment

- **Kira version:** (as installed at /usr/local/bin/kira)
- **Platform:** macOS Darwin 24.6.0
- **Date discovered:** 2026-01-25
