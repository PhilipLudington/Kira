# Kira — Implementation Plan

## Overview
Address remaining gaps in the Kira compiler: string interpolation (the one unimplemented language feature from DESIGN.md), LSP enhancements for a better editor experience, and interop hardening with E2E tests.

Reference: [DESIGN.md](DESIGN.md), [IDEA.md](IDEA.md).
Current status: Phases 0–2 complete. Phase 3 not started.

---

## Phase 0: String Interpolation ✅
**Status:** Complete (2026-03-14)

**Goal:** Implement `${expr}` syntax in string literals so `"hello ${name}"` works end-to-end through compilation and interpretation.
**Estimated Effort:** 2 days

### Deliverables
- Lexer recognizes `${` inside string literals and emits segmented tokens
- Parser builds `InterpolatedString` AST nodes (node type already exists in `src/ast/expression.zig:313-322`)
- IR lowering converts interpolated strings to `str_concat` instructions (already supported by codegen)
- Interpreter evaluates interpolated string expressions inline
- E2E tests covering interpolation in both compiled and interpreted paths

### Tasks
- [x] Update lexer to segment interpolated strings (was already implemented — lexer emits full string, parser splits) (completed 2026-03-14)
- [x] Update parser to build `InterpolatedString` nodes (was already implemented) (completed 2026-03-14)
- [x] Add resolver support for interpolated strings (was already implemented) (completed 2026-03-14)
- [x] Add typechecker support (was already implemented) (completed 2026-03-14)
- [x] Lower `InterpolatedString` to IR (was already implemented) (completed 2026-03-14)
- [x] Add interpreter support (was already implemented) (completed 2026-03-14)
- [x] Fix codegen `to_string` for string and bool types — string values were being formatted as integers, bools as numeric 0/1 (completed 2026-03-14)
- [x] Add E2E tests — 7 tests covering simple variable interpolation, expression interpolation, escaped `\${`, adjacent parts, bool interpolation, and mixed types (completed 2026-03-14)

### Testing Strategy
E2E tests comparing compiled C output and interpreter output for interpolated strings. Unit tests in the lexer for token segmentation edge cases (empty interpolation, adjacent interpolations, escaped dollars).

### Phase 0 Readiness Gate
Before Phase 1, these must be true:
- [x] `"hello ${name}"` compiles and runs correctly (completed 2026-03-14)
- [x] `"${a} + ${b} = ${a + b}"` produces correct output (completed 2026-03-14)
- [x] `"\${literal}"` produces the text `${literal}` (completed 2026-03-14)
- [x] Interpreter and compiled paths produce identical output (completed 2026-03-14)

---

## Phase 1: LSP Core Improvements ✅
**Status:** Complete (2026-03-14)

**Goal:** Add diagnostic publishing, document symbols, and context-aware completion to the LSP server — the three highest-impact features for editor usability.
**Estimated Effort:** 3 days

### Deliverables
- Real-time error/warning underlining as the user types
- Document symbol outline (functions, types, traits visible in sidebar/breadcrumbs)
- Completion filtered by scope and context instead of flat symbol dump

### Tasks
- [x] Improve diagnostic publishing on document change — `didChange` already triggered diagnostics; improved by: mapping full span ranges (start+end) instead of single-character, publishing warnings/hints (not just errors) with correct LSP severity, always running typechecker when resolver succeeds. (`src/lsp/server.zig`, `src/root.zig`) (completed 2026-03-14)
- [x] Implement `textDocument/documentSymbol` handler — walks parsed AST declarations, emits DocumentSymbol objects for functions (Function), types (Struct with variant/field children), traits (Interface with method children), impl blocks (with method children), constants (Constant), let bindings (Variable), test/bench (Event). Imports excluded. (`src/lsp/features.zig`, `src/lsp/server.zig`) (completed 2026-03-14)
- [x] Add `DocumentSymbol` type to LSP types — SymbolKind enum, DocumentSymbol struct with name, kind, range, selectionRange, children. Registered `documentSymbolProvider` capability. (`src/lsp/types.zig`) (completed 2026-03-14)
- [x] Improve completion with scope awareness — filters out symbols defined after cursor position (top-level declarations always visible), deduplicates by name (later/closer definitions shadow earlier ones), adds type detail strings for variables (type name), functions (parameter signature + return type), and other symbol kinds. (`src/lsp/features.zig`, `src/lsp/server.zig`) (completed 2026-03-14)
- [x] Add `textDocument/didChange` to diagnostic trigger — was already wired: `handleDidChange` calls `updateDocument` which calls `publishDiagnostics`. Full document sync (textDocumentSync: 1) already in place. (`src/lsp/server.zig`) (completed 2026-03-14)

### Testing Strategy
Manual testing with the VS Code extension (or any LSP client). Verify: errors underline correctly and update on edit, document outline shows all top-level declarations, completion narrows to relevant symbols.

---

## Phase 2: LSP Advanced Features ✅
**Status:** Complete (2026-03-14)

**Goal:** Add rename, workspace symbols, and signature help for a more complete IDE experience.
**Estimated Effort:** 3 days

### Deliverables
- Rename symbol across all references in a file
- Workspace-wide symbol search
- Function signature help on `(`

### Tasks
- [x] Implement `textDocument/rename` handler — finds symbol at cursor (reuses `findSymbolAtPosition`), collects all references (reuses `findReferences`), returns `WorkspaceEdit` with text edits for each location. Validates new name is a valid identifier. (`src/lsp/server.zig`) (completed 2026-03-14)
- [x] Implement `workspace/symbol` handler — iterates all open documents' symbol tables, returns matching top-level symbols filtered by query substring. (`src/lsp/server.zig`) (completed 2026-03-14)
- [x] Implement `textDocument/signatureHelp` handler — walks source backward from cursor to find unmatched `(`, extracts function name, counts commas for active parameter index, looks up function signature from symbol table. (`src/lsp/features.zig`, `src/lsp/server.zig`) (completed 2026-03-14)
- [x] Add `WorkspaceEdit`, `TextEdit`, `SignatureHelp`, `SignatureInformation`, `ParameterInformation`, and `SymbolInformation` types to LSP types. (`src/lsp/types.zig`) (completed 2026-03-14)
- [x] Register new capabilities in `initialize` response — `renameProvider`, `workspaceSymbolProvider`, `signatureHelpProvider` with trigger characters `(` and `,`. (`src/lsp/server.zig:handleInitialize`) (completed 2026-03-14)

### Testing Strategy
Automated unit tests in `src/lsp/server.zig` (integration tests via TestStream) and `src/lsp/features.zig` (findSignatureContext unit tests). Tests verify: rename produces WorkspaceEdit with correct newText, invalid rename names are rejected, workspace symbol returns matching results, signature help returns signatures with parameters. Total: 10 new tests added.

---

## Phase 3: Interop Hardening

**Goal:** Add E2E tests for the interop pipeline and handle remaining edge cases (indirect recursive ADTs, large type optimization).
**Estimated Effort:** 2 days

### Deliverables
- E2E tests that build a Kira library and verify .h/.kl/.json output
- Indirect recursive ADT cycle detection
- Size threshold for pass-by-pointer ADTs

### Tasks
- [ ] Add interop E2E tests — write a Kira module with mixed types (i32, f64, string, bool, ADT), run through `generateHeader()`, `generateKlarExternBlock()`, and `generateManifestJSON()`, verify output contains correct C types, Klar types, and JSON structure. (`tests/codegen_e2e_test.zig`)
- [ ] Add compiled interop E2E test — build a Kira module with `--lib`, compile the generated .c with a C test harness that calls the exported wrapper functions, verify correct return values. (`tests/codegen_e2e_test.zig`)
- [ ] Implement indirect recursive ADT detection — currently only direct self-references (type T contains T) are handled. Add cycle detection for A → B → A chains. When detected, use pointer indirection for the recursive field. (`src/interop/klar.zig`)
- [ ] Implement size-based pointer optimization — types exceeding 64 bytes should be passed by opaque pointer (`void*`) instead of inline struct in the C header. Add `kiraTypeByteSize` calculation for composite types. (`src/interop/klar.zig`)

### Testing Strategy
Automated tests in `tests/codegen_e2e_test.zig`. Verify: generated header compiles with `cc -fsyntax-only`, Klar extern block has correct types, JSON manifest is valid and parseable, recursive ADTs use pointer indirection, large types use opaque pointers.

### Phase 3 Readiness Gate
Before considering interop complete:
- [ ] All interop E2E tests pass
- [ ] Indirect recursive ADTs produce valid C headers
- [ ] A Kira library with mixed types can be compiled and linked from C

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Lexer changes for interpolation break existing string parsing | High — regressions | Medium | Extensive unit tests for string edge cases; keep non-interpolated strings on the fast path |
| LSP diagnostic publishing on every keystroke is too slow | Medium — poor UX | Medium | Debounce with 300ms delay; only re-parse changed document |
| Rename across files requires cross-file symbol resolution | Medium — incomplete feature | Low | Start with single-file rename; cross-file is Phase 2+ |
| Interpolated strings in the C backend need runtime `sprintf` or equivalent | Low — implementation complexity | Low | Use existing `str_concat` with `to_string` conversions; no new runtime needed |

## Timeline

```
Phase 0  ── (2 days) ──→  Phase 1  ── (3 days) ──→  Phase 2  ── (3 days) ──→  Phase 3
string interp            LSP core                  LSP advanced              interop hardening
```

- **Phase 0 → 1:** Independent — can be parallelized, but string interpolation informs LSP completion/hover
- **Phase 1 → 2:** Sequential — Phase 2 builds on infrastructure from Phase 1
- **Phase 3:** Independent — can run in parallel with Phase 1 or 2
