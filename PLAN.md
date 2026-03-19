# Kira Compiler — std.* Codegen & Cross-Module Import Plan

## Overview
Complete the compiler backend so `kira build` can compile programs that use standard library functions and cross-module imports.
Current status: Phase 2 complete, Phase 3 in progress.

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
- std.net HTTPS: http_request works over plain HTTP only (no TLS/SSL support yet)
- std.net record fields: tcp_listen/accept return integer handles; field access like `.port` on listener records not yet supported in compiled output
- std.bytes: not yet added (low priority — no downstream project uses it)

---

## Phase 1: Refactor Builtin Dispatch to Table-Driven ✅
**Status:** Complete (2026-03-16)

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
- [x] Implement C runtime for std.map (array-of-pairs with string keys, all 10 operations)
- [x] Implement C runtime for std.net (POSIX socket wrappers: tcp_listen, accept, read, write, close, close_listener, http_request)
- [x] Fix Option type tag mismatch (Some=0/None=1 runtime convention now matches type declarations)
- [x] Verify all existing tests still pass
- [x] Verify downstream projects still build identically

### Testing Strategy
Diff the generated `.c` files before and after refactor — output should be identical for all existing builtins.

### Phase 1 Readiness Gate
Before Phase 2, these must be true:
- [x] All builtins dispatched via registry, no hardcoded names in codegen
- [x] std.map and std.net have working C runtime implementations
- [x] All 685+ Kira compiler tests pass

---

## Phase 2: Cross-Module Imports

**Goal:** `kira build` on a file with `import` declarations compiles all transitively imported modules and links them into a single C output.

**Estimated Effort:** 3-5 days

### Design Decision: Single-File C Output
**Chosen:** Single-file strategy. All imported modules are lowered into one IR Module and codegen produces one `.c` file.

**Rationale:**
- Aligns with existing architecture (single IR module, single codegen pass)
- Project sizes are small (~42 .ki files max in kira-lpe)
- Avoids complexity of `extern` declarations, headers, and linking
- The resolver/module-loader already loads all dependencies into one symbol table

**Naming convention:**
- Entry module functions: no prefix (e.g., `main`)
- Imported module functions: `modulepath__funcname` (e.g., `logic_repl__repl_main`)
- Each module's import map resolves local names → qualified IR names

### Deliverables
- IR lowerer resolves imported function names via import maps
- All imported modules' declarations lowered into single IR Module
- kira-lpe and kira-http can `kira build` their main entry points

### Tasks
- [x] Design: decide on single-file vs multi-file C output strategy (single-file chosen)
- [x] Add `lowerWithModules()` to Lowerer: accepts entry program + loaded module programs
- [x] Add import map (`import_map`) field to Lowerer: maps local names → qualified IR names
- [x] Build import maps per module from ImportDecl + loaded module function lists
- [x] Register forward declarations for ALL modules (with qualified names for non-entry)
- [x] Modify `lowerFunctionDecl` to apply module prefix to function names
- [x] Modify `tryResolveFuncName` and identifier resolution to check import map
- [x] Lower type declarations from imported modules (pre-registration pass for variant tag resolution)
- [x] Lower module-level `let` and `const` bindings from imported modules (pre-registered constants)
- [x] Update `main.zig`: collect loaded modules from ModuleLoader and pass to lowerer
- [x] Register built-in List type (Nil/Cons) alongside Option and Result
- [x] Test: `kira build` on kira-lpe (21 modules → C compiles with 1 warning)
- [x] Test: `kira build` on kira-lisp (multi-module → C compiles cleanly)
- [x] Test: `kira build` on kira-json (multi-module → C generates successfully)
- [x] Test: `kira build` on kira-http (multi-module → C generates successfully)
- [x] Test: `kira build` on kira-pcl (multi-module → C compiles cleanly)
- [x] Fix: standalone runtime builtins (to_string, to_float, assert) with char type tracking
- [x] Fix: uniform _env calling convention for closures (all functions receive kira_int _env)

### Testing Strategy
Build kira-lpe and kira-http end-to-end. Compile the generated C with `cc`. Run and compare output to `kira run`.

### Phase 2 Readiness Gate
Before Phase 3, these must be true:
- [x] `kira build` on multi-module projects produces working C
- [x] No `UndefinedVariable` errors for imported symbols
- [x] Generated C compiles without errors (closures fixed; remaining warnings are unused vars/labels and null chars)

---

## Phase 3: End-to-End Validation

**Goal:** All 7 downstream kira-* projects build and produce correct executables.

**Estimated Effort:** 2-3 days

### Deliverables
- All downstream projects pass `kira build`
- Generated C compiles and produces correct output
- BUG.md files updated/cleared across all projects

### Tasks
- [x] Build and test kira-brainfuck — C compiles and runs (1 null-char warning)
- [x] Build and test kira-json — C generates successfully
- [x] Build and test kira-lisp — C generates and compiles (REPL: interactive only)
- [x] Build and test kira-lpe — C compiles and runs (1 null-char warning, REPL: interactive only)
- [x] Build and test kira-http — C generates successfully
- [x] Build and test kira-pcl — C compiles cleanly (library, no main)
- [x] Build and test kira-test — C compiles cleanly (library, no main)
- [x] Fix closure codegen: uniform _env calling convention
- [x] Fix pointer invalidation: replace cached func pointers with self.currentFunc() calls
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
- Phase 1: **Complete**
- Phase 1 → Phase 2: sequential (Phase 2 needs clean builtin infrastructure)
- Phase 2: **Complete**
- Phase 3: All 7 projects build and compile successfully
- Remaining: BUG.md cleanup across projects
