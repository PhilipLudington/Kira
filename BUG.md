# Kira Language Bugs

Bugs encountered in the Kira language while developing the Lisp interpreter.

---

## [x] Bug 1: Recursive HOF corrupts parameter bindings on second call with new closure

**Status:** Fixed

**Description:** When a recursive higher-order function is called twice, and the second call passes a newly-created closure (inline lambda), the parameter bindings become corrupted during recursion. The error manifests as "cdr: requires non-empty list" even when the list is not empty.

**Minimal reproduction:**

```lisp
(define (local-foldl f init lst)
  (if (null? lst)
      init
      (local-foldl f (f init (car lst)) (cdr lst))))

(local-foldl + 0 '(1 2 3))                                    ; ✅ returns 6
(local-foldl (lambda (acc x) (cons x acc)) '() '(1 2 3))      ; ❌ ERROR
```

Error: `cdr: requires non-empty list` at the `(cdr lst)` call site.

---

### Diagnostic Test Results

| Test | Scenario | Result |
|------|----------|--------|
| builtin → builtin | `(foldl + ...)` then `(foldl * ...)` | ✅ |
| builtin → inline lambda | `(foldl + ...)` then `(foldl (lambda ...) ...)` | ❌ |
| lambda → lambda | Two different inline lambdas | ❌ |
| same lambda twice | Identical `(lambda (acc x) (+ acc x))` syntax | ❌ |
| named lambda (define before) | `(define f ...)` before first call | ✅ |
| named lambda (define after) | `(define f ...)` after first call | ❌ |
| let-bound lambda | `(let ((f (lambda ...))) (foldl f ...))` | ❌ |
| lambda → builtin | Lambda first, then builtin | ✅ |
| single inline lambda | First and only call | ✅ |
| same named lambda twice | `(foldl my-fn ...)` twice | ✅ |
| non-recursive HOF | `(define (apply-fn f x y) (f x y))` | ✅ |
| f not called | Recursive fn that passes f but doesn't call it | ✅ |
| empty list | Second call with `'()` (no recursion) | ✅ |
| factory pattern | Fresh function instance per call | ✅ |

---

### Key Findings

1. **NOT import-specific** — Bug reproduces with local function definitions
2. **Requires recursion** — Non-recursive HOFs work correctly
3. **Requires `f` to be called** — If `f` is passed but not invoked, no bug
4. **Triggered by NEW closure instances** — Not builtin vs lambda specifically
5. **Second call triggers it** — First call to a recursive HOF always succeeds
6. **Order matters** — `lambda→builtin` works; `builtin→lambda` fails
7. **Same closure instance OK** — Using the same named lambda repeatedly works
8. **Define-before-first-call workaround** — Lambda must be bound at top-level BEFORE any call to the recursive function
9. **Let-binding insufficient** — Must be top-level `define`, not `let`

---

### Hypothesis for Compiler Team

The bug appears to be in **environment frame management during recursive calls** when the function parameter `f` holds a closure.

**Suspected mechanism:**

1. First call: `(foldl + 0 '(1 2 3))` — `f` binds to builtin `+` (no closure environment)
2. Recursive calls complete normally, environments cleaned up
3. Second call: `(foldl (lambda ...) '() '(1 2 3))` — `f` binds to new closure
4. When `(f init (car lst))` is evaluated, the closure's captured environment is activated
5. **BUG:** This activation corrupts or shadows the current frame's `lst` binding
6. The recursive call `(foldl f ... (cdr lst))` evaluates `lst` and gets wrong value
7. `(cdr lst)` receives stale/wrong value, causing the error

**Evidence supporting this hypothesis:**

- Bug only occurs when `f` is **called** (not just passed)
- Bug only occurs on **second+ calls** (first call establishes some state)
- Bug only occurs with **new closure instances** (reusing same closure works)
- Bug does NOT occur if lambda is defined **before first call** (suggests early definition avoids some environment collision)
- Let-bound lambdas fail (closure created at call time, like inline)
- Factory pattern works (fresh function = fresh closure scope)

**Possible root causes to investigate:**

1. **Environment frame reuse** — Recursive calls may reuse frames instead of allocating fresh ones when a closure is involved
2. **Closure environment merging** — When calling `f`, the closure's environment may be incorrectly merged into the current frame
3. **Binding shadowing** — The closure's captured bindings may shadow the function's parameter bindings
4. **Stale environment pointer** — The recursive function may hold a stale pointer to a previous call's environment

**Suggested investigation:**

1. Add debug tracing to `eval_apply` or equivalent to dump environment frames on each recursive call
2. Compare environment state between:
   - First call with builtin (works)
   - Second call with lambda (fails)
3. Check if `lst` binding exists in closure environment and shadows function parameter
4. Verify environment frames are properly allocated (not reused) for recursive calls

---

### Workarounds

```lisp
; Workaround 1: Define lambda at top-level BEFORE first call
(define my-cons (lambda (acc x) (cons x acc)))
(foldl + 0 '(1 2 3))              ; OK
(foldl my-cons '() '(1 2 3))      ; OK

; Workaround 2: Call with lambda FIRST
(foldl (lambda (acc x) (cons x acc)) '() '(1 2 3))  ; OK (first call)
(foldl + 0 '(1 2 3))                                 ; OK (after lambda)

; Workaround 3: Use explicit recursion instead of HOF
(define (reverse lst)
  (define (rev-helper lst acc)
    (if (null? lst)
        acc
        (rev-helper (cdr lst) (cons (car lst) acc))))
  (rev-helper lst '()))
```

**Affected code:** `src/stdlib.lisp` uses explicit recursion in several places to avoid this bug.

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
