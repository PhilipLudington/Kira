# Phase 7 IR — QA Review Issues

Resume here to fix remaining issues found during QA review of the IR module.

## FIXED

### C1: Binary ops always emit `int_binop` for floats ✅
- Added `isFloatValue()` helper that inspects operand instructions
- `lowerBinaryOp` now emits `float_binop` when operands are float-typed

### C2: Unary negate always emits `int_neg` for floats ✅
- `lowerUnaryOp` now emits `float_neg` when operand is float-typed

### C3: `lowerLoopStatement` discards `exit_blk` ✅
- Added `break_target: ?BlockId` field to Lowerer
- `lowerLoopStatement` and `lowerWhileLoop` set `break_target` before lowering body
- `break_statement` emits `jump` to `break_target` instead of `ret null`

### C4: `lowerForLoop` doesn't loop ✅
- Implemented proper loop structure with header, body, and exit blocks
- Binds loop variable via pattern, back-edge jumps to header
- Iterator protocol uses placeholder values (full implementation is future work)

### C5: Param ValueRefs collide with instruction ValueRefs ✅
- Added `param` and `capture` instruction ops to reserve ValueRef slots
- Params now emitted as instructions in the entry block
- Removed `next_value` field and `freshValue()` — addInstruction auto-numbers

### C6: Constructor pattern check compares integer tag against string ✅
- Added `lookupVariantTag()` helper that searches module type declarations
- `lowerPatternCheck` now emits `const_int` with numeric tag, not `const_string`

### H1-H3: Memory leaks (instruction slices, TypeDecl slices, Function fields) ✅
- Added `arena: std.heap.ArenaAllocator` to `Module`
- All IR-internal allocations go through the arena
- `Module.deinit()` frees arena in one shot — no individual slice freeing needed

### H4: No `errdefer` on partially-built functions ✅
- Added errdefer cleanup in `lowerFunctionDecl`
- Arena approach also mitigates this (Module.deinit frees everything)

### H5: `toOwnedSlice` args leak on emit failure ✅
- Fixed by using arena allocator for all `toOwnedSlice` calls
- Arena frees everything on Module.deinit regardless of error paths

### H6: DCE marks operands of dead instructions as used ✅
- Switched to mark-and-sweep from live roots (terminators + side-effectful instructions)
- Phase 1: seed with live roots, Phase 2: transitively mark operands until stable
- Added test verifying transitive dead chain elimination

### H8: Closures always have empty capture list (partial) ✅
- Added `collectFreeVariables()` that walks closure body for outer-scope references
- Emits `capture` instructions and populates `make_closure.captures`
- Basic identifier-level capture (deeper expression walking is partial)

### H9: `constantFold`/`eliminateDeadCode` exported as top-level API ✅
- Removed individual pass exports from `root.zig`
- Only `optimizeIR` is now public

### L1: Dead `false_val` emission in `lowerLogicalAnd` ✅
- Removed unused `const_bool false` emission

### L2: `lowerMatchBody` for blocks always returns `const_void` ✅
- Now checks if last statement is `expression_statement` and returns its value

### L3: Method calls encoded as `call(const_string "name")` ✅
- Added `method_call` instruction op with `object`, `method`, `args` fields
- `lowerMethodCall` now emits `method_call` instead of `call` with string callee

### L4: `lowerNullCoalesce` hardcodes `Some` tag as 0 ✅
- Uses `lookupVariantTag("Some")` to find numeric tag from type declarations
- Falls back to 0 if type declaration not found

### L5: Unused re-exports in `ir.zig` ✅
- Removed `PrimitiveType`, `EffectAnnotation`, `ResolvedType` re-exports

## REMAINING

### H7: Or-pattern bindings only process first alternative
- **File:** `src/ir/lower.zig` (`lowerPatternBindings`)
- Current code uses first alternative's bindings
- For correctness, should emit phi nodes for bindings from all alternatives
- Low-impact: correct when all alternatives bind the same names to same positions (common case)

## Test Status
- 394 tests passing, 0 failures, 0 leaks
