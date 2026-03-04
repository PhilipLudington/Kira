# RESUME.md — Task 145 Checkpoint

## Metadata

- **Task:** 145
- **TaskText:** Implement go-to-definition (`textDocument/definition`) in `src/lsp/server.zig` — given a position on an identifier, find where that symbol was defined using resolver data, return the definition location. Support cross-file jumps for imports. (per DESIGN.md section "Module System") Tests should cover: jump to local binding, jump to function parameter, jump to imported symbol, jump to type definition.
- **Step:** qa_review
- **Session:** 1
- **Timestamp:** 2026-03-04T17:49:27Z

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
- .forge/task-145.prompt
- RESUME.md

## Context Notes

No additional context.
