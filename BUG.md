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

## [x] Bug 2: Nested pattern match with sum type extraction causes TypeMismatch

**Status:** Cannot Reproduce

**Original Description:** When pattern matching on a `List[LispValue]` with a nested sum type extraction like `Cons(LispString(s), Nil)`, Kira was reported to throw a runtime `TypeMismatch` error.

**Investigation (2026-01-27):**

This bug cannot be reproduced. The referenced code does not exist:
- `src/main.ki` - file does not exist
- `LispValue`, `LispString` - types do not exist in the codebase
- "Lisp interpreter" - no such code found in the repository

Testing confirms nested pattern matching works correctly:
```kira
type Value = | VString(string) | VInt(i32)

fn extract_nested(lst: List[Value]) -> string {
    match lst {
        Cons(VString(s), Nil) => { return s }  // Works correctly
        _ => { return "no match" }
    }
}
```

All test variations pass, including:
- Basic nested patterns: `Cons(VString(s), Nil)`
- Multi-element lists: `Cons(VString(a), Cons(VString(b), Nil))`
- Deep nesting: `Cons(Wrapped(VString(s)), Nil)`

**Note:** The interpreter has a TODO at line 2080 for handling `.record` variant fields, but Kira syntax only supports tuple-style variant fields, so this code path is unreachable from user code.

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
