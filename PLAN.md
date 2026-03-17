# Kira Compiler — std.* Codegen & Cross-Module Import Plan

## Overview
Complete the compiler backend so `kira build` can compile programs that use standard library functions and cross-module imports.
Current status: Phase 0 complete, Phase 1 next.

## Phase 0: Audit & Complete std.* Builtin Coverage ✅
**Status:** Complete (2026-03-16)

**Goal:** Every std.* function recognized by the interpreter should also be recognized by the IR lowerer and have a C codegen implementation.

**Estimated Effort:** 2-3 days

### Deliverables
- [x] All ~151 std functions lowered via `call_builtin`
- [x] All ~151 std functions codegen'd to C
- [x] Downstream projects that don't use imports can `kira build` successfully

### Tasks
- [x] Audit: diff interpreter stdlib registry against lowerer to produce a gap list (99 missing of 151)
- [x] Create unified `resolveStdBuiltin()` in lower.zig — single source of truth for all std.* resolution
- [x] Add missing std.list builtins (22: `empty`, `singleton`, `cons`, `head`, `tail`, `fold`, `fold_right`, `foreach`, `find`, `any`, `all`, `reverse`, `append`, `concat`, `flatten`, `take`, `drop`, `zip`, `parallel_map/filter/fold`)
- [x] Add missing std.option builtins (5: `map`, `and_then`, `unwrap_or`, `is_some`, `is_none`)
- [x] Add missing std.result builtins (6: `map`, `map_err`, `and_then`, `unwrap_or`, `is_ok`, `is_err`)
- [x] Add missing std.convert builtins (i32↔i64, int↔float, int/float↔string)
- [x] Add missing std.map builtins (10: `new`, `get`, `put`, `contains`, `remove`, `keys`, `values`, `entries`, `size`, `is_empty`)
- [x] Add missing std.net builtins (7: `tcp_listen`, `accept`, `read`, `write`, `close`, `close_listener`, `http_request`)
- [x] Add missing std.builder builtins (8: `new`, `append`, `append_char`, `append_int`, `append_float`, `build`, `clear`, `length`)
- [x] Add missing std.string builtins (`concat`, `is_valid_utf8`, `byte_length`, `chars`, `from_bool`, `from_int/i32/i64`, `from_float/f32/f64`)
- [x] Add missing std.fs builtins (4: `read_dir`, `is_file`, `is_dir`, `create_dir`)
- [x] Add missing std.time builtins (1: `elapsed`)
- [x] Add missing std.assert builtins (3: `assert_true`, `assert_false`, `fail`)
- [x] Add C runtime implementations for all new builtins in codegen preamble
- [x] Add codegen dispatch cases for all new builtins
- [x] Add forward-declaration pass (`registerForwardDeclarations`) to resolve cross-function references regardless of declaration order
- [x] Refactor `lowerFunctionDecl` and `lowerLetDecl` to reuse pre-registered placeholders
- [x] Add `isStringReturningBuiltin()` helper to replace hardcoded string-tracking
- [x] Test: `kira build` on kira-brainfuck — **builds successfully**
- [x] Test: `kira build` on kira-test library module — **builds successfully**

### What's Still Missing (deferred)
- std.map codegen: lowerer resolves the names but C runtime hash map not yet implemented (emits `/* unknown builtin */`)
- std.net codegen: lowerer resolves names but C runtime TCP/HTTP not yet implemented
- std.bytes: not yet added (low priority — no downstream project uses it)

---

## Phase 1: Refactor Builtin Dispatch to Table-Driven

**Goal:** Replace the hardcoded if-else chains in the codegen `call_builtin` handler with a single registry table. The lowerer already has a unified `resolveStdBuiltin()` but codegen still has ~100 `else if` branches.

**Estimated Effort:** 1-2 days

### Deliverables
- Codegen dispatch via lookup table instead of if-else chain
- Adding a new builtin requires one table entry + one C implementation
- Extract C runtime helpers into separate section or header

### Tasks
- [x] Create a codegen builtin registry mapping canonical name → C code template
- [x] Refactor codegen `call_builtin` to dispatch via the registry
- [x] Extract C runtime helpers into a dedicated `emitRuntimeHelpers` section (already partially done)
- [ ] Implement C runtime for std.map (simple open-addressing hash table)
- [ ] Implement C runtime for std.net (socket wrappers)
- [x] Verify all existing tests still pass
- [x] Verify downstream projects still build identically

### Testing Strategy
Diff the generated `.c` files before and after refactor — output should be identical for all existing builtins.

### Phase 1 Readiness Gate
Before Phase 2, these must be true:
- [x] All builtins dispatched via registry, no hardcoded names in codegen
- [ ] std.map and std.net have working C runtime implementations
- [x] All 685+ Kira compiler tests pass

---

## Phase 2: Cross-Module Imports

**Goal:** `kira build` on a file with `import` declarations compiles all transitively imported modules and links them into a single C output (or multi-file C project).

**Estimated Effort:** 3-5 days

### Deliverables
- IR lowerer resolves imported function names
- Codegen emits `extern` declarations or concatenates modules
- kira-lpe and kira-http can `kira build` their main entry points

### Tasks
- [ ] Design: decide on single-file vs multi-file C output strategy
- [ ] Extend `lower()` to accept the resolved import map from the type checker
- [ ] When lowering an identifier that matches an imported function, emit `call_direct` with the qualified name
- [ ] When lowering a field access on an imported module (e.g., `loader.load_file()`), resolve to the imported function
- [ ] In codegen: emit `extern` declarations for functions defined in other modules
- [ ] In codegen: if single-file strategy, concatenate all module C outputs in dependency order
- [ ] Handle module-level `let` bindings from imported modules (extend the `lowerLetDecl` fix)
- [ ] Handle re-exported types from imported modules (type declarations must be emitted once)
- [ ] Test: `kira build` on kira-lpe (multi-module project with 24 .ki files)
- [ ] Test: `kira build` on kira-http (11 source files with inter-module deps)

### Testing Strategy
Build kira-lpe and kira-http end-to-end. Compile the generated C with `cc`. Run and compare output to `kira run`.

### Phase 2 Readiness Gate
Before Phase 3, these must be true:
- [ ] `kira build` on multi-module projects produces working C
- [ ] No `UndefinedVariable` errors for imported symbols
- [ ] Generated C compiles without warnings with `-Wall`

---

## Phase 3: End-to-End Validation

**Goal:** All 7 downstream kira-* projects build and produce correct executables.

**Estimated Effort:** 2-3 days

### Deliverables
- All downstream projects pass `kira build`
- Generated C compiles and produces correct output
- BUG.md files updated/cleared across all projects

### Tasks
- [ ] Build and test kira-brainfuck (interpret hello.bf, verify output)
- [ ] Build and test kira-json (run test suite, verify JSON parsing/serialization)
- [ ] Build and test kira-lisp (run REPL commands, verify factorial)
- [ ] Build and test kira-lpe (start REPL, query family database)
- [ ] Build and test kira-http (compile client/server modules)
- [ ] Build and test kira-pcl (compile parser combinators)
- [ ] Build and test kira-test (compile test framework and examples)
- [ ] Fix any remaining codegen issues discovered during testing
- [ ] Update BUG.md in each project to mark build bugs as fixed

### Testing Strategy
For each project: `kira build`, `cc` the output, run the binary, diff output against `kira run`.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| List/Option/Result C runtime needs GC or refcounting | High | Medium | Start with leak-tolerant arena allocator; add refcounting in a future phase |
| HashMap C runtime is complex | Medium | High | Use a simple open-addressing hash table; optimize later |
| Cross-module name collisions in single-file C | Medium | Medium | Prefix all function names with module path (e.g., `kira_loader_load_file`) |
| Closure captures across module boundaries | High | Low | Closures already work within a module; cross-module closures may need special handling |
| Generated C doesn't compile on all platforms | Medium | Low | Target C99; test on macOS (clang) and Linux (gcc) |

## Timeline
- Phase 0: **Complete**
- Phase 1 → Phase 2: sequential (Phase 2 needs clean builtin infrastructure)
- Phase 2 → Phase 3: sequential (Phase 3 validates Phase 2)
- Remaining: ~6-10 days of focused work
