# Memory Leak Fixes

## Summary

Fixed all memory leaks in the Kira codebase. Tests now pass with 0 leaks (previously 37).

## Status: Complete

All 164 tests pass with no memory leaks detected.

## Root Causes Fixed

### 1. AST Parser Memory Leaks
The parser allocated AST nodes (`Expression`, `Type`, `Pattern`, `Statement`) on the heap via `allocExpr`, `allocType`, etc., but `Program.deinit` only freed top-level slices.

**Fix**: Added `arena` field to `Program` struct. The `parse()` function now creates an arena allocator that owns all AST allocations, freed in one call via `program.deinit()`.

### 2. Stdlib Interpreter Memory Leaks
`registerStdlib()` created records with `StringArrayHashMapUnmanaged` for module fields, but these weren't freed when the interpreter was destroyed.

**Fix**: Changed `interpret()` to use the interpreter's existing arena allocator for stdlib and builtin registration.

### 3. Symbol Table Memory Leaks
The resolver allocated `parameter_types`, `parameter_names`, and `generic_params` slices for function/type symbols, but `SymbolTable.deinit()` didn't free these.

**Fix**: Added `deinit()` method to `Symbol` that recursively frees nested allocations, called from `SymbolTable.deinit()`.

### 4. Stdlib List Test Leaks
List construction tests allocated cons cells but didn't free them.

**Fix**: Updated tests to use arena allocators for automatic cleanup.

## Files Modified

### Core Changes
- `src/ast/program.zig` - Added `arena` field and updated `deinit()`
- `src/root.zig` - Updated `parse()` to use arena, `interpret()` to use interpreter's arena
- `src/interpreter/interpreter.zig` - Made `arenaAlloc()` public
- `src/symbols/symbol.zig` - Added `deinit()` method to free nested allocations
- `src/symbols/table.zig` - Updated `deinit()` to call `symbol.deinit()`
- `src/modules/loader.zig` - Updated to use arena for parsing, fixed `deinit()` call
- `src/main.zig` - Updated `program.deinit()` calls (no longer takes allocator)

### Test Fixes
- `src/interpreter/tests.zig` - Added `defer program.deinit()`
- `src/stdlib/list.zig` - Fixed tests to use arena allocators
- `src/typechecker/checker.zig` - Added `arena` field to Program literals

## API Changes

### Program.deinit()
```zig
// Old API
program.deinit(allocator);

// New API - no allocator needed, arena handles cleanup
program.deinit();
```

## Testing

```bash
# Build and run tests
zig build test

# Result: 164/164 tests passed, 0 leaks
```
