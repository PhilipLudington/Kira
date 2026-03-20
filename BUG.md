# Kira Compiler Bugs

## [x] Bug 1: Cross-module type imports fail to resolve

**Status:** Fixed

**Root cause:** Import aliases were always created with `is_public = false`, regardless of the original symbol's visibility. When module B imported a public type from module C, the import alias in B's scope was private. Any module A that tried to import that type through B (e.g., `import B.{ TypeName }`) received "Cannot import private symbol" because the visibility check only looked at the alias, not the original symbol.

**Fix:** Added `isEffectivelyPublic()` helper to both the Resolver and ModuleLoader that follows import alias chains to check the original symbol's visibility. Applied this check in all four import visibility gates: selective imports and whole-module imports in both `resolveImportDecl` (resolver) and `resolveModuleImport` (loader).

**Affected files:** `src/symbols/resolver.zig`, `src/modules/loader.zig`

---

## [ ] Bug 2: Compiler segfault on deep nesting with many imported symbols

**Status:** Open

**Description:** The compiler crashes with a segfault when compiling files that combine deeply nested code structures with a large number of imported symbols.

**Steps to reproduce:**
1. Create a module with many imported symbols
2. Write deeply nested control flow or match expressions within that module
3. Compile — the compiler segfaults

**Expected:** Compilation succeeds or produces a clear error message.

**Actual:** The compiler segfaults with no diagnostic output.

**Affected project:** Tharn — `runtime/channel_test.ki` had to be restructured to flatten nesting and reduce the interaction with imported symbols. See Tharn commit `5615440`.

---

## [ ] Bug 3: Match arm bindings silently shadow module-level functions

**Status:** Investigating

**Description:** Prior to a recent compiler update, match arm bindings could silently shadow module-level function names without any warning or error. The compiler now requires explicit acknowledgment of shadowing, but this was a breaking change with no migration guidance.

**Steps to reproduce:**
1. Define a module-level function `socket_handle`
2. In a match arm, bind a variable named `handle`
3. With older compiler: compiles silently (shadow is implicit)
4. With updated compiler: compilation fails due to new explicit shadow requirement

**Expected:** Either consistent behavior across versions, or a deprecation warning before making this a hard error.

**Actual:** The new requirement was introduced as a breaking change. Existing code using common binding names in match arms stopped compiling.

**Affected project:** Tharn — `tools/net.ki` match arms renamed bindings to avoid shadowing. See Tharn commit `5615440`.
