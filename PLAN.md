# Kira — Implementation Plan

## Overview

Kira is a functional programming language with explicit types, algebraic data types, and a compiler-enforced effects system. The compiler is written in Zig (0.15+) with a pipeline of Parser → Resolver → TypeChecker → Interpreter. Phase 0 (foundation) is complete at v0.11.1 with 285 passing tests. This plan covers Phases 1–4 from ROADMAP.md, taking Kira from a working interpreter to a complete, compiled language with tooling and ecosystem.

Current status: Phase 1 complete. Phase 2 next.

---

## Phase 1: String Interpolation ✅

**Status:** Complete (2026-03-04)
**Goal:** Add string interpolation syntax (`"hello {name}"`) across all compiler phases.
**Estimated Effort:** 2 days

### Deliverables
- Lexer/parser support for `"hello {expr}"` syntax
- AST node for interpolated strings
- Type checking of interpolated expressions
- Interpreter evaluation of interpolated strings

### Tasks
- [x] Add string interpolation lexing — extend the lexer to recognize `{` inside string literals and emit tokens for string fragments and interpolation boundaries. Update `src/lexer.zig`. (per DESIGN.md section "Literals") Tests should cover: plain strings unchanged, single interpolation, multiple interpolations, nested braces, escaped braces, empty interpolation error. (completed 2026-03-04)
- [x] Add `StringInterpolation` AST node and parser support — parse interpolated strings as a list of literal fragments and expression nodes. Update `src/ast.zig` and `src/parser.zig`. (per DESIGN.md section "Literals") Tests should cover: parsing `"hello {name}"`, `"a {x} b {y} c"`, plain strings produce regular string literal, expression inside interpolation. (completed 2026-03-04)
- [x] Type-check interpolated strings — verify each interpolated expression has a type that implements `Show` or is a primitive type convertible to string. Update `src/type_checker.zig`. (per DESIGN.md section "Literals") Tests should cover: interpolating i32, string, bool, interpolating non-showable type produces error, nested function calls in interpolation. (completed 2026-03-04)
- [x] Resolve interpolated strings — ensure the resolver visits expressions inside interpolated strings for symbol resolution. Update `src/resolver.zig`. (per DESIGN.md section "Literals") Tests should cover: interpolated variable references resolve correctly, undefined variable in interpolation produces error. (completed 2026-03-04)
- [x] Interpret interpolated strings — evaluate each fragment and expression, convert to string, concatenate. Update `src/interpreter.zig`. (per DESIGN.md section "Literals") Tests should cover: basic interpolation output, multiple expressions, expressions with arithmetic, string concatenation equivalence. (completed 2026-03-04)

### Testing Strategy
Run `./run-tests.sh`. Write `.ki` test files that use string interpolation in let bindings, function arguments, and match arms. Verify output matches expected concatenated strings.

### Phase 1 Readiness Gate
Before Phase 2, these must be true:
- [x] `"hello {name}"` parses, type-checks, and evaluates correctly
- [x] All existing 285+ tests still pass (292 passing)
- [x] Interpolation works inside all expression contexts (let, fn args, match arms)

---

## Phase 2: Trait System ✅

**Status:** Complete (2026-03-04)
**Goal:** Implement trait declarations, impl blocks, method resolution, and trait bounds on generics.
**Estimated Effort:** 4 days

### Deliverables
- Trait declaration parsing and type checking
- Impl block parsing, validation, and method resolution
- Trait bounds on generic type parameters
- Method call dispatch through impl blocks

### Tasks
- [x] Parse trait declarations — add AST nodes for `trait Name { fn method(self: Self) -> T }` and parse method signatures. Update `src/ast.zig` and `src/parser.zig`. (per DESIGN.md section "Standard Library") Tests should cover: empty trait, single method trait, multiple methods, trait with supertraits (`trait Ord: Eq`), trait with generic methods. (completed 2026-03-04)
- [x] Parse impl blocks — add AST nodes for `impl TraitName for TypeName { ... }` with method bodies. Update `src/ast.zig` and `src/parser.zig`. (per DESIGN.md section "Standard Library") Tests should cover: impl with one method, multiple methods, impl for generic type, impl without trait (inherent methods). (completed 2026-03-04)
- [x] Resolve traits and impl blocks — register trait names and impl blocks in the symbol table during resolution. Verify impl method names match trait requirements. Update `src/resolver.zig`. (per DESIGN.md section "Standard Library") Tests should cover: duplicate trait error, impl for undefined trait error, impl for undefined type error, method name resolution within impl. (completed 2026-03-04)
- [x] Type-check trait declarations and impl blocks — verify impl method signatures match trait declarations exactly. Check Self type substitution. Update `src/type_checker.zig`. (per DESIGN.md section "Standard Library") Tests should cover: signature mismatch error, missing method error, extra method warning, correct Self substitution, return type mismatch. (completed 2026-03-04)
- [x] Implement trait bounds on generics — parse and enforce `where T: Eq` or `[T: Eq]` syntax on generic functions and types. Update `src/parser.zig` and `src/type_checker.zig`. (per DESIGN.md sections "Generic Types" and "Standard Library") Tests should cover: calling generic fn with type satisfying bound, calling with type missing bound produces error, multiple bounds, bound with supertrait. (completed 2026-03-04)
- [x] Implement method resolution and dispatch — when a method is called on a value, find the appropriate impl block and dispatch. Update `src/type_checker.zig` and `src/interpreter.zig`. (per DESIGN.md section "Standard Library") Tests should cover: calling trait method on concrete type, ambiguous impl error, method on generic with trait bound, chained method calls. (completed 2026-03-04)
- [x] Implement core trait instances — add impl blocks for `Eq`, `Ord`, `Show` on primitive types (i32, string, bool, etc.) in the standard library. Update relevant stdlib files. (per DESIGN.md section "Standard Library") Tests should cover: `==` on i32 uses Eq, Show on i32 produces string, Ord comparison on strings. (completed 2026-03-04)

### Testing Strategy
Run `./run-tests.sh`. Write `.ki` files exercising trait definitions, impl blocks, trait bounds, and method dispatch. Verify error messages for missing impls and signature mismatches.

### Phase 2 Readiness Gate
Before Phase 3, these must be true:
- [x] Trait declarations parse and type-check
- [x] Impl blocks validate against trait requirements
- [x] Method calls dispatch through impl blocks
- [x] Trait bounds restrict generic instantiation
- [x] All prior tests still pass (314 passing)

---

## Phase 3: Mutation and Effects Enforcement

**Goal:** Support mutable field/index access in effect functions and enforce that mutation only occurs in effectful contexts.
**Estimated Effort:** 2 days

### Deliverables
- Mutable field assignment (`record.field = value`)
- Mutable index assignment (`array[i] = value`)
- Compiler enforcement that mutation is restricted to effect functions

### Tasks
- [ ] Parse mutable field and index assignments — extend the parser to handle `expr.field = value` and `expr[index] = value` as assignment targets. Update `src/parser.zig` and `src/ast.zig`. (per DESIGN.md section "Effects System") Tests should cover: field assignment, nested field assignment, index assignment, invalid assignment target error.
- [ ] Type-check mutable assignments — verify left-hand side is a valid assignable location and right-hand side type matches. Update `src/type_checker.zig`. (per DESIGN.md section "Effects System") Tests should cover: field type mismatch error, index into non-array error, assignment to immutable let error, assignment in effect function succeeds.
- [ ] Enforce mutation only in effect functions — during type checking, track whether the current function is effectful. Report errors for mutation in pure functions. Update `src/type_checker.zig`. (per DESIGN.md section "Effects System") Tests should cover: mutation in pure function produces error, mutation in effect function succeeds, nested pure-within-effect correctly restricts inner function.
- [ ] Interpret mutable assignments — implement field and index assignment evaluation in the interpreter. Update `src/interpreter.zig`. (per DESIGN.md section "Effects System") Tests should cover: mutating a record field and reading it back, mutating an array element, chained mutations, mutation visible after function call.

### Testing Strategy
Run `./run-tests.sh`. Write `.ki` files that mutate record fields and array indices inside effect functions. Verify pure functions correctly reject mutation attempts.

### Phase 3 Readiness Gate
Before Phase 4, these must be true:
- [ ] Field and index assignment works in effect functions
- [ ] Mutation in pure functions produces compile error
- [ ] All prior tests still pass

---

## Phase 4: Error Reporting

**Goal:** Improve compiler error messages with source snippets, suggestions, and colored output.
**Estimated Effort:** 3 days

### Deliverables
- Source code snippets shown alongside error messages
- "Did you mean?" suggestions for name typos
- Colored terminal output for diagnostics
- Related info and notes attached to errors

### Tasks
- [ ] Build a source location tracking module — create `src/diagnostic.zig` that maps byte offsets to line/column, extracts source lines, and renders underline carets. (per DESIGN.md section "Implementation Notes") Tests should cover: offset-to-line mapping, multi-line extraction, caret positioning for single-token and multi-token spans, tab handling.
- [ ] Add source snippets to error output — integrate the diagnostic module into the error reporting path so all errors display the offending source line with a caret. Update error emission in `src/type_checker.zig`, `src/resolver.zig`, and `src/parser.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: parser error shows source line, type error shows source line, resolver error shows source line, multi-line span renders correctly.
- [ ] Implement "Did you mean?" suggestions — when a symbol is not found, compute edit distance against known symbols in scope and suggest close matches. Add a Levenshtein distance utility. Update `src/resolver.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: single-character typo suggests correct name, no suggestion when nothing is close, multiple close matches show best, case-sensitivity handling.
- [ ] Add colored terminal output — implement ANSI color codes for error (red), warning (yellow), note (blue), and source context (dim). Add `--no-color` flag. Update `src/diagnostic.zig` and CLI argument parsing. (per DESIGN.md section "Implementation Notes") Tests should cover: color codes present in TTY mode, no color codes with `--no-color`, color codes absent when piped (non-TTY).
- [ ] Add related info and notes to diagnostics — extend error types to carry secondary spans and note messages (e.g., "first defined here" for duplicates). Update `src/diagnostic.zig` and error sites in resolver/type-checker. (per DESIGN.md section "Implementation Notes") Tests should cover: duplicate definition shows both locations, type mismatch shows expected type origin, import conflict shows both sources.

### Testing Strategy
Run `./run-tests.sh`. Create `.ki` files with intentional errors and verify error output includes source snippets, suggestions, and notes. Test `--no-color` flag.

### Phase 4 Readiness Gate
Before Phase 5, these must be true:
- [ ] All errors show source snippets with carets
- [ ] Typo suggestions appear for undefined names
- [ ] Color output works and `--no-color` disables it
- [ ] All prior tests still pass

---

## Phase 5: LSP Server

**Goal:** Build a Language Server Protocol implementation for IDE integration.
**Estimated Effort:** 5 days

### Deliverables
- LSP server binary (`kira lsp`)
- Diagnostics on save
- Hover type information
- Go-to-definition
- Find references
- Completion suggestions

### Tasks
- [ ] Implement LSP JSON-RPC transport layer — create `src/lsp/transport.zig` that reads/writes LSP messages over stdin/stdout with Content-Length headers. (per DESIGN.md section "Implementation Notes") Tests should cover: parse valid message, handle partial reads, write properly framed response, reject malformed headers.
- [ ] Implement LSP initialization handshake — handle `initialize` and `initialized` requests, advertise server capabilities. Create `src/lsp/server.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: respond to initialize with capabilities, handle initialized notification, reject requests before initialize.
- [ ] Implement diagnostics (errors on save) — on `textDocument/didOpen` and `textDocument/didSave`, run the parser/resolver/type-checker and publish diagnostics. Update `src/lsp/server.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: clean file produces no diagnostics, syntax error produces diagnostic with correct range, type error produces diagnostic, multiple errors reported.
- [ ] Implement hover for type information — on `textDocument/hover`, find the symbol at the cursor position and return its type. Create `src/lsp/features.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: hover on variable shows type, hover on function shows signature, hover on type name shows definition, hover on whitespace returns null.
- [ ] Implement go-to-definition — on `textDocument/definition`, resolve the symbol at cursor and return its definition location. Update `src/lsp/features.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: jump to local variable definition, jump to function definition, jump to imported symbol's source file, jump to type definition.
- [ ] Implement find references — on `textDocument/references`, find all uses of the symbol at cursor. Update `src/lsp/features.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: find all uses of a variable, find all uses of a function, find all uses of a type, include/exclude definition based on request.
- [ ] Implement completion suggestions — on `textDocument/completion`, suggest symbols in scope, struct fields after `.`, and module members after `::`. Update `src/lsp/features.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: suggest local variables, suggest module members after import, suggest struct fields after dot, filter by prefix.
- [ ] Add `kira lsp` CLI subcommand — wire the LSP server into the CLI entry point. Update `src/main.zig` or CLI handling. (per DESIGN.md section "Implementation Notes") Tests should cover: `kira lsp` starts and responds to initialize, graceful shutdown on exit notification.

### Testing Strategy
Run `./run-tests.sh`. Write integration tests that send LSP JSON-RPC messages and verify responses. Test with sample `.ki` files containing various language constructs.

### Phase 5 Readiness Gate
Before Phase 6, these must be true:
- [ ] `kira lsp` starts and handles initialize/shutdown
- [ ] Diagnostics published on file open/save
- [ ] Hover, go-to-definition, references, and completion all work
- [ ] All prior tests still pass

---

## Phase 6: Formatter and REPL Improvements

**Goal:** Add `kira fmt` and improve the REPL experience.
**Estimated Effort:** 3 days

### Deliverables
- `kira fmt` command that formats `.ki` files
- REPL with `:type` command, multiline input, tab completion, and history

### Tasks
- [ ] Implement AST pretty-printer — create `src/formatter.zig` that takes an AST and emits canonically formatted Kira source code with consistent indentation and spacing. (per DESIGN.md section "Syntax and Grammar") Tests should cover: indentation of nested blocks, line breaking for long expressions, preservation of comments, consistent spacing around operators.
- [ ] Add `kira fmt` CLI command — parse each input file, pretty-print the AST, and write back. Support `--check` mode (exit non-zero if changes needed). Update CLI handling. (per DESIGN.md section "Syntax and Grammar") Tests should cover: format a messy file produces clean output, `--check` on formatted file exits 0, `--check` on unformatted file exits non-zero, multiple file arguments.
- [ ] Implement REPL `:type` command — when the user enters `:type expr`, parse and type-check the expression and display the inferred type without evaluating. Update `src/repl.zig` or equivalent. (per DESIGN.md section "Type System") Tests should cover: `:type 42` shows `i32`, `:type fn(x: i32) -> i32 { return x }` shows function type, `:type undefined_var` shows error.
- [ ] Add multiline input and history to REPL — detect incomplete expressions (unmatched braces) and continue reading. Persist history to `~/.kira_history`. Update REPL module. (per DESIGN.md section "Implementation Notes") Tests should cover: multiline function definition, history recall, unmatched brace continues prompt, Ctrl-C cancels current input.
- [ ] Add tab completion to REPL — complete keywords, in-scope symbols, and module names on Tab press. Update REPL module. (per DESIGN.md section "Implementation Notes") Tests should cover: complete keyword prefix, complete variable name, complete module name after import, no completions for unknown prefix.

### Testing Strategy
Run `./run-tests.sh`. Test formatter on sample `.ki` files and verify idempotency (formatting twice produces same output). Test REPL features interactively and via scripted input.

### Phase 6 Readiness Gate
Before Phase 7, these must be true:
- [ ] `kira fmt` formats files and `--check` works
- [ ] REPL supports `:type`, multiline, tab completion, and history
- [ ] All prior tests still pass

---

## Phase 7: Intermediate Representation

**Goal:** Design and implement an IR for functional code, lower AST to IR, and apply basic optimizations.
**Estimated Effort:** 4 days

### Deliverables
- IR data structures suited for functional code
- AST-to-IR lowering pass
- IR-level optimizations (inlining, constant folding, dead code elimination)

### Tasks
- [ ] Design IR data structures — create `src/ir.zig` with IR node types: basic blocks, SSA-style values, function definitions, ADT constructors, closure captures, effect annotations. (per DESIGN.md section "Implementation Notes") Tests should cover: construct IR nodes programmatically, IR printer produces readable output, round-trip IR creation and inspection.
- [ ] Implement AST-to-IR lowering for expressions — convert arithmetic, function calls, let bindings, and literals to IR form. Create `src/lower.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: lower integer literal, lower binary operation, lower let binding, lower function call, lower nested expressions.
- [ ] Implement AST-to-IR lowering for control flow — convert if/else, match statements, and for loops to IR basic blocks with branches. Update `src/lower.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: lower if/else to branch, lower match to jump table, lower for loop, nested control flow.
- [ ] Implement AST-to-IR lowering for functions and closures — convert function definitions, closure captures, and effect functions to IR. Update `src/lower.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: lower pure function, lower effect function with annotation, lower closure with captured variables, lower recursive function.
- [ ] Implement constant folding optimization — evaluate constant expressions at IR level. Create `src/ir_opt.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: fold `2 + 3` to `5`, fold boolean logic, fold string concatenation of literals, don't fold expressions with variables.
- [ ] Implement inlining and dead code elimination — inline small pure functions, remove unused bindings. Update `src/ir_opt.zig`. (per DESIGN.md sections "Implementation Notes" and "Effects System") Tests should cover: inline single-use small function, don't inline recursive function, don't inline effect function into pure context, eliminate unused let binding.

### Testing Strategy
Run `./run-tests.sh`. Write tests that lower sample ASTs to IR and verify structure. Verify optimized IR produces same results as unoptimized when interpreted.

### Phase 7 Readiness Gate
Before Phase 8, these must be true:
- [ ] All AST node types lower to IR
- [ ] Constant folding and dead code elimination work
- [ ] IR can represent closures and effects
- [ ] All prior tests still pass

---

## Phase 8: Code Generation

**Goal:** Emit native executables from IR, implement `kira build`, and build the runtime system.
**Estimated Effort:** 5 days

### Deliverables
- Native code generation from IR
- `kira build` command
- Runtime system for ADTs, closures, and garbage collection

### Tasks
- [ ] Implement runtime system for ADTs — create `src/runtime/adt.zig` with tagged union representation, constructor allocation, and pattern match dispatch at native level. (per DESIGN.md sections "Syntax and Grammar" and "Pattern Matching") Tests should cover: construct Option.Some, match on ADT tag, nested ADT construction, memory layout correctness.
- [ ] Implement runtime system for closures — create `src/runtime/closure.zig` with closure allocation, environment capture, and function pointer dispatch. (per DESIGN.md section "Higher-Order Functions") Tests should cover: create closure capturing one variable, call closure, nested closures, closure outlives creating scope.
- [ ] Implement runtime memory management — create `src/runtime/gc.zig` with a simple garbage collector or reference counting for heap-allocated ADTs and closures. (per DESIGN.md section "Implementation Notes") Tests should cover: allocate and collect, no premature collection of live objects, cyclic reference handling if using GC, memory pressure triggers collection.
- [ ] Implement code generation for expressions and functions — emit native code (or C, or LLVM IR) from Kira IR for arithmetic, function calls, and let bindings. Create `src/codegen.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: compile and run arithmetic expression, compile function call, compile let binding, output matches interpreter result.
- [ ] Implement code generation for control flow and pattern matching — emit branches, jumps, and match dispatch. Update `src/codegen.zig`. (per DESIGN.md sections "Implementation Notes" and "Pattern Matching") Tests should cover: compile if/else, compile match on ADT, compile for loop, nested match with guards.
- [ ] Implement code generation for effects and IO — emit code that interfaces with the runtime for IO operations and effect tracking. Update `src/codegen.zig`. (per DESIGN.md section "Effects System") Tests should cover: compile println, compile file read, compile effect function calling pure function, compile error propagation with `?`.
- [ ] Add `kira build` CLI command — wire code generation into the CLI, producing a native executable from `.ki` source. Update CLI handling. (per DESIGN.md section "Implementation Notes") Tests should cover: `kira build hello.ki` produces executable, executable runs and produces correct output, build error on type error, `--output` flag for output path.
- [ ] Implement tail-call optimization — detect tail-position calls in IR and emit jumps instead of calls. Update `src/ir_opt.zig` and `src/codegen.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: recursive factorial with TCO doesn't stack overflow, mutual recursion with TCO, non-tail call preserved as regular call.

### Testing Strategy
Run `./run-tests.sh`. Compile sample `.ki` programs with `kira build` and run the executables. Compare output to interpreter results for the same programs.

### Phase 8 Readiness Gate
Before Phase 9, these must be true:
- [ ] `kira build` produces working native executables
- [ ] ADTs, closures, and effects work in compiled code
- [ ] Tail-call optimization prevents stack overflow on recursive programs
- [ ] All prior tests still pass

---

## Phase 9: Ecosystem

**Goal:** Add package management, documentation generation, testing framework, and interoperability.
**Estimated Effort:** 5 days

### Deliverables
- Package manifest and dependency resolution
- `kira doc` generation
- Property-based testing and benchmarks
- Klar interop and C FFI

### Tasks
- [ ] Design and implement package manifest format — create `kira.toml` or `kira.json` schema for project name, version, dependencies. Create `src/package.zig` for parsing. (per DESIGN.md section "Module System") Tests should cover: parse valid manifest, reject missing required fields, parse dependencies with version constraints, parse empty dependencies.
- [ ] Implement dependency resolution — resolve dependency versions from a registry or git URLs, download and cache packages. Update `src/package.zig`. (per DESIGN.md section "Module System") Tests should cover: resolve single dependency, resolve diamond dependency, version conflict produces error, cached dependency skips download.
- [ ] Add `kira init` scaffolding command — generate project directory with manifest, src/main.ki, and gitignore. Update CLI handling. (per DESIGN.md section "Module System") Tests should cover: creates expected files, doesn't overwrite existing files, `--name` flag customizes project name.
- [ ] Implement `kira doc` generation — extract doc comments (`///`) from parsed AST and generate HTML or Markdown API reference. Create `src/doc_gen.zig`. (per DESIGN.md section "Lexical Elements") Tests should cover: extract function doc comment, extract type doc comment, module-level doc comment (`//!`), markdown formatting preserved in output.
- [ ] Implement property-based testing support — add a `kira test` mode that generates random inputs for functions annotated with test properties. Update test runner. (per DESIGN.md section "Implementation Notes") Tests should cover: generate random i32 inputs, shrink failing case, property holds for simple function, property violation detected.
- [ ] Implement Klar interop — allow Kira pure functions to be called from Klar via a shared calling convention or FFI bridge. Create `src/interop/klar.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: call Kira function from Klar, pass ADT across boundary, type mismatch produces error at compile time.
- [ ] Implement C FFI — allow Kira to declare and call external C functions with explicit type mappings. Create `src/interop/c_ffi.zig`. (per DESIGN.md section "Implementation Notes") Tests should cover: declare external C function, call C function with correct argument marshaling, handle C return values, pointer type mapping.

### Testing Strategy
Run `./run-tests.sh`. Test package management with mock registry. Test doc generation on sample modules. Test interop by compiling and linking Kira+Klar and Kira+C programs.

### Phase 9 Readiness Gate
Before considering the project complete, these must be true:
- [ ] `kira init` creates valid project scaffold
- [ ] Dependencies resolve and modules import from packages
- [ ] `kira doc` generates readable API documentation
- [ ] C FFI and Klar interop work for basic cases
- [ ] All prior tests still pass

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Trait system complexity cascades into method resolution ambiguity | High | Medium | Start with single-impl-per-type constraint, add overlapping impls later |
| String interpolation interacts poorly with existing lexer state machine | Medium | Low | Implement as separate lexer mode with clear entry/exit transitions |
| Effect tracking for mutation requires whole-program analysis | High | Medium | Track effects per-function, not per-expression; conservative analysis |
| LSP transport layer has subtle buffering/framing bugs | Medium | Medium | Use existing LSP test harness; test with real editor early |
| Code generation backend choice (LLVM vs C vs custom) constrains future options | High | Medium | Start with C backend for portability, migrate to LLVM later if needed |
| Garbage collector introduces latency in compiled programs | Medium | High | Start with simple ref counting; GC is a later optimization |
| Package registry infrastructure doesn't exist yet | Medium | High | Support git URL dependencies first; registry is Phase 4+ concern |
| Closure capture semantics differ between interpreter and compiled code | High | Medium | Define capture semantics precisely in IR; test interpreter vs compiled parity |

## Timeline

```
Phase 1: String Interpolation     [2 days]  — No dependencies
Phase 2: Trait System              [4 days]  — Depends on Phase 1 (interpolation used in Show)
Phase 3: Mutation & Effects        [2 days]  — Depends on Phase 2 (traits inform effect checking)
Phase 4: Error Reporting           [3 days]  — Depends on Phase 3 (all language features present for diagnostics)
Phase 5: LSP Server                [5 days]  — Depends on Phase 4 (good diagnostics needed for LSP)
Phase 6: Formatter & REPL          [3 days]  — Depends on Phase 4 (needs complete parser)
Phase 7: Intermediate Repr.        [4 days]  — Depends on Phase 3 (needs complete language semantics)
Phase 8: Code Generation           [5 days]  — Depends on Phase 7 (needs IR)
Phase 9: Ecosystem                 [5 days]  — Depends on Phase 8 (needs kira build)
```

Phases 5–6 can run in parallel after Phase 4. Phases 7–8 can run in parallel with Phases 5–6.

Total estimated effort: ~33 days of agent work.
