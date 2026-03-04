# RESUME.md — Task 235 Checkpoint

## Metadata

- **Task:** 235
- **TaskText:** Implement C FFI in `src/ffi.zig` — allow Kira functions to declare external C functions and call them. Marshal Kira types to/from C types (integers, strings as char*, records as structs). Effect functions can call C; pure functions cannot call C (C is inherently effectful). (per DESIGN.md section "Effects System") Tests should cover: call C strlen from Kira, pass string to C function, receive integer from C function, pure function calling C produces error, struct marshaling works.
- **Step:** qa_review
- **Session:** 1
- **Timestamp:** 2026-03-04T17:52:42Z

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
- .forge/task-235.prompt
- RESUME.md

## Context Notes

No additional context.
