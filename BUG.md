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

**Status:** Fixed in Kira v0.11.0

**Description:** The Kira v0.11.0 type checker did not recognize `List[T]`, `HashMap`, or `StringBuilder` as built-in types. It also failed to resolve user-defined sum type variant constructors (e.g., `Circle`, `TokFloat`, `LispNil`), rejected string concatenation with `+`, and errored on pattern variable bindings in match arms.

**Resolution:** Fixed with four changes to the Kira compiler:
- Registered `StringBuilder` as a built-in type alongside `List[T]` and `HashMap` in the symbol table (`src/symbols/table.zig`)
- Added string concatenation support: `string + string` now returns `string` (`src/typechecker/checker.zig`)
- Variant constructors for user-defined sum types are now resolved by searching all registered type definitions for the matching variant name (`src/typechecker/checker.zig`)
- Pattern variable bindings in match arms (e.g., `Circle(r)`) no longer emit "type inference is not allowed" — inferred types return error_type silently, which unifies with any type (`src/typechecker/checker.zig`)

---

## [x] Bug 5: Type checker crashes (segfault) on large files

**Status:** Fixed (resolved by Bug 4 fix)

**Description:** The Kira v0.11.0 type checker crashed with a segmentation fault when checking `eval.ki` and `main.ki`. The crash occurred in the type checker's hash map implementation, suggesting a null pointer or uninitialized memory access during type resolution.

**Resolution:** Fixed by the Bug 4 fix. The segfault was caused by the type checker dereferencing null type information for unregistered types and unresolved variant constructors. With all built-in types registered and variant constructor resolution in place, the null dereference paths are eliminated.
