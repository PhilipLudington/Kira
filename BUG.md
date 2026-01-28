# Kira Language Bugs

Bugs encountered in the Kira language while developing the Lisp interpreter.

---

## [x] Bug 1: Imported recursive functions fail after builtin+lambda call sequence

**Status:** Fixed

**Description:** When a recursive function is imported from a module, calling it with a builtin function (like `+`) followed by calling it with an inline lambda causes the second call to fail with "cdr: requires non-empty list" error, even though the list is not empty.

**Root Cause:** Module-level and imported functions were registered with `captured_env = null`. When called via builtins like `std.list.fold`, the `builtinCallFunction` passed `&self.global_env` as the caller environment. The fallback in `callFunction` became `current_func.captured_env orelse current_caller_env`, which resolved to the global env instead of the defining scope. Recursive calls couldn't find the function name in this incorrect scope.

**Fix:** Changed three locations in `src/interpreter/interpreter.zig` to capture the appropriate environment instead of `null`:
- Line 130 (`registerModuleExports`): `captured_env = &self.global_env`
- Line 286 (`registerModuleNamespace`): `captured_env = env`
- Line 492 (`registerDeclaration`): `captured_env = env`

**Verification:** All 256 tests pass, plus manual verification with `std.list.fold` and recursive functions.

---

## [ ] Bug 2: Nested pattern match with sum type extraction causes TypeMismatch

**Status:** Open (workaround in place)

**Description:** When pattern matching on a `List[LispValue]` with a nested sum type extraction like `Cons(LispString(s), Nil)`, Kira throws a runtime `TypeMismatch` error even when the pattern should match.

**Steps to reproduce:**
```kira
match args {
    Cons(LispString(s), Nil) => {
        // Use s - causes TypeMismatch at runtime
    }
    _ => { }
}
```

**Expected:** Pattern matches and `s` is bound to the string value.

**Actual:** Runtime error: `error.TypeMismatch`

**Workaround:** Use two-level matching:
```kira
match args {
    Cons(first, Nil) => {
        match first {
            LispString(s) => {
                // Use s - works
            }
            _ => { }
        }
    }
    _ => { }
}
```

**Affected code:** `src/main.ki` - test framework builtins (`assert-eq`, `assert-true`, `assert-false`, `assert-throws`, `test-begin`) all use two-level matching.

---

## Limitations

### No variadic functions

The Lisp interpreter does not support variadic/rest parameters.

```lisp
; This syntax is NOT supported:
(define (func . args) ...)
(lambda args ...)
```

**Impact:** Functions like `constantly` cannot ignore arbitrary arguments.

**Workaround:** Define functions with a fixed number of parameters (possibly ignored).

### No string manipulation primitives

The interpreter lacks primitives for string operations beyond:
- `string-append` - concatenate strings
- `string-length` - get length
- `number->string` / `string->number` - conversion

**Missing:** `substring`, `string-ref`, `string-split`, `string-join`, `string-trim`

**Impact:** Standard library cannot implement string utilities.

### Import paths relative to working directory

The `import` function resolves paths relative to the current working directory, not relative to the importing file.

```lisp
; In examples/testing/test-stdlib.lisp:
(import "src/stdlib.lisp")        ; Correct - relative to project root
(import "../src/stdlib.lisp")     ; Wrong - would look for examples/src/stdlib.lisp
```

**Impact:** Tests must be run from the project root directory.
