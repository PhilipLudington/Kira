# Kira Bugs

## [x] Bug 1: Type checker accepts `std.i64.to_string` but runtime crashes

**Status:** Fixed

**Fix:** Added type checker rejection for `std.i64`, `std.i32`, `std.f64`, `std.f32` paths with a helpful error message redirecting to `std.int` or `std.float`.

---

## [x] Bug 2: Named-field variant constructors not resolved from type imports

**Status:** Fixed

**Fix:** When importing a sum type by name, the resolver now automatically imports all its variant constructors into the importing scope.

---

## [x] Bug 3: Generic type parameters unresolved in function-type positions

**Status:** Fixed

**Fix:** Two changes: (1) Cache the resolved type of generic `let_decl` bindings in `type_env` during declaration checking, so `getSymbolType` can find it without re-resolving. (2) Added `checkGenericVariableCall` to handle generic calls on variable symbols (from `let name[T]: fn(...) = ...`), which extracts type variables from the cached type and instantiates them.

---

## [x] Bug 4: Segfault in type checker on variant constructor with complex arguments

**Status:** Fixed

**Fix:** Root cause was Bug 3 — when generic type parameters couldn't be resolved, the type checker entered an error state that led to the segfault. Fixed by the Bug 3 fix.

---

## [x] Bug 5: `shadow` keyword not supported on closure/function parameters

**Status:** Fixed

**Fix:** Removed the shadowing check for function and closure parameters. Parameters naturally create bindings in a new scope, so shadowing outer names is expected behavior (consistent with most languages). The `shadow` keyword remains available for `let`/`var` same-scope rebinding.
