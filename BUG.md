# Kira Language Bugs

Bugs encountered in the Kira language while developing the Lisp interpreter.

---

## [x] Bug 1: Imported recursive functions fail after builtin+lambda call sequence

**Status:** Fixed (commit 89f2b5c)

**Description:** When a recursive function is imported from a module, calling it with a builtin function (like `+`) followed by calling it with an inline lambda causes the second call to fail with "cdr: requires non-empty list" error, even though the list is not empty.

**Root cause:** Module-level and imported functions were registered with `captured_env = null`. When called via builtins, recursive calls couldn't find the function name because the fallback used the caller's environment instead of the defining scope.

**Fix:** Capture the appropriate environment at registration time:
- `registerModuleExports`: capture `&self.global_env`
- `registerModuleNamespace`: capture `env` parameter
- `registerDeclaration`: capture `env` parameter

See `src/interpreter/interpreter.zig` lines 130, 286, 492.

**Verified:** Test case `examples/bug1_test.ki` demonstrates the fix works correctly with interleaved named function and lambda calls.

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
