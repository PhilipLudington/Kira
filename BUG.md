# Kira Compiler Bugs

## [x] Bug 1: IR lowering cannot resolve module-level `let` bindings

**Status:** Fixed

**Root cause:** `lowerLetDecl` was a no-op — module-level `let` bindings were completely skipped during IR lowering. When another function referenced a `let`-bound function (e.g. `make_num()`), it wasn't in the function map, constants list, or any scope, causing `UndefinedVariable`.

**Fix:** Implemented `lowerLetDecl` to handle closure values by emitting them as named IR functions (mirroring `lowerFunctionDecl`), and non-closure values by evaluating them as compile-time constants (mirroring `lowerConstDecl`).

## [x] Bug 2: IR lowering cannot resolve `std.*` standard library calls

**Status:** Fixed

**Root cause:** Only ~54 of ~151 std.* functions were hardcoded in `tryResolveBuiltin` and `tryResolveMethodBuiltin`. Missing functions caused `std` to be looked up as a local variable, failing with `UndefinedVariable`.

**Fix:** Created unified `resolveStdBuiltin()` function covering all std modules: io, int, float, string, char, math, list (22 functions), option (5), result (6), map (10), fs (9), time (3), env, assert, convert, builder (8), net (7). Added corresponding C runtime implementations and codegen dispatch cases. Also added forward-declaration pass (`registerForwardDeclarations`) to resolve cross-function references regardless of declaration order.

**Impact:** kira-brainfuck now builds successfully. Single-module projects without imports can now `kira build`.

## [x] Bug 3: IR lowering cannot resolve imported functions from other modules

**Status:** Fixed

**Root cause:** Two issues: (1) Cross-module import support was missing from the IR lowerer — imported symbols were not registered in the function map. (2) Standalone runtime builtins (`to_string`, `to_float`, `assert`) used as bare function calls were not recognized by the IR lowerer.

**Fix:** (1) Phase 2 of PLAN.md implemented `lowerWithModules()` with import maps, qualified naming (`prefix__name`), and forward declarations for all imported modules. (2) Added `tryResolveStandaloneBuiltin()` to handle bare runtime builtins with type-aware dispatch (e.g., `to_string` dispatches to `char_to_string`/`float_to_string`/`int_to_string` based on tracked argument type). Added `char_refs` tracking parallel to existing `float_refs`. Added C runtime implementations for `kira_char_to_string` and `kira_assert`.

**Impact:** All multi-module downstream projects now build: kira-lpe, kira-http, kira-lisp, kira-json, kira-pcl.
