# RESUME.md — Task 143 Checkpoint

## Metadata

- **Task:** 143
- **TaskText:** Implement diagnostics on `textDocument/didSave` in `src/lsp/server.zig` — run the parser, resolver, and type checker on the saved file, convert compiler errors to LSP Diagnostic objects, publish via `textDocument/publishDiagnostics`. (per DESIGN.md section "Implementation Notes") Tests should cover: clean file produces no diagnostics, parse error produces diagnostic at correct position, type error produces diagnostic, multiple errors in one file.
- **Step:** qa_review
- **Session:** 1
- **Timestamp:** 2026-03-04T17:49:03Z

## Completed Steps

- install_deps
- implement
- shift_left
- test
- qa_review

## Remaining Steps

- qa_fix
- post_qa_test
- commit
- push

## Files Modified

- carbide/examples/c-binding/build.zig
- carbide/templates/build.zig.zon
- carbide/templates/project/build.zig.zon
- src/lexer/lexer.zig
- src/main.zig
- src/stdlib/bytes.zig
- .forge/task-143.prompt
- RESUME.md

## Context Notes

No additional context.
