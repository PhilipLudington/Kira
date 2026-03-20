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

## [x] Bug 3: Match arm bindings silently shadow module-level functions

**Status:** Fixed

**Root cause:** When the explicit shadowing requirement (`shadow` keyword) was added to Kira, match arm pattern bindings were given the same restriction as `let`/`var` bindings — `allow_shadow` was hardcoded to `false` in both the resolver and type checker for match arms. However, match arm bindings are inherently scoped (each arm creates its own block scope) and pattern variable names are often constrained by the data being destructured, making the `shadow` keyword requirement overly burdensome and a breaking change for existing code.

**Fix:** Changed `allow_shadow` from `false` to `true` for match arm pattern resolution in all four call sites: match statements and match expressions in both the resolver (`resolvePattern`) and type checker (`addPatternBindings`). Match arm bindings now implicitly allow shadowing outer scope names without requiring the `shadow` keyword.

**Affected files:** `src/symbols/resolver.zig`, `src/typechecker/checker.zig`
