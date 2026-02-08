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

---

## [x] Bug 4: `List[T]` and `HashMap` types not registered in type checker

**Status:** Fixed in Kira compiler

**Description:** The Kira v0.11.0 type checker did not recognize `List[T]` or `HashMap` as built-in types. Both are documented in the Kira standard library docs (`stdlib.md`) as automatically available types, and the Kira interpreter handled them correctly at runtime, but the type checker rejected them with `undefined type`.

**Resolution:** Fixed by registering `List` and `HashMap` as built-in type symbols in the global scope during symbol table initialization (`src/symbols/table.zig`), and adding `Cons`/`Nil` variant constructor handling in the type checker (`src/typechecker/checker.zig`).

---

## [ ] Bug 5: Type checker crashes (segfault) on large files

**Status:** Blocked (Kira compiler bug)

**Description:** The Kira v0.11.0 type checker crashes with a segmentation fault when checking `eval.ki` and `main.ki`. The crash occurs in the type checker's hash map implementation (`_hash_map.wyhash`), suggesting a null pointer or uninitialized memory access during type resolution.

**Steps to reproduce:**
1. Run `kira check src/eval.ki` or `kira check src/main.ki`

**Expected:** Type checking completes (with errors or success).

**Actual:**
```
Segmentation fault at address 0x1
???:?:?: in _hash.wyhash.Wyhash.hash
???:?:?: in _typechecker.checker.TypeChecker.resolveAstType
```

**Notes:** This may be triggered by the undefined `List[T]`/`HashMap` types (Bug 4) causing the type checker to dereference null type information. Fixing Bug 4 may also fix this crash.
