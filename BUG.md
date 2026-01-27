# Kira Language Bugs Encountered

These are bugs in the Kira programming language that were encountered while implementing the Lisp interpreter and compiler. Workarounds are in place in `src/main.ki`.

**Last verified:** 2026-01-27

---

## [x] Bug 1: `for` loop crashes on empty `List[RecursiveType]`

**Status:** Fixed (2026-01-27)

**Description:** When using a `for` loop to iterate over an empty list where the element type is a recursive sum type (like `LispValue` or `IRExpr`), Kira threw a `TypeMismatch` runtime error.

**Root Cause:** In `evalForLoop()` in `src/interpreter/interpreter.zig`, the switch statement on the iterable value had cases for `.array`, `.tuple`, `.cons`, and `.string`, but no case for `.nil` (empty list). Empty lists fell through to `else => return error.TypeMismatch`.

**Solution:** Added a `.nil` case to handle empty lists (zero iterations, no error).

**Note:** The workarounds in `src/main.ki` can now be simplified to remove the empty list guards before `for` loops.

---

## [x] Bug 2: `if` is a statement, not an expression

**Status:** Fixed (2026-01-27)

**Description:** Kira's `if` construct was a statement and did not return a value.

**Solution:** Implemented `if` as an expression. Both branches must have the same type and `else` is required:
```kira
let x: i32 = if condition { 42 } else { 0 }
let grade: string = if score >= 90 { "A" } else if score >= 80 { "B" } else { "F" }
```

**Note:** The workarounds in `src/main.ki` can now be simplified to use if expressions directly.

---

## [x] Bug 3: No command-line argument support

**Status:** Fixed (2026-01-27)

**Description:** Kira did not provide access to command-line arguments.

**Solution:** Added `std.env.args()` function that returns `[string]` (array of strings) containing command-line arguments passed after the file path.

**Usage:**
```kira
effect fn main() -> void {
    let args: [string] = std.env.args()
    for arg in args {
        std.io.println(arg)
    }
}
```

**Running:** `kira run myprogram.ki arg1 arg2 arg3`

---

## [x] Bug 4: Multi-line string literals not supported

**Status:** Fixed (2026-01-27)

**Description:** Kira did not support multi-line string literals. A string had to be on a single line.

**Root Cause:** In `scanString()` in `src/lexer/lexer.zig`, the while loop condition explicitly rejected newlines (`self.peek() != '\n'`), and the subsequent error check also treated newlines as invalid.

**Solution:** Removed the newline checks from `scanString()`. The lexer's location tracking already handles newlines correctly via `advance()`, so multi-line strings work naturally.

**Usage:**
```kira
let s: string = "line 1
line 2
line 3"
```

**Note:** The workarounds in `src/main.ki` can now be simplified to use multi-line string literals directly instead of `StringBuilder`.
