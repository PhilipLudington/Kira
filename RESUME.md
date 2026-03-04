# RESUME.md — Task 113 Checkpoint

## Metadata

- **Task:** 113
- **TaskText:** Add related info and notes to diagnostic messages — extend the diagnostic struct to support secondary spans and note messages. Use for things like "first defined here" on duplicate definitions, "expected because of this" on type mismatches. (per DESIGN.md section "Implementation Notes") Tests should cover: duplicate definition shows both locations, type mismatch shows expected-type origin, import error shows import site and definition site.
- **Step:** qa_review
- **Session:** 1
- **Timestamp:** 2026-03-04T17:48:22Z

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
- .forge/task-113.prompt
- RESUME.md

## Context Notes

No additional context.
