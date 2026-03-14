# Kira — C Codegen Maturity Plan

## Overview
Mature Kira's C code generation backend from "basic programs work" to "correct, complete, and safe." Reference: DESIGN.md, src/codegen.zig.
Current status: Phases 0-3 complete. 616 total tests pass (18 E2E). Only remaining: example programs `simple_parser.ki`/`word_count.ki` (blocked by closures/list ops/ADT codegen gaps in IR lowerer).

## Phase 0: E2E Test Harness

**Goal:** Build infrastructure that compiles `.ki` → C → binary → run → compare output against interpreter. Everything else depends on this.
**Estimated Effort:** 2-3 days

### Deliverables
- New test file `tests/codegen_e2e_test.zig` with helpers
- `compileToC(allocator, ki_source) -> []const u8` — runs full pipeline in-memory
- `compileCAndRun(allocator, c_source) -> []const u8` — writes C to tmpfile, invokes `cc`, captures stdout
- `interpretAndCapture(allocator, ki_source) -> []const u8` — runs interpreter, captures stdout
- At least 5 passing E2E tests

### Tasks
- [x] Create `tests/codegen_e2e_test.zig`
- [x] Implement `compileToC` helper (model on `buildFileWithIO` in `src/main.zig:1125`)
- [x] Implement `compileCAndRun` helper using `std.process.Child` to invoke `cc` + run binary
- [x] Implement `interpretAndCapture` helper — added stdout capture to `BuiltinContext`, `Interpreter`, and stdlib `io.zig`
- [x] Wire into `build.zig` test step (add third test artifact alongside `mod_tests` and `exe_tests`)
- [x] E2E test: hello world — println output
- [x] E2E test: arithmetic + int_to_string
- [x] E2E test: fibonacci — recursion + int_to_string
- [x] E2E test: conditionals — string return values
- [x] E2E test: factorial — recursion + multiplication
- [x] E2E test: nested function calls
- [x] Skip gracefully if `cc` not available
Note: string concat and ADT pattern matching tests deferred — require codegen fixes (string param type mismatch, variant codegen).

### Testing Strategy
Each test: Kira source as string literal → run through both paths → assert outputs match.

### Phase 0 Readiness Gate
- [x] 5+ E2E tests pass (6 passing)
- [x] `./run-tests.sh` includes E2E tests (604 total tests pass)
- [x] Test harness handles missing C compiler gracefully (returns `error.SkipZigTest`)

---

## Phase 1: Boehm GC Integration

**Goal:** Eliminate all memory leaks in generated C by replacing `malloc()` → `GC_MALLOC()` at all 9 allocation sites.
**Estimated Effort:** 1-2 days

### Deliverables
- `codegen.zig`: all 9 malloc sites emit `GC_MALLOC()`
- Preamble: `#include <gc.h>`
- Entry point: `GC_INIT();` as first line in generated `main()`
- Updated unit tests (31 tests check for `malloc(` in output)
- E2E tests verify GC'd programs run correctly

### Tasks
- [x] Add `#include <gc.h>` in `emitPreamble`
- [x] Add `GC_INIT();` in `emitEntryPoint`
- [x] Replace `malloc(` → `GC_MALLOC(` at all 9 sites in `codegen.zig`
- [x] Update E2E harness to pass `-lgc` (and `-I/opt/homebrew/include -L/opt/homebrew/lib` on macOS)
- [x] Update unit tests that assert `malloc(` → assert `GC_MALLOC(`
- [x] E2E test: heavy-allocation program (10k string concats in loop) doesn't crash or exhaust memory
- [x] Document: GC install instructions added to docs/reference.md (brew, apt, dnf)
- [x] `KIRA_NO_GC` compile flag: `GC_MALLOC` → `KIRA_ALLOC` macro, `GC_INIT()` → `KIRA_GC_INIT()` macro; compile with `-DKIRA_NO_GC` to fall back to plain malloc

### Testing Strategy
Run E2E tests normally — Boehm GC is a drop-in replacement. Optionally verify with `leaks` tool on macOS. Key test: loop allocating many tuples/strings completes without memory growth.

### Phase 1 Readiness Gate
- [x] All 9 sites replaced
- [x] All unit tests updated and passing (604/604)
- [x] E2E tests pass with `-lgc` linking

---

## Phase 2: Stdlib Builtins Expansion

**Goal:** Expand from 6 builtins to full coverage of what the interpreter supports, prioritized by what real programs need.
**Estimated Effort:** 5-7 days

### Deliverables
- 30+ new builtin handlers in `codegen.zig` `call_builtin` branch
- Extended `tryResolveMethodBuiltin` in `lower.zig` for new std.* mappings
- C runtime helpers in preamble for complex builtins (string_trim, string_split, etc.)
- E2E test for each new builtin

### Tasks

**Tier 1 — Already lowered, now codegen'd:**
- [x] `string_char_at` — index into C string, return char as kira_int
- [x] `string_trim` — C preamble helper using `isspace()`
- [x] `string_split` — C preamble helper returning Kira array of strings
- [x] `char_to_int` — identity cast

**Tier 2 — String operations (lowerer + codegen):**
- [x] `string_contains` — `strstr() != NULL`
- [x] `string_starts_with` — `strncmp()`
- [x] `string_ends_with` — `strlen` + `strcmp` at offset
- [x] `string_substring` — C preamble helper
- [x] `string_index_of` — `strstr()` returning offset or -1
- [x] `string_equals` — `strcmp() == 0`
- [x] `string_to_upper` / `string_to_lower` — C preamble helpers
- [x] `string_replace` — C preamble helper
- [x] `string_parse_int` — `strtoll()`, returns Option-encoded variant
- [x] `string_parse_float` — `strtod()`, returns Option-encoded variant
- [x] `string_concat` — verified: `+` on strings lowers to `str_concat` IR, codegen emits strlen+GC_MALLOC+strcpy/strcat

**Tier 3 — Numeric builtins:**
- [x] `int_abs` — ternary
- [x] `int_min` / `int_max` — ternary
- [x] `int_sign` — `(v > 0) - (v < 0)`
- [x] `int_parse` — `strtoll()`
- [x] `float_abs` — `fabs()` with memcpy
- [x] `float_floor` / `float_ceil` / `float_round` — math.h with memcpy
- [x] `float_sqrt` — `sqrt()` with memcpy
- [x] `float_min` / `float_max` — `fmin()` / `fmax()` with memcpy
- [x] `float_is_nan` / `float_is_infinite` — `isnan()` / `isinf()`
- [x] `float_from_int` — `(double)v` with memcpy repack
- [x] `float_parse` — `strtod()`
- [x] `char_from_int` — identity cast
- [x] `math_trunc_to_i64` — `(int64_t)trunc()`

**Tier 4 — IO/Effect builtins:**
- [x] `eprint` — `fprintf(stderr, "%s", ...)`
- [x] `read_line` — `fgets()` with GC_MALLOC buffer, returns Result[string, string]

**Tier 5 — Filesystem & system:**
- [x] `fs_read_file` — `fopen`/`fread`/`fclose`, returns Result[string, string]
- [x] `fs_write_file` — `fopen`/`fwrite`/`fclose`, returns Result[void, string]
- [x] `fs_exists` — `access(path, F_OK)`
- [x] `fs_remove` — `unlink()`, returns Result[void, string]
- [x] `fs_append_file` — `fopen` with "ab" mode, returns Result[void, string]
- [x] `time_now` — `gettimeofday()` returning milliseconds
- [x] `time_sleep` — `usleep()`
- [x] `env_args` — `argc`/`argv` stored in globals by `main(int argc, char** argv)`, `kira_env_args()` preamble helper constructs Kira array
- [x] `assert_eq` / `assert_not_eq` / `assert_contains` — runtime checks with abort

### Implementation Pattern
For each builtin:
1. Add recognition in `lower.zig:tryResolveMethodBuiltin` (map std.module.method → canonical name)
2. Add handler in `codegen.zig` `call_builtin` branch
3. For complex builtins, add C helper function in `emitPreamble`
4. Add unit test verifying generated C text
5. Add E2E test verifying correct runtime behavior

### Testing Strategy
Each builtin gets at least one E2E test. String builtins include empty-string edge cases. Numeric builtins include boundary values. Option-returning builtins test both Some and None paths.

### Phase 2 Readiness Gate
- [x] All Tier 1-3 builtins implemented (30+ new handlers)
- [x] Tier 4 IO builtins implemented
- [x] Tier 5 filesystem/system builtins (8/9 — env_args deferred)
- [x] E2E tests for Tier 5 builtins (6 new tests: fs_write+read, fs_exists, fs_read_error, fs_append, time_now, assert_eq)
- [ ] `simple_parser.ki` and `word_count.ki` examples compile and run correctly (blocked by IR lowerer: closures/list ops/ADT codegen gaps)
- [x] Built-in Option/Result type declarations auto-registered in IR lowerer

---

## Phase 3: Correctness Hardening

**Goal:** Fix remaining correctness gaps — memoization, bounds checking, string comparison, and method_call cleanup.
**Estimated Effort:** 3-4 days

### Deliverables
- Memoization cache for `memo fn` in generated C
- Array/string bounds checking (configurable via `KIRA_BOUNDS_CHECK`)
- String comparison using `strcmp()` instead of pointer equality
- Clean error for unresolved `method_call`

### Tasks

**Memoization:**
- [x] For `memo fn` with single int arg: emit static array cache (wrapper function pattern with `_memo_impl` + caching `kira_<name>` wrapper)
- [x] For general case: emit linked-list cache (`_KiraMemoCache` with `_kira_memo_lookup`/`_kira_memo_store` in preamble)
- [x] E2E test: `memo_fibonacci.ki` compiles and produces correct output (fib 0,1,5,10,20 match interpreter)

**Bounds checking:**
- [x] Wrap `index_get` / `index_set` with bounds check + abort
- [x] Gate behind `#ifdef KIRA_BOUNDS_CHECK` (like existing `KIRA_DEBUG_EFFECTS`)
- [x] E2E test: out-of-bounds access produces clear error message (compiled with `-DKIRA_BOUNDS_CHECK`, verifies abort + stderr)

**String comparison:**
- [x] `cmp` instruction on string operands: emit `strcmp()` instead of `==`
- [x] Codegen pre-scans instructions to track string-typed SSA values (const_string, str_concat, string-returning builtins, string-typed params)
- [x] Verified: `label == "positive"` returns true in compiled C (value comparison, not pointer)

**method_call cleanup:**
- [x] Changed abort message to include function name and SSA value ref
- [x] Audit: trait/impl method calls (e.g. `.eq()`, `.show()`) produce unresolved `method_call` IR — by design, C codegen aborts at runtime since dynamic dispatch requires interpreter. All `std.*` builtins resolve to `call_builtin`.

### Testing Strategy
Memoization: verify `memo_fibonacci(35)` completes quickly (< 1s) — without cache it would take minutes. Bounds checking: verify out-of-bounds produces descriptive abort. String comparison: verify string equality works by value.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Boehm GC unavailable in CI | Blocks Phase 1 tests | Medium | `--no-gc` fallback; document install |
| `intptr_t` casts confuse conservative GC | Phantom leaks | Low | Boehm handles interior pointers; test under stress |
| String pointer equality (current `cmp`) | Silent bugs in real programs | High | Fix in Phase 3; add E2E test early |
| Complex builtins (split, replace) edge cases | Wrong output | Medium | Comprehensive E2E tests with edge cases |
| Memoization cache unbounded growth | OOM for long-running programs | Medium | Fixed-size cache; document limitation |
| gcc vs clang differences | Subtle codegen bugs | Low | Use C99 only; test with both in CI |

## Timeline

```
Phase 0 (E2E Harness)        [2-3 days]  ← Foundation, no dependencies
Phase 1 (Boehm GC)           [1-2 days]  ← Depends on Phase 0 for verification
Phase 2 (Stdlib Builtins)     [5-7 days]  ← Depends on Phase 0; Phase 1 for GC in helpers
Phase 3 (Correctness)         [3-4 days]  ← Depends on Phases 0-2
                              -----------
Total:                        11-16 days
```

## Critical Files
- `src/codegen.zig` — All phases: malloc→GC_MALLOC, new builtins, bounds checks, memoization
- `src/ir/lower.zig:1039` — Phase 2: extend `tryResolveMethodBuiltin` for new std.* mappings
- `src/ir/ir.zig` — Phase 3: possibly add type info to `cmp` instruction for string comparison
- `src/main.zig:1125` — Phase 0: model for `compileToC` helper
- `build.zig:141` — Phase 0: wire E2E test module into test step
- `tests/codegen_e2e_test.zig` — Phase 0: new file
