# Kira — Klar Interop Plan

## Overview

Make Kira libraries seamlessly callable from Klar projects. Kira compiles to C and has a full interop module (`src/interop/klar.zig`) with type-correct header generation, Klar extern blocks, ADT support, library wrappers, string marshaling, and JSON manifests.

Reference: [DESIGN.md](DESIGN.md) section "Implementation Notes".

Current status: Phases 0–4 complete. Remaining work is hardening (E2E tests, recursive ADT cycles, performance optimizations).

---

## Phase 0: Fix Type Mapping ✅
**Status:** Complete

### Deliverables
- [x] `kiraToCType()` maps all Kira primitives to C types (i32→int32_t, f64→double, string→const char*, etc.)
- [x] `kiraToKlarType()` maps all Kira primitives to Klar FFI types (i32→i32, string→CStr, bool→Bool, etc.)
- [x] `kiraToCTypeAlloc()` handles user-defined types (→ kira_{Name})
- [x] IR preserves source-level types: `ir.Function.return_type_name` and `ir.Function.Param.type_name`
- [x] 28 unit tests covering type mapping, header generation, extern blocks, ADT types, wrappers, and manifests

---

## Phase 1: Library Build Mode ✅
**Status:** Complete

### Deliverables
- [x] `--lib` flag in `src/main.zig` — produces .c, .h, .kl, and .json files
- [x] `--emit-header` flag — generates .h and .kl only (no C compilation)
- [x] `--manifest` flag — generates .json manifest only
- [x] `main` function not required in library mode
- [x] `generateLibraryWrappers()` bridges typed C API and internal kira_int representation

---

## Phase 2: ADT Interop Convention ✅
**Status:** Complete

### Deliverables
- [x] `docs/design/adt-interop.md` — C layout for sum types (tagged unions) and product types (plain structs)
- [x] `emitHeaderTypeDecls()` — generates C tag enums, variant payload structs, and tagged union structs
- [x] `emitKlarTypeDecls()` — generates Klar extern enum/struct matching C layout
- [x] Variant selection picks largest variant by byte size for ABI compatibility
- [x] Tag numbering: 0-indexed, declaration order

---

## Phase 3: String and Memory Convention ✅
**Status:** Complete

### Deliverables
- [x] `docs/design/interop-memory.md` — ownership rules for strings, ADTs, and lists
- [x] String marshaling: Kira→Klar strings are borrowed `const char*`; Klar→Kira strings are copied
- [x] `emitKlarStringWrappers()` — auto-generated `_str` convenience functions with `String.from_cstr()`/`String.to_cstr()` conversion
- [x] `kira_free(void* ptr)` exported in library builds for cross-language memory management
- [x] Float marshaling via memcpy bit-punning (f32 widened to double first)
- [x] Collision detection: skips wrapper generation if `{name}_str` would collide

---

## Phase 4: Build System Integration ✅
**Status:** Complete

### Deliverables
- [x] `[exports]` section in kira.toml — controls which modules generate interop files
- [x] `generateManifestJSON()` — machine-readable JSON describing exported functions and types
- [x] `--manifest` flag for manifest-only output (no compilation)
- [x] `docs/guide/klar-interop.md` — step-by-step workflow guide

---

## Phase 5: Hardening (Not Started)

**Goal:** Close remaining gaps in test coverage and handle edge cases.
**Estimated Effort:** 2–3 days

### Tasks
- [ ] Add E2E interop tests to `tests/codegen_e2e_test.zig` — build a Kira library module, verify .h/.kl/.json output contents, compile the generated C with a test harness that calls the exported functions
- [ ] Implement indirect recursive ADT detection — currently only direct self-references are handled; indirect cycles (A → B → A) need pointer indirection
- [ ] Add size-based pass-by-pointer optimization — types exceeding 64 bytes should use opaque pointers instead of inline structs (documented in `docs/design/adt-interop.md` but not implemented)
- [ ] Cross-language round-trip test — Klar program calls Kira functions in a loop, verify no memory growth (LeakSanitizer or manual tracking)

### Future Work (Deferred)
- [ ] Arena allocator for returned strings (noted in `docs/design/interop-memory.md`)
- [ ] Reference counting for shared strings across the boundary

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| ~~C backend doesn't preserve type info in IR~~ | ~~High~~ | ~~Medium~~ | **Resolved** — IR has `return_type_name` and `Param.type_name` |
| ADT layout diverges from Klar's extern struct expectations | High — runtime crashes | Low | Test with actual Klar compilation; design docs specify exact layout |
| String ownership bugs cause use-after-free | Medium — memory safety | Low | Conservative default (borrowed strings, copy on entry); `kira_free` for heap values |
| Indirect recursive ADTs crash at codegen | Medium — limits expressiveness | Medium | Currently deferred; add cycle detection in Phase 5 |
| ~~`ar` not available on all platforms~~ | ~~Low~~ | ~~Low~~ | **Mitigated** — library mode emits .c/.h/.kl/.json; archiving is optional |
