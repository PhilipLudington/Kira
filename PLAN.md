# Kira — IR Lowerer & Codegen: Example Programs

## Overview
Make `examples/simple_parser.ki` and `examples/word_count.ki` compile to C and run correctly, matching interpreter output. Reference: src/ir/lower.zig, src/codegen.zig.
Current status: Phase 0 complete. 617 total tests pass (19 E2E). Phase 1 next.

## Phase 0: Codegen Type Casting Fixes

**Goal:** Fix type mismatches in generated C for string/float parameter passing.
**Estimated Effort:** < 1 day

### Deliverables
- String params properly cast between `const char*` and `kira_int` at load and call sites
- `simple_parser.ki` compiles to C, runs, and matches interpreter output
- E2E test confirming simple_parser behavior

### Tasks
- [x] Fix `simple_parser.ki` integer literal types (`0` → `0i64`)
- [x] Codegen: cast string params to `(kira_int)(intptr_t)` in `.param` instruction
- [x] Codegen: cast string args to `(const char*)(intptr_t)` in `.call_direct` instruction
- [x] Codegen: cast float params via `memcpy` in `.param` instruction
- [x] E2E test: `simple_parser.ki` compiles and matches interpreter output (ADTs, pattern matching, recursion, Result type)
- [x] Verify: all 617 tests pass

### Testing Strategy
Compile simple_parser.ki → C → binary → run → compare with interpreter output.

### Phase 0 Readiness Gate
- [x] `simple_parser.ki` E2E test passes
- [x] All existing tests pass (617/617)

---

## Phase 1: std.list Builtins for C Codegen

**Goal:** Lower `std.list.map`, `std.list.filter`, `std.list.length` to IR builtins and implement as C runtime helpers operating on Kira arrays.
**Estimated Effort:** 2-3 days

### Deliverables
- IR lowerer resolves `std.list.*` function calls to `call_builtin` instructions
- C preamble helpers: `kira_list_map`, `kira_list_filter`, `kira_list_length`
- Closure-as-argument calling convention in C helpers
- `word_count.ki` compiles to C, runs, and matches interpreter output

### Tasks

**Lowerer changes (src/ir/lower.zig):**
- [ ] Expand `tryResolveBuiltin` to match `std.list.<method>` patterns (3-level field access: `std` → `list` → method)
- [ ] Map: `std.list.map` → `list_map`, `std.list.filter` → `list_filter`, `std.list.length` → `list_length`
- [ ] Verify closures in arguments are lowered correctly as `make_closure` values

**Codegen changes (src/codegen.zig):**
- [ ] Add `kira_list_length(arr)` preamble helper — return `arr[0]`
- [ ] Add `kira_list_map(arr, fn_ptr)` preamble helper — iterate array, call function on each element, return new array
- [ ] Add `kira_list_filter(arr, fn_ptr)` preamble helper — iterate array, call predicate, collect matching elements
- [ ] Handle closure calling convention: closure value `kira_int*` has `[0]` = function pointer; call via cast
- [ ] Add `list_map`, `list_filter`, `list_length` handlers in `call_builtin` branch

**Example fixes (examples/word_count.ki):**
- [ ] Fix any type annotation issues (e.g., `List[string]` → `[string]` if needed for codegen)

**Tests:**
- [ ] Unit test: verify generated C for list_map/filter/length builtins
- [ ] E2E test: `word_count.ki` compiles and matches interpreter output

### Implementation Pattern
For each list builtin:
1. Add recognition in `tryResolveBuiltin` (match `std.list.<method>` 3-level field access)
2. Add C helper function in `emitPreamble`
3. Add handler in `call_builtin` codegen branch
4. Add unit test + E2E test

### Testing Strategy
word_count.ki: compile → run → compare output with interpreter. Key validation: list operations (map, filter, length) produce correct results on string arrays from `std.string.split`.

### Phase 1 Readiness Gate
- [ ] `word_count.ki` E2E test passes
- [ ] All existing tests pass
- [ ] Both example programs compile and match interpreter output

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Closure calling convention mismatch | C helper can't call closures | High | Test with simple closures first; match `make_closure` layout |
| `string_split` returns array not list | Type mismatch with list ops | Medium | Verify `string_split` codegen returns same format list helpers expect |
| Generic args ignored in lowering | Wrong specialization | Low | Generic args are erased; Kira arrays are uniform `kira_int*` |
| Closures with captures in list ops | Capture env not passed | Medium | Test capture-free closures first; extend helper for captures |

## Timeline

```
Phase 0 (Type Casting)          [< 1 day]  ← Nearly done
Phase 1 (std.list Builtins)     [2-3 days] ← Depends on Phase 0
                                -----------
Total:                          2-4 days
```

## Critical Files
- `src/ir/lower.zig` — Phase 1: expand `tryResolveBuiltin` for `std.list.*`
- `src/codegen.zig` — Both phases: param casting, list helper preamble, call_builtin handlers
- `examples/simple_parser.ki` — Phase 0: integer literal fix
- `examples/word_count.ki` — Phase 1: target example
- `tests/codegen_e2e_test.zig` — Both phases: new E2E tests
