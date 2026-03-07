# Kira — Klar Interop Plan

## Overview

Make Kira libraries seamlessly callable from Klar projects. Kira already compiles to C and has a basic interop module (`src/interop/klar.zig`), but the current implementation hardcodes all types to `int64_t` and requires manual steps. This plan closes the gaps so an AI agent (or human) can add a Kira dependency to a Klar project and call it without friction.

Reference: [DESIGN.md](DESIGN.md) section "Implementation Notes", [ROADMAP.md](ROADMAP.md) Phase 4 Interoperability.

Current status: Phase 0 not started.

---

## Phase 0: Fix Type Mapping

**Goal:** Generated C headers and Klar extern blocks use actual Kira types instead of hardcoded `int64_t`.
**Estimated Effort:** 1 day

### Deliverables
- Updated `src/interop/klar.zig` that reads IR type information
- Correct C header output for all primitive types
- Correct Klar extern block output with matching types

### Tasks
- [ ] Thread IR return-type and parameter-type information through `generateHeader()` — replace the hardcoded `int64_t` on lines 75 and 84 with calls to `kiraToCType()` using actual IR type data. (per `src/interop/klar.zig`) Tests should cover: `fn add(a: i32, b: i32) -> i32` emits `int32_t add(int32_t a, int32_t b)`, f64 params emit `double`, bool emits `bool`, string emits `const char*`, void return emits `void`.
- [ ] Thread IR type information through `generateKlarExternBlock()` — replace hardcoded `i64` on lines 114 and 117 with calls to `kiraToKlarType()`. Tests should cover: Klar extern block uses `i32`, `f64`, `CStr`, `Bool` etc. matching the Kira source types.
- [ ] Add IR type information to `ir.Function.Param` if not already present — ensure the IR preserves source-level type names through lowering. Tests should cover: after IR lowering, function params retain their declared types.

### Testing Strategy
Extend existing tests in `src/interop/klar.zig` to verify type-correct output for each primitive type. Add a new integration test: compile a multi-function Kira module, generate header, verify header contents match expected C types.

---

## Phase 1: Library Build Mode

**Goal:** `kira build --lib` produces a static library (`.a`) plus a C header and Klar extern block, ready for linking.
**Estimated Effort:** 2 days

### Deliverables
- `kira build --lib mylib.ki` produces `mylib.a`, `mylib.h`, `mylib.kl` (extern block)
- No `main()` function required in library mode
- Header and extern block files written alongside the archive

### Tasks
- [ ] Add `--lib` flag to `kira build` in `src/main.zig` — when set, compile to `.o` without requiring a `main` function, then archive into `.a` using `ar`. Emit the `.h` and `.kl` files by calling `generateHeader()` and `generateKlarExternBlock()`. Tests should cover: a module with two public functions and no main produces `.a`, `.h`, and `.kl` files.
- [ ] Skip `main` requirement in library mode — the C backend currently assumes a `main` entry point. In `--lib` mode, omit the `main` wrapper and only emit exported functions. Tests should cover: a module with no `main` compiles successfully with `--lib`, fails without it.
- [ ] Add `--emit-header` flag as a lighter alternative — only generates the `.h` and `.kl` files without compiling. Useful for AI agents that only need the interface. Tests should cover: `--emit-header` produces correct files without invoking the C compiler.
- [ ] Document library build mode in `docs/reference.md` — add a section on building Kira libraries for Klar consumption, including the full workflow.

### Testing Strategy
End-to-end test: write a Kira module with `add(a: i32, b: i32) -> i32`, build with `--lib`, verify `.a` exists and `nm` shows the symbol, verify `.h` has correct declaration, verify `.kl` has correct extern block.

### Phase 1 Readiness Gate
Before Phase 2, these must be true:
- [ ] `kira build --lib` produces a linkable `.a` file
- [ ] Generated `.h` has correct types for all exported functions
- [ ] Generated `.kl` has correct Klar extern block
- [ ] A Klar program can link against the `.a` and call the functions

---

## Phase 2: ADT Interop Convention

**Goal:** Define a C-compatible representation for Kira algebraic data types so Klar can receive and pattern-match on them.
**Estimated Effort:** 3 days

### Deliverables
- C struct layout convention for Kira ADTs (tagged union)
- Generated C header includes ADT struct definitions
- Generated Klar extern block includes matching `extern struct` and `extern enum` definitions
- Design document: `docs/design/adt-interop.md`

### Tasks
- [ ] Write `docs/design/adt-interop.md` — define the C layout for Kira sum types. Proposed: `struct KiraShape { int32_t tag; union { double circle_radius; struct { double w, h; } rectangle; } data; }`. Define tag numbering (0-indexed, declaration order). Define when to use opaque pointers vs inline structs (threshold: types > 64 bytes use pointers). Tests should cover: document covers simple enums, single-payload variants, multi-payload variants, nested ADTs, and recursive types.
- [ ] Implement ADT header generation in `src/interop/klar.zig` — for each exported Kira type that is a sum type, emit a C struct with tag enum + union. For record types, emit a plain C struct. Tests should cover: `type Shape = Circle(f64) | Rectangle(f64, f64)` produces a tagged union struct in the header.
- [ ] Implement ADT Klar extern block generation — emit `extern enum` for the tag and `extern struct` for the data layout. Tests should cover: generated Klar code compiles and can read the tag field.
- [ ] Handle recursive types via opaque pointers — types like `type Tree = Leaf(i32) | Node(Tree, Tree)` must use `CPtr` for recursive children. Tests should cover: recursive type generates pointer-based layout, non-recursive type generates inline layout.

### Testing Strategy
Round-trip test: Kira function returns an ADT value, Klar program calls it and matches on the tag. Verify both branches (e.g., Circle and Rectangle) produce correct values.

---

## Phase 3: String and Memory Convention

**Goal:** Establish clear ownership rules for values crossing the Kira-Klar boundary.
**Estimated Effort:** 2 days

### Deliverables
- Documented ownership convention in `docs/design/interop-memory.md`
- Runtime support for crossing strings safely
- Helper functions in generated Klar extern blocks

### Tasks
- [ ] Write `docs/design/interop-memory.md` — define ownership rules: (1) Kira-to-Klar strings are borrowed `CStr` valid for the call duration, (2) Klar-to-Kira strings are copied on entry, (3) ADT values returned by value are owned by the caller, (4) ADT values behind pointers require explicit free. Tests should cover: document addresses string, ADT, and list ownership in both directions.
- [ ] Implement string marshaling in the C backend — when a Kira function returns `string`, emit code that returns a `const char*` pointing to a stable buffer. When accepting a `string` parameter, copy the `const char*` into a Kira-managed string. Tests should cover: Klar passes a string to Kira and gets it back uppercased, original Klar string is unmodified.
- [ ] Generate Klar wrapper functions for string-returning Kira functions — the `.kl` extern block should include a safe wrapper that converts `CStr` to Klar `string`. Tests should cover: wrapper function compiles, returns a proper Klar string, no memory leak on repeated calls.
- [ ] Add `kira_free(ptr)` export to library builds — a function Klar can call to free Kira-allocated memory (for ADT values returned via pointer). Tests should cover: allocate in Kira, free from Klar via `kira_free`, no leak detected.

### Testing Strategy
Valgrind/LeakSanitizer test: Klar program calls Kira functions in a loop (1000 iterations), verify no memory growth. String round-trip test: pass string Klar → Kira → Klar, verify equality.

---

## Phase 4: Build System Integration

**Goal:** A Kira dependency can be declared in a Klar project manifest and built automatically.
**Estimated Effort:** 3 days

### Deliverables
- `kira.toml` `[exports]` section defining the public API
- Type manifest format (JSON) describing exported functions and types
- Integration with Klar's build process (Klar consumes the manifest)

### Tasks
- [ ] Define `[exports]` section in `kira.toml` — list modules whose public functions are exported for interop. Default: none (opt-in). Tests should cover: only listed modules appear in generated header, unlisted modules are excluded.
- [ ] Generate type manifest JSON alongside `.a` build — machine-readable description of all exported functions, their parameter types, return types, and ADT definitions. Tests should cover: JSON is valid, includes all exported symbols, parseable by a simple script.
- [ ] Add `kira build --manifest` flag — emits only the JSON manifest without compiling. Useful for tooling and AI agents. Tests should cover: manifest output matches full build output.
- [ ] Document the cross-project workflow in `docs/guide/klar-interop.md` — step-by-step guide: create Kira library, build it, add to Klar project, import and call. Include AI agent instructions. Tests should cover: a developer can follow the guide and get a working cross-language project.

### Testing Strategy
End-to-end test project: Kira library with 3 functions (pure arithmetic, string processing, ADT-returning), Klar binary that calls all three, build script that compiles both and links. Verify correct output.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| C backend doesn't preserve type info in IR | High — blocks Phase 0 | Medium | Audit IR pipeline first; add type annotations to IR if missing |
| ADT layout diverges from Klar's extern struct expectations | High — runtime crashes | Medium | Test with actual Klar compilation early; don't design in isolation |
| String ownership bugs cause use-after-free | High — memory safety | Medium | Conservative default (always copy); optimize later with borrowed views |
| `ar` not available on all platforms | Low — only affects `--lib` | Low | Fall back to emitting `.o` only; document `ar` requirement |
| Klar changes its FFI ABI | Medium — breaks interop | Low | Pin to C ABI which both languages already support; avoid Klar-internal ABI details |

## Timeline

```
Phase 0  ── (1 day)  ──→  Phase 1  ── (2 days)  ──→  Phase 2  ── (3 days)  ──→  Phase 3  ── (2 days)  ──→  Phase 4
fix types     lib build      ADT interop     memory/strings     build integration
```

- **Phase 0 → 1:** Sequential — correct types needed before library output
- **Phase 1 → 2:** Sequential — library build needed before ADT testing
- **Phase 2 and 3:** Could be parallelized — ADT layout and string conventions are independent
- **Phase 4:** Requires Phase 1-3 — build integration wraps everything together
