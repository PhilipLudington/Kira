# BUG.md

## [ ] Bug 1: Task 24 stuck — Add `StringInterpolation` AST node and parser support — parse interpolated strings as a list of literal fragments and expression nodes. Update `src/ast.zig` and `src/parser.zig`. (per DESIGN.md section "Literals") Tests should cover: parsing `"hello {name}"`, `"a {x} b {y} c"`, plain strings produce regular string literal, expression inside interpolation.

**Task:** 24
**Logged:** 2026-03-04T19:21:00Z

No blocker report available.

---

## [ ] Bug 2: Task 25 stuck — Type-check interpolated strings — verify each interpolated expression has a type that implements `Show` or is a primitive type convertible to string. Update `src/type_checker.zig`. (per DESIGN.md section "Literals") Tests should cover: interpolating i32, string, bool, interpolating non-showable type produces error, nested function calls in interpolation.

**Task:** 25
**Logged:** 2026-03-04T19:27:26Z

No blocker report available.

---

## [ ] Bug 3: Task 26 stuck — Resolve interpolated strings — ensure the resolver visits expressions inside interpolated strings for symbol resolution. Update `src/resolver.zig`. (per DESIGN.md section "Literals") Tests should cover: interpolated variable references resolve correctly, undefined variable in interpolation produces error.

**Task:** 26
**Logged:** 2026-03-04T19:29:57Z

No blocker report available.

---

## [ ] Bug 4: Task 27 stuck — Interpret interpolated strings — evaluate each fragment and expression, convert to string, concatenate. Update `src/interpreter.zig`. (per DESIGN.md section "Literals") Tests should cover: basic interpolation output, multiple expressions, expressions with arithmetic, string concatenation equivalence.

**Task:** 27
**Logged:** 2026-03-04T19:43:20Z

No blocker report available.

---

## [ ] Bug 5: Task 53 stuck — Parse impl blocks — add AST nodes for `impl TraitName for TypeName { ... }` with method bodies. Update `src/ast.zig` and `src/parser.zig`. (per DESIGN.md section "Standard Library") Tests should cover: impl with one method, multiple methods, impl for generic type, impl without trait (inherent methods).

**Task:** 53
**Logged:** 2026-03-04T19:47:08Z

No blocker report available.

---

## [ ] Bug 6: Task 54 stuck — Resolve traits and impl blocks — register trait names and impl blocks in the symbol table during resolution. Verify impl method names match trait requirements. Update `src/resolver.zig`. (per DESIGN.md section "Standard Library") Tests should cover: duplicate trait error, impl for undefined trait error, impl for undefined type error, method name resolution within impl.

**Task:** 54
**Logged:** 2026-03-04T19:53:45Z

No blocker report available.

---

## [ ] Bug 7: Task 55 stuck — Type-check trait declarations and impl blocks — verify impl method signatures match trait declarations exactly. Check Self type substitution. Update `src/type_checker.zig`. (per DESIGN.md section "Standard Library") Tests should cover: signature mismatch error, missing method error, extra method warning, correct Self substitution, return type mismatch.

**Task:** 55
**Logged:** 2026-03-04T20:03:03Z

No blocker report available.

---

## [ ] Bug 8: Task 56 stuck — Implement trait bounds on generics — parse and enforce `where T: Eq` or `[T: Eq]` syntax on generic functions and types. Update `src/parser.zig` and `src/type_checker.zig`. (per DESIGN.md sections "Generic Types" and "Standard Library") Tests should cover: calling generic fn with type satisfying bound, calling with type missing bound produces error, multiple bounds, bound with supertrait.

**Task:** 56
**Logged:** 2026-03-04T20:03:08Z

## Blocker Report: Task 56

**Step:** implement
**Timestamp:** 2026-03-04T20:03:04Z

### What Was Attempted

Blueprint step "implement" for task 56.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 9: Task 57 stuck — Implement method resolution and dispatch — when a method is called on a value, find the appropriate impl block and dispatch. Update `src/type_checker.zig` and `src/interpreter.zig`. (per DESIGN.md section "Standard Library") Tests should cover: calling trait method on concrete type, ambiguous impl error, method on generic with trait bound, chained method calls.

**Task:** 57
**Logged:** 2026-03-04T20:03:14Z

## Blocker Report: Task 57

**Step:** implement
**Timestamp:** 2026-03-04T20:03:12Z

### What Was Attempted

Blueprint step "implement" for task 57.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 10: Task 58 stuck — Implement core trait instances — add impl blocks for `Eq`, `Ord`, `Show` on primitive types (i32, string, bool, etc.) in the standard library. Update relevant stdlib files. (per DESIGN.md section "Standard Library") Tests should cover: `==` on i32 uses Eq, Show on i32 produces string, Ord comparison on strings.

**Task:** 58
**Logged:** 2026-03-04T20:03:16Z

## Blocker Report: Task 58

**Step:** implement
**Timestamp:** 2026-03-04T20:03:16Z

### What Was Attempted

Blueprint step "implement" for task 58.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 11: Task 84 stuck — Parse mutable field and index assignments — extend the parser to handle `expr.field = value` and `expr[index] = value` as assignment targets. Update `src/parser.zig` and `src/ast.zig`. (per DESIGN.md section "Effects System") Tests should cover: field assignment, nested field assignment, index assignment, invalid assignment target error.

**Task:** 84
**Logged:** 2026-03-04T20:03:22Z

## Blocker Report: Task 84

**Step:** implement
**Timestamp:** 2026-03-04T20:03:19Z

### What Was Attempted

Blueprint step "implement" for task 84.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 12: Task 85 stuck — Type-check mutable assignments — verify left-hand side is a valid assignable location and right-hand side type matches. Update `src/type_checker.zig`. (per DESIGN.md section "Effects System") Tests should cover: field type mismatch error, index into non-array error, assignment to immutable let error, assignment in effect function succeeds.

**Task:** 85
**Logged:** 2026-03-04T20:03:28Z

## Blocker Report: Task 85

**Step:** implement
**Timestamp:** 2026-03-04T20:03:25Z

### What Was Attempted

Blueprint step "implement" for task 85.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 13: Task 86 stuck — Enforce mutation only in effect functions — during type checking, track whether the current function is effectful. Report errors for mutation in pure functions. Update `src/type_checker.zig`. (per DESIGN.md section "Effects System") Tests should cover: mutation in pure function produces error, mutation in effect function succeeds, nested pure-within-effect correctly restricts inner function.

**Task:** 86
**Logged:** 2026-03-04T20:03:35Z

## Blocker Report: Task 86

**Step:** implement
**Timestamp:** 2026-03-04T20:03:32Z

### What Was Attempted

Blueprint step "implement" for task 86.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 14: Task 87 stuck — Interpret mutable assignments — implement field and index assignment evaluation in the interpreter. Update `src/interpreter.zig`. (per DESIGN.md section "Effects System") Tests should cover: mutating a record field and reading it back, mutating an array element, chained mutations, mutation visible after function call.

**Task:** 87
**Logged:** 2026-03-04T20:03:37Z

## Blocker Report: Task 87

**Step:** implement
**Timestamp:** 2026-03-04T20:03:37Z

### What Was Attempted

Blueprint step "implement" for task 87.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 15: Task 112 stuck — Build a source location tracking module — create `src/diagnostic.zig` that maps byte offsets to line/column, extracts source lines, and renders underline carets. (per DESIGN.md section "Implementation Notes") Tests should cover: offset-to-line mapping, multi-line extraction, caret positioning for single-token and multi-token spans, tab handling.

**Task:** 112
**Logged:** 2026-03-04T20:03:42Z

## Blocker Report: Task 112

**Step:** implement
**Timestamp:** 2026-03-04T20:03:39Z

### What Was Attempted

Blueprint step "implement" for task 112.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 16: Task 113 stuck — Add source snippets to error output — integrate the diagnostic module into the error reporting path so all errors display the offending source line with a caret. Update error emission in `src/type_checker.zig`, `src/resolver.zig`, and `src/parser.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: parser error shows source line, type error shows source line, resolver error shows source line, multi-line span renders correctly.

**Task:** 113
**Logged:** 2026-03-04T20:03:49Z

## Blocker Report: Task 113

**Step:** implement
**Timestamp:** 2026-03-04T20:03:46Z

### What Was Attempted

Blueprint step "implement" for task 113.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 17: Task 114 stuck — Implement "Did you mean?" suggestions — when a symbol is not found, compute edit distance against known symbols in scope and suggest close matches. Add a Levenshtein distance utility. Update `src/resolver.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: single-character typo suggests correct name, no suggestion when nothing is close, multiple close matches show best, case-sensitivity handling.

**Task:** 114
**Logged:** 2026-03-04T20:03:51Z

## Blocker Report: Task 114

**Step:** implement
**Timestamp:** 2026-03-04T20:03:51Z

### What Was Attempted

Blueprint step "implement" for task 114.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 18: Task 115 stuck — Add colored terminal output — implement ANSI color codes for error (red), warning (yellow), note (blue), and source context (dim). Add `--no-color` flag. Update `src/diagnostic.zig` and CLI argument parsing. (per DESIGN.md section "Implementation Notes") Tests should cover: color codes present in TTY mode, no color codes with `--no-color`, color codes absent when piped (non-TTY).

**Task:** 115
**Logged:** 2026-03-04T20:03:58Z

## Blocker Report: Task 115

**Step:** implement
**Timestamp:** 2026-03-04T20:03:56Z

### What Was Attempted

Blueprint step "implement" for task 115.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 19: Task 144 stuck — Implement LSP JSON-RPC transport layer — create `src/lsp/transport.zig` that reads/writes LSP messages over stdin/stdout with Content-Length headers. (per DESIGN.md section "Implementation Notes") Tests should cover: parse valid message, handle partial reads, write properly framed response, reject malformed headers.

**Task:** 144
**Logged:** 2026-03-04T20:04:09Z

## Blocker Report: Task 144

**Step:** implement
**Timestamp:** 2026-03-04T20:04:06Z

### What Was Attempted

Blueprint step "implement" for task 144.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 20: Task 146 stuck — Implement diagnostics (errors on save) — on `textDocument/didOpen` and `textDocument/didSave`, run the parser/resolver/type-checker and publish diagnostics. Update `src/lsp/server.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: clean file produces no diagnostics, syntax error produces diagnostic with correct range, type error produces diagnostic, multiple errors reported.

**Task:** 146
**Logged:** 2026-03-04T20:04:18Z

## Blocker Report: Task 146

**Step:** implement
**Timestamp:** 2026-03-04T20:04:16Z

### What Was Attempted

Blueprint step "implement" for task 146.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 21: Task 148 stuck — Implement go-to-definition — on `textDocument/definition`, resolve the symbol at cursor and return its definition location. Update `src/lsp/features.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: jump to local variable definition, jump to function definition, jump to imported symbol's source file, jump to type definition.

**Task:** 148
**Logged:** 2026-03-04T20:04:27Z

## Blocker Report: Task 148

**Step:** implement
**Timestamp:** 2026-03-04T20:04:25Z

### What Was Attempted

Blueprint step "implement" for task 148.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 22: Task 149 stuck — Implement find references — on `textDocument/references`, find all uses of the symbol at cursor. Update `src/lsp/features.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: find all uses of a variable, find all uses of a function, find all uses of a type, include/exclude definition based on request.

**Task:** 149
**Logged:** 2026-03-04T20:04:29Z

## Blocker Report: Task 149

**Step:** implement
**Timestamp:** 2026-03-04T20:04:29Z

### What Was Attempted

Blueprint step "implement" for task 149.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 23: Task 150 stuck — Implement completion suggestions — on `textDocument/completion`, suggest symbols in scope, struct fields after `.`, and module members after `::`. Update `src/lsp/features.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: suggest local variables, suggest module members after import, suggest struct fields after dot, filter by prefix.

**Task:** 150
**Logged:** 2026-03-04T20:04:35Z

## Blocker Report: Task 150

**Step:** implement
**Timestamp:** 2026-03-04T20:04:33Z

### What Was Attempted

Blueprint step "implement" for task 150.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 24: Task 175 stuck — Implement AST pretty-printer — create `src/formatter.zig` that takes an AST and emits canonically formatted Kira source code with consistent indentation and spacing. (per DESIGN.md section "Syntax and Grammar") Tests should cover: indentation of nested blocks, line breaking for long expressions, preservation of comments, consistent spacing around operators.

**Task:** 175
**Logged:** 2026-03-04T20:04:46Z

## Blocker Report: Task 175

**Step:** implement
**Timestamp:** 2026-03-04T20:04:43Z

### What Was Attempted

Blueprint step "implement" for task 175.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 25: Task 177 stuck — Implement REPL `:type` command — when the user enters `:type expr`, parse and type-check the expression and display the inferred type without evaluating. Update `src/repl.zig` or equivalent. (per DESIGN.md section "Type System") Tests should cover: `:type 42` shows `i32`, `:type fn(x: i32) -> i32 { return x }` shows function type, `:type undefined_var` shows error.

**Task:** 177
**Logged:** 2026-03-04T20:04:53Z

## Blocker Report: Task 177

**Step:** implement
**Timestamp:** 2026-03-04T20:04:51Z

### What Was Attempted

Blueprint step "implement" for task 177.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 26: Task 179 stuck — Add tab completion to REPL — complete keywords, in-scope symbols, and module names on Tab press. Update REPL module. (per DESIGN.md section "Implementation Notes") Tests should cover: complete keyword prefix, complete variable name, complete module name after import, no completions for unknown prefix.

**Task:** 179
**Logged:** 2026-03-04T20:05:03Z

## Blocker Report: Task 179

**Step:** implement
**Timestamp:** 2026-03-04T20:05:01Z

### What Was Attempted

Blueprint step "implement" for task 179.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 27: Task 204 stuck — Implement AST-to-IR lowering for expressions — convert arithmetic, function calls, let bindings, and literals to IR form. Create `src/lower.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: lower integer literal, lower binary operation, lower let binding, lower function call, lower nested expressions.

**Task:** 204
**Logged:** 2026-03-04T20:05:11Z

## Blocker Report: Task 204

**Step:** implement
**Timestamp:** 2026-03-04T20:05:09Z

### What Was Attempted

Blueprint step "implement" for task 204.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 28: Task 205 stuck — Implement AST-to-IR lowering for control flow — convert if/else, match statements, and for loops to IR basic blocks with branches. Update `src/lower.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: lower if/else to branch, lower match to jump table, lower for loop, nested control flow.

**Task:** 205
**Logged:** 2026-03-04T20:05:18Z

## Blocker Report: Task 205

**Step:** implement
**Timestamp:** 2026-03-04T20:05:16Z

### What Was Attempted

Blueprint step "implement" for task 205.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 29: Task 206 stuck — Implement AST-to-IR lowering for functions and closures — convert function definitions, closure captures, and effect functions to IR. Update `src/lower.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: lower pure function, lower effect function with annotation, lower closure with captured variables, lower recursive function.

**Task:** 206
**Logged:** 2026-03-04T20:05:25Z

## Blocker Report: Task 206

**Step:** implement
**Timestamp:** 2026-03-04T20:05:23Z

### What Was Attempted

Blueprint step "implement" for task 206.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 30: Task 208 stuck — Implement inlining and dead code elimination — inline small pure functions, remove unused bindings. Update `src/ir_opt.zig`. (per DESIGN.md sections "Implementation Notes" and "Effects System") Tests should cover: inline single-use small function, don't inline recursive function, don't inline effect function into pure context, eliminate unused let binding.

**Task:** 208
**Logged:** 2026-03-04T20:05:34Z

## Blocker Report: Task 208

**Step:** implement
**Timestamp:** 2026-03-04T20:05:32Z

### What Was Attempted

Blueprint step "implement" for task 208.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 31: Task 234 stuck — Implement runtime system for closures — create `src/runtime/closure.zig` with closure allocation, environment capture, and function pointer dispatch. (per DESIGN.md section "Higher-Order Functions") Tests should cover: create closure capturing one variable, call closure, nested closures, closure outlives creating scope.

**Task:** 234
**Logged:** 2026-03-04T20:05:43Z

## Blocker Report: Task 234

**Step:** implement
**Timestamp:** 2026-03-04T20:05:40Z

### What Was Attempted

Blueprint step "implement" for task 234.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 32: Task 236 stuck — Implement code generation for expressions and functions — emit native code (or C, or LLVM IR) from Kira IR for arithmetic, function calls, and let bindings. Create `src/codegen.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: compile and run arithmetic expression, compile function call, compile let binding, output matches interpreter result.

**Task:** 236
**Logged:** 2026-03-04T20:05:51Z

## Blocker Report: Task 236

**Step:** implement
**Timestamp:** 2026-03-04T20:05:48Z

### What Was Attempted

Blueprint step "implement" for task 236.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 33: Task 238 stuck — Implement code generation for effects and IO — emit code that interfaces with the runtime for IO operations and effect tracking. Update `src/codegen.zig`. (per DESIGN.md section "Effects System") Tests should cover: compile println, compile file read, compile effect function calling pure function, compile error propagation with `?`.

**Task:** 238
**Logged:** 2026-03-04T20:06:01Z

## Blocker Report: Task 238

**Step:** implement
**Timestamp:** 2026-03-04T20:05:59Z

### What Was Attempted

Blueprint step "implement" for task 238.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 34: Task 239 stuck — Add `kira build` CLI command — wire code generation into the CLI, producing a native executable from `.ki` source. Update CLI handling. (per DESIGN.md section "Implementation Notes") Tests should cover: `kira build hello.ki` produces executable, executable runs and produces correct output, build error on type error, `--output` flag for output path.

**Task:** 239
**Logged:** 2026-03-04T20:06:03Z

## Blocker Report: Task 239

**Step:** implement
**Timestamp:** 2026-03-04T20:06:03Z

### What Was Attempted

Blueprint step "implement" for task 239.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 35: Task 240 stuck — Implement tail-call optimization — detect tail-position calls in IR and emit jumps instead of calls. Update `src/ir_opt.zig` and `src/codegen.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: recursive factorial with TCO doesn't stack overflow, mutual recursion with TCO, non-tail call preserved as regular call.

**Task:** 240
**Logged:** 2026-03-04T20:06:10Z

## Blocker Report: Task 240

**Step:** implement
**Timestamp:** 2026-03-04T20:06:08Z

### What Was Attempted

Blueprint step "implement" for task 240.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 36: Task 266 stuck — Design and implement package manifest format — create `kira.toml` or `kira.json` schema for project name, version, dependencies. Create `src/package.zig` for parsing. (per DESIGN.md section "Module System") Tests should cover: parse valid manifest, reject missing required fields, parse dependencies with version constraints, parse empty dependencies.

**Task:** 266
**Logged:** 2026-03-04T20:06:18Z

## Blocker Report: Task 266

**Step:** implement
**Timestamp:** 2026-03-04T20:06:15Z

### What Was Attempted

Blueprint step "implement" for task 266.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 37: Task 267 stuck — Implement dependency resolution — resolve dependency versions from a registry or git URLs, download and cache packages. Update `src/package.zig`. (per DESIGN.md section "Module System") Tests should cover: resolve single dependency, resolve diamond dependency, version conflict produces error, cached dependency skips download.

**Task:** 267
**Logged:** 2026-03-04T20:06:20Z

## Blocker Report: Task 267

**Step:** implement
**Timestamp:** 2026-03-04T20:06:20Z

### What Was Attempted

Blueprint step "implement" for task 267.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 38: Task 268 stuck — Add `kira init` scaffolding command — generate project directory with manifest, src/main.ki, and gitignore. Update CLI handling. (per DESIGN.md section "Module System") Tests should cover: creates expected files, doesn't overwrite existing files, `--name` flag customizes project name.

**Task:** 268
**Logged:** 2026-03-04T20:06:26Z

## Blocker Report: Task 268

**Step:** implement
**Timestamp:** 2026-03-04T20:06:24Z

### What Was Attempted

Blueprint step "implement" for task 268.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 39: Task 270 stuck — Implement property-based testing support — add a `kira test` mode that generates random inputs for functions annotated with test properties. Update test runner. (per DESIGN.md section "Implementation Notes") Tests should cover: generate random i32 inputs, shrink failing case, property holds for simple function, property violation detected.

**Task:** 270
**Logged:** 2026-03-04T20:06:34Z

## Blocker Report: Task 270

**Step:** implement
**Timestamp:** 2026-03-04T20:06:33Z

### What Was Attempted

Blueprint step "implement" for task 270.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

## [ ] Bug 40: Task 271 stuck — Implement Klar interop — allow Kira pure functions to be called from Klar via a shared calling convention or FFI bridge. Create `src/interop/klar.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: call Kira function from Klar, pass ADT across boundary, type mismatch produces error at compile time.

**Task:** 271
**Logged:** 2026-03-04T20:06:41Z

## Blocker Report: Task 271

**Step:** implement
**Timestamp:** 2026-03-04T20:06:39Z

### What Was Attempted

Blueprint step "implement" for task 271.

### What Failed

```
No source files were created or modified by the implementation step.
```

### Root Cause Hypothesis

Step "implement" failed after exhausting retries.

### What Is Needed to Unblock

Manual investigation of the failure in step "implement".

---

