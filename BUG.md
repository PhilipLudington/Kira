# Kira Compiler Bugs

## [x] Bug 1: Cross-module type imports fail to resolve

**Status:** Fixed

**Root cause:** Import aliases were always created with `is_public = false`, regardless of the original symbol's visibility. When module B imported a public type from module C, the import alias in B's scope was private. Any module A that tried to import that type through B (e.g., `import B.{ TypeName }`) received "Cannot import private symbol" because the visibility check only looked at the alias, not the original symbol.

**Fix:** Added `isEffectivelyPublic()` helper to both the Resolver and ModuleLoader that follows import alias chains to check the original symbol's visibility. Applied this check in all four import visibility gates: selective imports and whole-module imports in both `resolveImportDecl` (resolver) and `resolveModuleImport` (loader).

**Affected files:** `src/symbols/resolver.zig`, `src/modules/loader.zig`

---

## [x] Bug 2: Compiler segfault on deep nesting with many imported symbols

**Status:** Fixed

**Root cause:** The parser, resolver, type checker, and IR lowerer all used unbounded recursion for nested expressions, statements, blocks, and patterns. With deeply nested code, the process stack would overflow causing a segfault with no diagnostic output. (The interpreter already had a recursion limit of 1000, and the module loader had an import depth limit of 64, but the compilation passes had no such guards.)

**Fix:** Added a `nesting_depth` counter and `max_nesting_depth` limit (256) to all four compilation passes: Parser (`parseExpression`, `parseBlock`), Resolver (`resolveStatement`, `resolveExpression`), TypeChecker (`checkExpression`, `checkStatement`), and Lowerer (`lowerExpression`, `lowerStatement`). When the limit is hit, each pass reports a clear diagnostic error instead of segfaulting.

**Affected files:** `src/parser/parser.zig`, `src/symbols/resolver.zig`, `src/typechecker/checker.zig`, `src/ir/lower.zig`

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
