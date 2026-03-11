# Kira — Audit Remediation Plan

## Overview
Comprehensive plan to fix philosophy violations, align the spec with the implementation,
complete partially-implemented features, and prepare for production codegen.
Current status: Phase 0, Phase 1, and Phase 2 complete. Phase 3 (Production Codegen) next.

Audit performed against IDEA.md, PHILOSOPHY.md, and DESIGN.md.

---

## Phase 0: Fix Philosophy Violations ✅
**Status:** Complete (2026-03-10)

**Goal:** Eliminate every place the compiler contradicts its own design principles.
**Estimated Effort:** 3-5 days

### Deliverables
- Type checker rejects cross-width integer assignment without `.as[T]`
- Type checker rejects implicit `[T; N]` to `[T]` array coercion
- Interpreter confirmed strictly eager (no lazy evaluation)
- DESIGN.md string interpolation syntax updated to `${}`

### Tasks
- [x] Fix integer width implicit conversion: require `.as[T]` for all cross-width integer assignments (e.g., `i32` to `i64`). Update `unify.zig` `isAssignable()` to reject mismatched integer widths/signedness. (completed 2026-03-10)
- [x] Fix array coercion: remove implicit `[T; N]` to `[T]` assignment in `unify.zig`. Add explicit `.as[[T]]` cast support in `isValidCast()`. (completed 2026-03-10)
- [x] Audit interpreter for lazy evaluation: confirmed all evaluation is strict. No thunks, deferred computation, or lazy patterns found. (completed 2026-03-10)
- [x] Update DESIGN.md: changed all 13 string interpolation examples from `{name}` to `${name}` to match the implementation. (completed 2026-03-10)

### Testing Strategy
- Existing tests that rely on implicit integer widening must be updated to use `.as[T]`.
- Existing tests that rely on array coercion must be updated.
- Write new negative tests: `let x: i64 = 42i32` must fail. `let a: [i32] = [1, 2, 3]` (fixed-size to dynamic) must fail without explicit conversion.
- Run full test suite to confirm no regressions.

---

## Phase 1: Spec Alignment ✅
**Status:** Complete (2026-03-10)

**Goal:** Update DESIGN.md to document every implemented feature not currently in the spec.
**Estimated Effort:** 1-2 days

### Deliverables
- DESIGN.md covers all implemented language features
- No undocumented syntax in the compiler

### Tasks
- [x] Document `shadow` keyword: add to keywords list, add grammar section showing `shadow let` and `shadow var` with explanation of explicit shadowing opt-in. (completed 2026-03-10)
- [x] Document `const` declarations: add to keywords list, add grammar section distinguishing `const` (compile-time known) from `let` (runtime immutable). (completed 2026-03-10)
- [x] Document `test` and `bench` declarations: add syntax, semantics, and examples for `test "name" { ... }` and `bench "name" { ... }`. (completed 2026-03-10)
- [x] Document `??` operator: add to operators list (already present), add semantics section showing `val ?? default` for Option types. (completed 2026-03-10)
- [x] Document `while` and `loop`: add to control flow section with grammar and examples. Clarify when to use `for` vs `while` vs `loop`. (completed 2026-03-10)
- [x] Document `memo fn`: add to function declarations section. Explain memoization, the purity requirement, and that `memo` + `effect` is a compile error. (completed 2026-03-10)
- [x] Document `var` bindings explicitly: clarify that `var` is for local mutable bindings within function bodies, and that top-level bindings are always immutable. (completed 2026-03-10)
- [x] Document range patterns (`1..10`, `'a'..='z'`) and rest patterns (`..`) in pattern matching section. (completed 2026-03-10)
- [x] Review all keyword/operator lists in DESIGN.md for completeness against the lexer's actual keyword and operator tables. Added missing `|` operator. All 34 keywords verified present. (completed 2026-03-10)

### Testing Strategy
- No code changes in this phase — spec-only updates.
- Cross-check every keyword in `token.zig` against DESIGN.md keyword list.
- Cross-check every operator in the lexer against DESIGN.md operator list.

---

## Phase 1 Readiness Gate
Before Phase 2, these must be true:
- [x] All Phase 0 fixes merged and passing tests (completed 2026-03-10)
- [x] DESIGN.md fully describes every language feature the compiler implements (completed 2026-03-10)
- [x] No undocumented syntax exists in the parser (completed 2026-03-10)

---

## Phase 2: Complete Traits ✅
**Status:** Complete (2026-03-10)

**Goal:** Make the trait system production-ready per the DESIGN.md spec.
**Estimated Effort:** 1-2 weeks

### Deliverables
- Trait default method implementations work
- Where clause constraints are validated by the type checker
- Impl block method signatures are checked against trait definitions
- `Eq`, `Ord`, `Show` traits from the spec standard library are usable

### Tasks
- [x] Implement default method bodies in traits: when a trait declares a method with a body, impl blocks can omit it and inherit the default. (completed 2026-03-10)
- [x] Validate where clause constraints: type checker must resolve and enforce `where T: Eq, U: Show` constraints on generic functions and impl blocks. (completed 2026-03-10)
- [x] Check method signature compatibility in impl blocks: verify that each method in an `impl Trait for Type` block matches the trait's declared signature (parameter types, return type, effect annotation). (completed 2026-03-10)
- [x] Implement trait method dispatch: when calling a method on a generic `T: Eq`, resolve to the concrete impl's method. (completed 2026-03-10)
- [x] Add comprehensive trait tests: default methods, missing methods (error), wrong signatures (error), multiple trait bounds, where clauses. (completed 2026-03-10)
- [x] Wire up `Eq`, `Ord`, `Show` in the standard library so they can be implemented by user types. (completed 2026-03-10)

### Testing Strategy
- Write `.ki` test programs exercising each trait feature.
- Negative tests: impl missing a required method, impl with wrong method signature, calling trait method on type that doesn't implement it.
- Test trait bounds on generic functions: `fn sort[T: Ord](list: List[T]) -> List[T]`.

---

## Phase 2 Readiness Gate
Before Phase 3, these must be true:
- [x] Traits with default methods, where clauses, and signature checking all pass tests (completed 2026-03-10)
- [x] At least `Eq` and `Show` are usable from user code (completed 2026-03-10)
- [x] No trait-related TODOs remain in the type checker (completed 2026-03-10)

---

## Phase 3: Production Codegen

**Goal:** Make the C code generation backend functional for real programs.
**Estimated Effort:** 2-4 weeks

### Deliverables
- C codegen handles all value types (tuples, arrays, records, closures, variants)
- Compiled Kira programs produce correct output
- Klar interop verified end-to-end

### Tasks
- [ ] Implement C representations for tuples: struct with indexed fields.
- [ ] Implement C representations for records: struct with named fields.
- [ ] Implement C representations for arrays: pointer + length, with fixed-size optimization.
- [ ] Implement C representations for ADT variants: tagged union with payload.
- [ ] Implement C representations for closures: function pointer + captured environment struct.
- [ ] Implement proper type-specific code generation (replace uniform `kira_int` with actual types).
- [ ] Implement string representation and string interpolation in C output.
- [ ] Implement pattern matching compilation to C (decision trees or backtracking).
- [ ] Implement effect tracking in compiled code (ensure pure/effect boundary survives compilation).
- [ ] Test compiled output against interpreter output for all example programs.
- [ ] Verify Klar interop: call Klar functions from Kira compiled code and vice versa.

### Testing Strategy
- For each example in `examples/`, compile via C codegen and compare output to interpreter.
- Compile and run the word_count example from DESIGN.md.
- Cross-language test: Kira calls a Klar function, Klar calls a Kira pure function.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Integer width fix breaks many existing programs/tests | High | High | Audit all tests first, batch-fix with `.as[T]` |
| Array coercion removal has unclear replacement syntax | Medium | Medium | Design explicit conversion before removing implicit |
| Trait completion reveals type system gaps | High | Medium | Limit scope to basic traits first, defer associated types |
| C codegen for closures is architecturally complex | High | Medium | Study existing closure compilation strategies (e.g., GCC nested functions, lambda lifting) |
| Klar interop may have bitrotted | Medium | Medium | Test early in Phase 3, don't leave for last |

## Timeline
- Phase 0 depends on nothing — start immediately
- Phase 1 can run in parallel with Phase 0 (spec changes are independent of code changes)
- Phase 2 depends on Phase 0 + Phase 1 (trait work needs stable type system and complete spec)
- Phase 3 depends on Phase 2 (codegen needs trait dispatch to be settled)
