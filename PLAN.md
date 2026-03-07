# Kira-Klar Interop — Implementation Plan

## Overview

Make Kira libraries seamlessly callable from Klar projects. The current
interop module (`src/interop/klar.zig`) has type-mapping infrastructure and
header/extern-block generation, but everything emits hardcoded `int64_t`/`i64`
because the IR strips type information during lowering. The C backend
(`src/codegen.zig`) uses a uniform `kira_int` (i64) representation for all
values, with float bit-punning and string pointer casting.

This plan threads real types through the pipeline and builds the `--lib`
workflow so a Kira module can be compiled, linked, and called from Klar
with zero manual steps.

Reference: [PLAN-interop.md](PLAN-interop.md) (original design),
[DESIGN.md](DESIGN.md).

Current status: Phase 0 complete.

---

## Phase 0: Thread Type Information Through IR ✅
**Status:** Complete (2026-03-06)

**Goal:** IR functions carry source-level type names so header/extern-block
generation can emit correct C and Klar types instead of hardcoded `int64_t`.

**Estimated Effort:** 1 day

### Deliverables
- `ir.Function` gains a `return_type_name: []const u8` field
- `ir.Function.Param` gains a `type_name: []const u8` field
- `generateHeader()` and `generateKlarExternBlock()` use real types
- All existing tests still pass; new tests cover type-correct output

### Tasks
- [x] Add `type_name: []const u8` field to `ir.Function.Param` in `src/ir/ir.zig` — default `"i64"` for backwards compatibility. Add `return_type_name: []const u8` to `ir.Function` with default `"i64"`.
- [x] Thread AST type info through `lowerFunctionDecl` in `src/ir/lower.zig` — the lowerer already has access to `param.param_type` (it calls `isAstTypeFloat` on it). Add a helper `astTypeToName(*Type) []const u8` that maps primitive types to their canonical names (`i32`, `i64`, `f64`, `bool`, `string`, `void`). Populate `Param.type_name` and `Function.return_type_name` during lowering. Also update the closure lowering path (~line 919) to thread param types.
- [x] Update `generateHeader()` in `src/interop/klar.zig` — replace the hardcoded `"int64_t"` with `kiraToCType(param.type_name)` and `kiraToCType(func.return_type_name)`.
- [x] Update `generateKlarExternBlock()` in `src/interop/klar.zig` — replace hardcoded `"i64"` with `kiraToKlarType(param.type_name)` and `kiraToKlarType(func.return_type_name)`.
- [x] Add tests: `fn add(a: i32, b: i32) -> i32` emits `int32_t add(int32_t a, int32_t b)` in header and `fn add(a: i32, b: i32) -> i32` in Klar extern block. Cover `f64`->`double`, `bool`->`bool`/`Bool`, `string`->`const char*`/`CStr`, `void`->`void`/`Void`.

### Testing Strategy
Extend unit tests in `src/interop/klar.zig`. Build a multi-function IR module
with mixed types programmatically, generate header and extern block, verify
output strings contain correct C/Klar types.

---

## Phase 1: Library Build Mode

**Goal:** `kira build --lib mylib.ki` produces `mylib.c`, `mylib.h`, and
`mylib.kl` — a C source file without a `main` wrapper, a type-correct header,
and a Klar extern block.

**Estimated Effort:** 2 days

### Deliverables
- `--lib` flag on `kira build` that skips `main` requirement
- `--emit-header` flag that generates `.h` and `.kl` without compiling
- Generated `.h` and `.kl` files written alongside output
- Documentation in `docs/reference.md`

### Tasks
- [ ] Add `--lib` flag to `buildFile()` in `src/main.zig` — when set, pass a `library_mode: bool` through to codegen. In library mode: (a) don't error if no `main` function, (b) after generating `.c`, also call `generateHeader()` and `generateKlarExternBlock()` and write the results to `.h` and `.kl` files alongside the `.c` output.
- [ ] Update `CCodeGen` to support library mode in `src/codegen.zig` — in library mode, skip emitting the `main` wrapper function (if any special main handling is added later). Currently codegen emits all functions uniformly, so this may be a no-op initially, but the flag should exist for Phase 2 work.
- [ ] Add `--emit-header` flag to `buildFile()` — lighter alternative that only runs parse/resolve/typecheck/lower and then generates `.h` and `.kl` files without codegen. Useful for tooling and AI agents that only need the interface.
- [ ] Document library build mode in `docs/reference.md` — add a "Building Libraries" section covering `--lib` and `--emit-header` flags, the generated file layout, and the workflow for consuming from Klar.
- [ ] Add integration tests — verify `--lib` produces all three files, verify `--emit-header` produces only `.h` and `.kl`, verify a module with no `main` succeeds with `--lib` and fails without it.

### Testing Strategy
End-to-end: write a Kira module with `add(a: i32, b: i32) -> i32`, build with
`--lib`, verify `.c`, `.h`, and `.kl` files are created with correct content.

### Phase 1 Readiness Gate
Before Phase 2, these must be true:
- [ ] `kira build --lib` produces `.c`, `.h`, and `.kl` files
- [ ] Generated `.h` has correct C types for all exported functions
- [ ] Generated `.kl` has correct Klar extern block with proper types
- [ ] A module with no `main` compiles successfully in `--lib` mode

---

## Phase 2: ADT Interop Convention

**Goal:** Define and implement a C-compatible representation for Kira algebraic
data types so Klar can receive and pattern-match on them across the FFI boundary.

**Estimated Effort:** 3 days

### Deliverables
- Design document: `docs/design/adt-interop.md`
- C struct layout for Kira sum types (tagged union) and product types
- Header generation emits ADT struct definitions
- Klar extern block includes matching `extern struct`/`extern enum`

### Tasks
- [ ] Write `docs/design/adt-interop.md` — define the C layout convention: tag enum (int32_t, 0-indexed by declaration order) + union of payloads for sum types; plain struct for product types. Define the threshold for opaque pointers (types > 64 bytes or recursive types). Cover: simple enums, single-payload variants, multi-payload variants, nested ADTs, and recursive types.
- [ ] Thread ADT type information through IR — `ir.Function` params and return types need to reference user-defined types, not just primitives. Extend `astTypeToName` (from Phase 0) to handle named types, and add an `ir.TypeDef` struct to `ir.Module` that describes exported ADTs.
- [ ] Implement ADT header generation in `src/interop/klar.zig` — for each exported sum type, emit a C `enum` for tags and a `struct` with tag + union. For product types, emit a plain C struct. Handle recursive types via pointer fields.
- [ ] Implement ADT Klar extern block generation — emit `extern enum` for tags and `extern struct` for data layout matching the C structs.
- [ ] Add tests: `type Shape = Circle(f64) | Rectangle(f64, f64)` produces correct tagged union in header and matching extern declarations in Klar block.

### Testing Strategy
Round-trip test: build a Kira module exporting a function that returns an ADT,
verify the generated header and Klar block contain correct struct definitions.
Test recursive types produce pointer-based layouts.

---

## Phase 3: String and Memory Convention

**Goal:** Establish clear ownership rules for values crossing the Kira-Klar
boundary and implement runtime support for safe string passing.

**Estimated Effort:** 2 days

### Deliverables
- Design document: `docs/design/interop-memory.md`
- String marshaling in C backend (borrowed `const char*` out, copied on entry)
- `kira_free()` export for Klar to free Kira-allocated heap values
- Generated Klar wrappers for string-returning functions

### Tasks
- [ ] Write `docs/design/interop-memory.md` — ownership rules: (1) Kira->Klar strings are borrowed `const char*` valid for call duration, (2) Klar->Kira strings are copied on entry, (3) returned ADTs by-value are caller-owned, (4) returned ADTs via pointer require `kira_free()`.
- [ ] Implement string marshaling in codegen — when a Kira library function returns `string`, emit code returning `const char*` to a stable buffer. When accepting `string`, emit a copy from `const char*` into Kira-managed memory.
- [ ] Add `kira_free(void* ptr)` to library builds — exported function Klar can call to free Kira-allocated memory (for heap ADT values). Emit it in the generated C and declare it in the header.
- [ ] Generate Klar wrapper functions for string-returning Kira functions — the `.kl` extern block should include a safe wrapper that converts `CStr` to Klar `string`.
- [ ] Add tests: string round-trip (pass string Klar->Kira->Klar, verify equality), verify `kira_free` is declared in header, verify wrapper functions appear in `.kl`.

### Testing Strategy
Verify generated C code handles string ownership correctly. Test that the
header includes `kira_free`. Test wrapper function generation in Klar block.

---

## Phase 4: Build System Integration

**Goal:** A Kira dependency can be declared in `kira.toml` with an `[exports]`
section and built automatically with machine-readable output.

**Estimated Effort:** 3 days

### Deliverables
- `[exports]` section in `kira.toml` defining public API modules
- Type manifest JSON describing exported functions and types
- `--manifest` flag for tooling/AI agent consumption
- User guide: `docs/guide/klar-interop.md`

### Tasks
- [ ] Define `[exports]` section in `kira.toml` — list of module names whose public functions are exported. Default: none (opt-in). Update `src/config/project.zig` to parse this section. Only listed modules appear in generated header/extern block.
- [ ] Generate type manifest JSON alongside `--lib` build — machine-readable JSON with all exported functions, parameter types, return types, and ADT definitions. Write to `<name>.json` alongside other outputs.
- [ ] Add `--manifest` flag to `kira build` — emits only the JSON manifest without compiling. Useful for tooling and AI agents that need the interface description.
- [ ] Write `docs/guide/klar-interop.md` — step-by-step guide: create Kira library, build with `--lib`, add to Klar project, import and call. Include AI agent workflow.
- [ ] End-to-end integration test — Kira library with arithmetic, string, and ADT-returning functions. Build with `--lib`, verify all output files, verify manifest JSON is valid and complete.

### Testing Strategy
Full workflow test: Kira module with mixed function types, build with `--lib`,
verify `.c`, `.h`, `.kl`, and `.json` outputs. Parse manifest JSON and verify
it matches the source declarations.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| IR type threading breaks existing codegen | High | Medium | Codegen ignores new fields (defaults to `kira_int`); only interop reads them |
| ADT layout diverges from Klar extern struct expectations | High | Medium | Test with actual Klar compilation early in Phase 2 |
| String ownership bugs cause use-after-free | High | Medium | Conservative default (always copy); optimize later |
| Recursive ADT detection misses indirect cycles | Medium | Low | Start with direct self-reference only; extend later |
| `kira.toml` parsing changes break existing projects | Medium | Low | New `[exports]` section is opt-in; absent = no exports |

## Timeline

```
Phase 0 --(1d)--> Phase 1 --(2d)--> Phase 2 --(3d)--> Phase 3 --(2d)--> Phase 4
fix types          lib build          ADT interop       memory/strings     build integration
```

- **Phase 0 -> 1:** Sequential — correct types needed before library output
- **Phase 1 -> 2:** Sequential — library build needed before ADT testing
- **Phase 2 and 3:** Could be parallelized — ADT layout and string conventions are independent
- **Phase 4:** Requires Phases 1-3 — build integration wraps everything together
