# Kira Phase 5 — Implementation Plan

## Overview
Productization and performance improvements for Kira. Closes the remaining roadmap gaps after Phase 4: searchable API docs, benchmark harness, test coverage reporting, and pure-function memoization. Scoped to this repository only.

Current status: Phase 0 nearly complete — examples remaining.

## Phase 0: Searchable API Docs

**Goal:** Extend `kira doc` to generate GitHub-friendly multi-module API docs with search.
**Estimated Effort:** 3-5 days

### Deliverables
- Intermediate documentation model (decoupled from AST traversal)
- Per-module Markdown pages with top-level index
- Search index JSON (module path, symbol name/kind, signature, doc summary)
- Project-level doc generation from `kira.toml`

### Tasks
- [x] Introduce intermediate documentation model (SymbolDoc, ModuleDoc, ProjectDocs, SymbolKind)
- [x] Refactor `doc_gen.zig` to populate model from AST instead of emitting Markdown directly
- [x] Add project-level module discovery from `kira.toml`
- [x] Generate top-level Markdown index page
- [x] Generate per-module Markdown pages
- [x] Generate search index JSON
- [x] Index public symbols by module path, name, kind, signature, and doc summary
- [x] Filter out private declarations from generated output
- [x] Add CLI help text and docs for new `kira doc` flags
- [ ] Add examples under `examples/`

### Testing Strategy
- Docs generation for a multi-module package produces correct output.
- Search finds functions, traits, and types by exact and partial name.
- Symbols from private declarations do not appear.
- Existing Markdown-only workflows continue to work.

---

## Phase 1: Benchmark Harness

**Goal:** Add `kira bench` CLI command with package-oriented benchmark discovery and execution.
**Estimated Effort:** 3-5 days

### Deliverables
- `kira bench` CLI command
- Benchmark discovery (files under `bench/` and annotated declarations)
- Standard output: iterations, total time, mean time, optional min/max
- Machine-readable JSON output option

### Tasks
- [ ] Add `kira bench` command to CLI
- [ ] Implement benchmark file discovery under `bench/`
- [ ] Support annotated benchmark declarations within package modules
- [ ] Implement warmup and repeated sampling
- [ ] Emit standard benchmark output (iterations, total/mean time, min/max)
- [ ] Add JSON output mode for CI ingestion
- [ ] Prevent benchmark bodies from being optimized away
- [ ] Add CLI help text for `kira bench`
- [ ] Add benchmark examples under `examples/`

### Testing Strategy
- Benchmark discovery across a simple package works correctly.
- Stable CLI output for one and multiple benchmarks.
- JSON output format parses correctly for CI ingestion.
- Failure path when a benchmark raises a runtime error.

---

## Phase 2: Coverage Reporting

**Goal:** Add interpreter-level coverage instrumentation and reporting to `kira test`.
**Estimated Effort:** 4-6 days

### Deliverables
- `kira test --coverage` flag
- Interpreter-level statement/line coverage instrumentation
- Terminal summary, machine-readable report, optional annotated source output

### Tasks
- [ ] Instrument executable statements and branch arms during evaluation
- [ ] Record coverage spans keyed by module path and source ranges
- [ ] Add `--coverage` flag to `kira test`
- [ ] Emit terminal coverage summary
- [ ] Emit machine-readable coverage report
- [ ] Add optional annotated source output
- [ ] Define how property tests count toward coverage
- [ ] Add CLI help text for `--coverage`

### Testing Strategy
- Covered and uncovered lines reported correctly for simple functions.
- Branch coverage behaves sensibly for `match` and `if`.
- Multi-file project coverage aggregates correctly.
- Coverage collection does not change program behavior.

---

## Phase 3: Memoization of Pure Functions

**Goal:** Add opt-in memoization for eligible pure functions with explicit cache policy.
**Estimated Effort:** 5-7 days

### Deliverables
- Annotation-based opt-in memoization
- Eligibility rules: pure, deterministic args, supported cache-key types
- Explicit memory policy (unbounded, LRU, or per-function limit)

### Tasks
- [ ] Define eligibility rules (pure, deterministic args, supported value types)
- [ ] Implement annotation-based opt-in mechanism
- [ ] Add interpreter-level memoization cache
- [ ] Restrict cacheable arguments to primitives, tuples, enums, and immutable records
- [ ] Implement initial memory policy (unbounded or LRU)
- [ ] Document interactions with recursion and generic functions
- [ ] Validate performance improvements using benchmark harness (Phase 1)
- [ ] Add diagnostics for non-eligible functions
- [ ] Gate behind `experimental` naming if necessary

### Testing Strategy
- Repeated calls with identical inputs hit cache.
- Different generic instantiations do not alias cache entries.
- Recursive pure functions remain correct.
- Non-eligible functions are rejected with clear diagnostics.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Coverage + memoization both depend on execution semantics; parallel implementation fragments design | High | Medium | Deliver sequentially; coverage before memoization |
| Searchable docs scope creep into site generator | Medium | Medium | Keep output contract narrow: Markdown + JSON only |
| Noisy benchmark results | Medium | High | Define warmup, repetition, and reporting rules precisely |
| Memoization introduces hidden memory growth | High | Medium | Require explicit cache policy from day one |

## Timeline
Phases are sequential. Phase 0 (docs) is lowest-risk and already has implementation base in `src/doc_gen.zig`. Phase 1 (benchmarks) provides measurement tooling needed by later phases. Phase 2 (coverage) depends on interpreter instrumentation decisions. Phase 3 (memoization) has highest risk and lands last after measurement tooling exists.
