# Bug: Kira Runtime Memory Leaks During Module Loading

**Status: FIXED**

## Summary

The Kira runtime reports memory leaks during module loading and symbol resolution. These occur consistently when running any Kira program that imports modules.

## Severity

**Low** - Does not affect program correctness. Memory is leaked but programs run successfully.

## Reproduction

Run any Kira program that imports modules:

```bash
kira run tests/test_json_testsuite.ki
```

Or even just check syntax:

```bash
kira check tests/test_json_testsuite.ki
```

**Output (truncated):**
```
error(gpa): memory address 0x103800040 leaked:
???:?:?: 0x103025957 in _array_list.Aligned(symbols.symbol.Symbol.GenericParamInfo,null).toOwnedSlice (???)
???:?:?: 0x103071583 in _modules.loader.ModuleLoader.addTypeSymbol (???)
???:?:?: 0x10305203b in _modules.loader.ModuleLoader.loadAndResolveFile (???)
???:?:?: 0x10302928f in _modules.loader.ModuleLoader.loadModule (???)
???:?:?: 0x102ffed27 in _symbols.resolver.Resolver.resolveImportDecl (???)
???:?:?: 0x102fcb95f in _symbols.resolver.Resolver.resolveImports (???)

error(gpa): memory address 0x102300000 leaked:
???:?:?: 0x10106a2c3 in _array_list.Aligned(symbols.symbol.Symbol.RecordFieldInfo,null).toOwnedSlice (???)
???:?:?: 0x1010b59c7 in _modules.loader.ModuleLoader.addTypeSymbol (???)
...
```

## Root Cause

The leaks originate in Kira's module loader (`ModuleLoader`) and symbol resolver (`Resolver`), specifically in:

1. `ModuleLoader.addTypeSymbol` - When adding type symbols to the symbol table
2. `ModuleLoader.loadAndResolveFile` - When loading and resolving imported files
3. `Resolver.resolveImportDecl` - When resolving import declarations

The leaked memory appears to be from `ArrayList.toOwnedSlice` calls for:
- `Symbol.GenericParamInfo` - Generic type parameters
- `Symbol.RecordFieldInfo` - Record/struct field information
- `Symbol.VariantInfo` - Sum type variant information

## Impact

- Memory usage grows with each module load
- Does not affect program correctness
- May cause issues in long-running processes or when loading many modules

## Workaround

None required for correctness. The leaks are small and programs complete successfully.

## Notes

This is a Kira runtime/compiler issue, not a kira-json library issue. The fix would need to be in:
- `~/Fun/Kira/src/modules/loader.zig`
- `~/Fun/Kira/src/symbols/resolver.zig`

The issue is likely missing `deinit` or `free` calls when the module loader completes, or arena allocator cleanup not happening properly.

## Fix

**Fixed in:** `src/symbols/symbol.zig`

The root cause was that `Symbol.deinit()` did nothing - it had an incorrect comment claiming all memory was owned by the program arena. In reality, slices created by `toOwnedSlice()` during symbol resolution were allocated with the resolver's allocator and needed to be freed.

The fix implements proper cleanup in `Symbol.deinit()` that frees:
- `FunctionSymbol`: generic_params, parameter_types, parameter_names slices
- `TypeDefSymbol`: generic_params, and for sum_type/product_type the variants/fields slices
- `TraitDefSymbol`: generic_params, methods slice, and nested allocations in each method

String contents and type pointers are NOT freed as they point to AST data owned by the program arena.
