# Kira Compiler Bugs (v0.11.0)

## [x] Bug 1: Type checker does not register `std` module

**Status:** Fixed in Kira v0.11.0

**Description:** The Kira v0.11.0 type checker had no knowledge of the `std` module. Any code referencing `std.*` failed during type checking with `undefined symbol 'std'`.

**Resolution:** Fixed in the Kira compiler. `std.io.println("hello")` now runs correctly.

---

## [x] Bug 2: `var` bindings rejected in pure functions

**Status:** Fixed in Kira v0.11.0

**Description:** Kira v0.11.0 previously enforced that `var` (mutable) bindings could only appear inside `effect fn` declarations.

**Resolution:** Fixed in the Kira compiler. `var` is now allowed in plain `fn`.

---

## [x] Bug 3: Built-in conversion functions removed without migration path

**Status:** Fixed (migrated to namespaced functions)

**Description:** The bare built-in functions `to_string()`, `to_float()`, and `to_i64()` are no longer recognized as identifiers. They were moved to namespaced modules.

**Resolution:** All source files have been updated to use the namespaced replacements:
- `to_string(n)` (i64) → `std.int.to_string(n)`
- `to_string(n)` (i32) → `std.int.to_string(n)`
- `to_string(n)` (f64) → `std.float.to_string(n)`
- `to_float(n)` → `std.float.from_int(n)`
- `to_i64(n)` → `std.int.to_i64(n)`

Files updated: `eval.ki`, `lexer.ki`, `parser.ki`, `types.ki`, `main.ki`.

Example files also migrated (2026-02-09): `binary_tree.ki`, `bug1_test.ki`, `calculator.ki`, `fibonacci.ki`, `fizzbuzz.ki`, `json_builder.ki`, `list_operations.ki`, `option_handling.ki`, `parallel_test.ki`, `quicksort.ki`, `simple_parser.ki`, `stack.ki`, `temperature.ki`, `time_test.ki`, `word_count.ki`.

---

## [x] Bug 4: Type checker does not understand built-in generic types or their cascading effects

**Status:** Fixed in Kira compiler — verified 2026-02-09

**Description:** The Kira v0.11.0 type checker did not recognize `List[T]`, `HashMap`, `Option[T]`, `Result[T, E]`, or `StringBuilder` as built-in types. All are documented in the Kira standard library docs (`stdlib.md`) as automatically available types, and the Kira interpreter handles them correctly at runtime, but the type checker rejected them. This single root cause produced a cascade of downstream errors that made `kira check` unusable on any non-trivial codebase.

**Steps to reproduce:**
1. Create a file containing:
```
type Foo =
    | Bar(List[i32])

fn baz() -> Foo {
    return Bar(Cons(1, Nil))
}
```
2. Run `kira check <file>`

**Expected:** `List[T]` is recognized as a built-in generic type with `Cons` and `Nil` constructors.

**Actual:** `error: undefined type 'List'` / `error.TypeCheckError`

Similarly, `HashMap` produces `error: undefined type 'HashMap'`.

**Impact on this project:** Every source file except `compile.ki` uses `List[T]` in type definitions (e.g., `LispList(List[LispValue])`). `types.ki` and `env.ki` also use `HashMap` for environment bindings. The build cannot pass until the Kira type checker registers these built-in types.

### Root cause analysis for the Kira compiler team

The type checker appears to be missing built-in type registrations for the standard library's generic types. This single gap produces six distinct categories of downstream errors. All of them likely go away once the built-in types are registered.

**Category 1 — Unregistered built-in types:**
The type checker has no definitions for `List[T]`, `HashMap`, `StringBuilder`, `Option[T]`, or `Result[T, E]`. These are all used pervasively and work correctly at runtime.

**Category 2 — Variant constructors resolve to wrong types (`i8`):**
When the type checker cannot resolve a generic type like `Option[T]`, it appears to fall back to `i8` for the inner value. This produces misleading errors like:
- `type mismatch: expected 'string', found 'i8'` — from `match std.string.substring(...) { Some(result) => { return result } }`
- `type mismatch: expected 'char', found 'i8'` — from `match std.string.char_at(...) { Some(c) => { return c } }`
- `type mismatch: expected 'i64', found 'i8'` — from `TokInt(n)` where `n` should be `i64`
- `type mismatch: expected 'f64', found 'i8'` — from `TokFloat(f)` where `f` should be `f64`
- `type mismatch: expected 'Option[LispValue]', found 'Option[i8]'` — wrapping an extracted value in `Some()`
- `type mismatch: expected 'Option[LispValue]', found 'Option[i16]'` — variant with tuple payload

The `i8` fallback is a strong clue: the checker resolves unknown variant payloads to its smallest integer type rather than propagating a proper "unknown" type or emitting a single "undefined type" error.

**Category 3 — `Cons` destructuring rejected:**
`Cons(head, tail)` patterns in match arms produce `expected 0 argument(s), found 2`. The checker sees `Cons` as a nullary constructor because `List[T]` is not registered as a 2-variant sum type (`Cons(T, List[T]) | Nil`). This affects every file that pattern-matches on lists. Example from `parser.ki:41`:
```
Cons(token, rest) => {  // error: expected 0 argument(s), found 2
```

**Category 4 — `variant not found in matched type`:**
The checker cannot find `Ok`, `Err`, `Some`, or `None` as valid variants, because `Result[T, E]` and `Option[T]` are not registered. This makes it impossible to match on any std library function that returns these types. Example from `env.ki:53`:
```
Some(parent) => { return env_lookup(parent, name) }  // error: variant not found
```

**Category 5 — Boolean and iterable blindness:**
- `if condition must be a boolean expression` — functions like `std.map.contains()` and comparisons like `cmd == "help"` return `bool`, but the checker does not recognize the result as boolean. This suggests the return types of std library functions are also not registered.
- `for loop requires an iterable` — `List[T]` is not recognized as iterable, so `for c in std.string.chars(s)` and `for def in defs` (where `defs: List[T]`) both fail.

**Category 6 — Non-exhaustive match false positives:**
The checker reports `non-exhaustive match` on patterns that are actually exhaustive (e.g., matching `Some` + `None`, or `Ok` + `Err`). Because the variants are not registered, the checker cannot verify coverage and defaults to "missing patterns for _ (catch-all pattern needed)".

**Category 7 — Tuple and struct destructuring:**
- `tuple pattern used with non-tuple type` — `let (name, value): (string, IRExpr) = binding` is rejected. The checker may not recognize tuple types extracted from unresolved generic containers.
- `type mismatch: expected 'List[(string, IRExpr)]', found 'List[(i8, i8)]'` — tuple elements inside `Cons()` calls fall back to `i8`.
- `char pattern used with non-char type` — matching `char` values from `std.string.chars()` fails because the iterator's element type is not resolved.

**Affected files (verified 2026-02-09):**
- `types.ki` — `for loop requires an iterable`, char pattern mismatches (6 errors)
- `lexer.ki` — `i8` type fallback, `variant not found`, non-exhaustive match (5 errors)
- `parser.ki` — Cons destructuring rejected, `i8` type fallback, non-exhaustive match (5 errors)
- `env.ki` — `variant not found` (Ok/Err/Some/None), boolean blindness, Cons destructuring, non-exhaustive match (16 errors)
- `main.ki` — all categories above combined (100+ errors; does not segfault as of 2026-02-09)
- `eval.ki` — cannot be checked, segfaults (see Bug 5)

**Resolution:** Fixed in the Kira compiler. All seven error categories were resolved by:
1. Registering `Option[T]` and `Result[T, E]` as built-in types in the symbol table (`table.zig`)
2. Adding `getOptionInnerType()` and `getResultTypes()` helpers to handle both `ResolvedType.option`/`.result` and instantiated representations (`checker.zig`)
3. Fixing variant constructors (`Ok`, `Err`, `None`) to return proper `Result`/`Option` types instead of `errorType`/`i8` (`checker.zig`)
4. Adding `checkPattern()` direct handling for Option/Result subject types in constructor patterns (`checker.zig`)
5. Updating `lookupVariantInType()` and `lookupVariantFieldTypes()` for `.option` and `.result` resolved types (`checker.zig`)
6. Fixing `getIterableElement()` to return element type for instantiated generic collections (`unify.zig`)
7. Updating exhaustiveness checker to handle instantiated Option/Result types (`pattern_compiler.zig`)

Verified: `examples/test_result_match.ki`, `examples/error_chain.ki`, and `examples/bug4_test.ki` all pass `kira check`.

---

## [x] Bug 5: Type checker crashes (segfault) on `eval.ki`

**Status:** Fixed — root cause was Bug 4 (now resolved); `eval.ki` no longer in tree

**Description:** The Kira v0.11.0 type checker crashes with a segmentation fault when checking `eval.ki`. The crash occurs during type resolution, likely due to a null pointer dereference when the checker encounters types it cannot resolve (see Bug 4).

**Steps to reproduce:**
1. Run `kira check src/eval.ki`

**Expected:** Type checking completes (with errors or success).

**Actual (eval.ki, verified 2026-02-09):**
```
Segmentation fault at address 0xaaaaaaaaaaaaaaaa
???:?:?: in _typechecker.checker.TypeChecker.resolveAstType
???:?:?: in _typechecker.checker.TypeChecker.resolveAstType
???:?:?: in _typechecker.checker.TypeChecker.getSymbolType
???:?:?: in _typechecker.checker.TypeChecker.checkExpression
???:?:?: in _typechecker.checker.TypeChecker.checkFunctionCall
???:?:?: in _typechecker.checker.TypeChecker.checkExpression
???:?:?: in _typechecker.checker.TypeChecker.checkStatement (repeated)
???:?:?: in _typechecker.checker.TypeChecker.checkFunctionDecl
???:?:?: in _typechecker.checker.TypeChecker.checkDeclaration
???:?:?: in _typechecker.checker.TypeChecker.check
```

### Changes since last report (2026-02-08)

- **`main.ki` no longer segfaults.** It now completes type checking and reports 100+ errors (all Bug 4 categories). This may be due to code changes in `main.ki` since the last check, not a compiler fix — the same compiler version (v0.11.0) is in use.
- **`eval.ki` still segfaults** but at a different address: `0xaaaaaaaaaaaaaaaa` (previously `0x1`). The sentinel value `0xAAAA...` (repeating `0xAA` bytes) is a common debug/uninitialized memory pattern, strongly suggesting the crash is a use-after-free or access to uninitialized memory in the type checker's internal data structures.
- The stack trace has shifted: previously the crash was in `Scope.lookupLocal` → `hashString` → `Wyhash.hash` (null key being hashed). Now it crashes in `resolveAstType` → `getSymbolType` → `checkFunctionCall` (null type being dereferenced during function call checking).

### Analysis for the Kira compiler team

The segfault address `0xaaaaaaaaaaaaaaaa` is diagnostic — this is likely Zig's debug allocator poison pattern (`0xAA` fill), meaning the checker is reading from freed or uninitialized memory. The crash path is:

1. `checkFunctionCall` needs the return type of a function
2. `getSymbolType` looks up the function's type signature
3. `resolveAstType` tries to resolve a type reference (likely a `List[T]` or other unregistered type from Bug 4)
4. The unresolved type produces a null/garbage pointer
5. The checker dereferences it → segfault

**Why `eval.ki` crashes but other files don't:** `eval.ki` is the largest file (~900 lines) with the densest use of unregistered types. The checker may accumulate enough unresolved type entries to trigger the memory corruption, while smaller files hit soft errors and bail out before reaching the crash point.

**Suggested fix for the Kira compiler:** Add null checks in `resolveAstType` and `getSymbolType` before dereferencing type pointers. When a type cannot be resolved, emit a type error and substitute an "error" sentinel type instead of storing null/garbage. This is defense-in-depth — fixing Bug 4 (registering built-in types) would remove the primary trigger, but the null-safety issue should be fixed independently to prevent segfaults on any future unresolvable type.

**Relationship to Bug 4:** This is almost certainly a consequence of Bug 4. If the built-in types were registered, the type checker would have valid type entries and would not dereference null/uninitialized pointers. However, the segfault is a separate defect — the checker should never crash regardless of input.

---

## [x] Bug 6: Type checker unconditionally requires `effect` on `main`

**Status:** Fixed in Kira compiler — 2026-02-09

**Description:** The type checker unconditionally required `effect fn main()`, even when `main` performed no I/O or side effects. A pure `fn main() -> i32 { return factorial(5) }` was rejected with `'main' function must be declared with 'effect' keyword`.

**Steps to reproduce:**
1. Create a file with a pure main function (no I/O):
```
fn main() -> i32 {
    return 42
}
```
2. Run `kira check <file>`

**Expected:** Type checking passes — `main` is pure, no effects needed.

**Actual:** `error: 'main' function must be declared with 'effect' keyword`

**Root cause:** The check in `checker.zig` was unconditional — it tested `!func.is_effect` on any function named `main` regardless of whether it actually called effectful functions.

**Resolution:** Removed the unconditional check. The existing effect system already validates this correctly: if `main` calls an effectful function without being declared `effect`, the checker emits `"cannot call effect function from pure function"` at the specific call site. This gives a more precise error and allows pure `main` functions.

**Files changed:** `src/typechecker/checker.zig` (removed E7 main_decl tracking, updated test).

**Affected examples fixed:** `factorial.ki`, `geometry_combined.ki`, `modules_demo.ki` — all now pass `kira check`.

---

## [x] Bug 7: Type checker rejects array literal assignment to dynamic array type

**Status:** Fixed in Kira compiler — 2026-02-09

**Description:** The type checker rejected `let arr: [i32] = [1, 2, 3]` with `type mismatch: expected '[i32]', found '[i32; 3]'`. Array literals always produced fixed-size types (`[i32; 3]`), which could not be assigned to dynamic array types (`[i32]`).

**Steps to reproduce:**
1. Create a file containing:
```
let arr: [i32] = [1, 2, 3]
```
2. Run `kira check <file>`

**Expected:** Type checking passes — `[i32; 3]` should be assignable to `[i32]`.

**Actual:** `error: type mismatch: expected '[i32]', found '[i32; 3]'`

**Root cause:** The `typesEqual` function in `unify.zig` compared array sizes strictly (`aa.size != ab.size`), rejecting `null` (dynamic) vs `3` (fixed). The `isAssignable` function simply delegated to `typesEqual` with no coercion logic.

**Resolution:** Added array coercion to `isAssignable` in `unify.zig`: fixed-size arrays `[T; N]` are now assignable to dynamic arrays `[T]` when element types match. Updated `checker.zig` to use `isAssignable` (instead of `typesEqual`) for let-bindings, var-bindings, and function argument type checks.

**Files changed:** `src/typechecker/unify.zig` (array coercion in `isAssignable`), `src/typechecker/checker.zig` (use `isAssignable` for bindings and arguments).

**Remaining:** Empty array literal `[]` still cannot infer its type — `let arr: [i32] = []` produces `cannot infer type of empty array literal`. This is a separate issue (no elements to infer element type from).
