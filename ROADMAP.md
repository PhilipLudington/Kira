# Kira — Roadmap

## Phase 0: Foundation ✅

**Status:** Complete (v0.11.1)

### Core Language
- [x] Lexer with all keywords and operators
- [x] Recursive descent parser
- [x] Two-pass resolver with symbol table and scope management
- [x] Type checker with explicit type annotations
- [x] Tree-walking interpreter

### Type System
- [x] All primitive types (i8–i128, u8–u128, f32, f64, bool, char, string, void)
- [x] Algebraic data types (sum types and record types)
- [x] Tuples and fixed-size arrays
- [x] Generic types with explicit type parameters
- [x] Function types as first-class values
- [x] No implicit conversions

### Effects System
- [x] Pure functions by default
- [x] `effect` keyword for side-effecting functions
- [x] Compiler-enforced purity boundary

### Pattern Matching
- [x] Literal, constructor, record, and tuple patterns
- [x] Or-patterns and guard clauses
- [x] Range patterns and rest patterns
- [x] Exhaustiveness checking
- [x] Destructuring in let bindings

### Module System
- [x] Module declarations
- [x] Cross-file imports with symbol resolution
- [x] Selective imports (`import std.list.{ map, filter }`)
- [x] Aliased imports
- [x] Pub/private visibility

### Standard Library
- [x] 17 modules: io, list, string, option, result, map, set, math, assert, int, float, fs, char, convert, json, bytes, time
- [x] Core types auto-imported: Option[T], Result[T, E], List[T]

### CLI & Tooling
- [x] `kira run`, `kira check`, `kira test`, `kira repl`
- [x] `--tokens` and `--ast` debug flags
- [x] VSCode syntax highlighting
- [x] 285 passing tests

---

## Phase 1: Language Completeness ✅

**Status:** Complete (2026-03-04)

### String Interpolation
- [x] Implement interpolation parsing (`"hello {name}"`)
- [x] Type-check interpolated expressions
- [x] Interpreter support for interpolated strings

### Trait System
- [x] Type-check trait declarations and verify method signatures
- [x] Enforce impl blocks satisfy trait requirements
- [x] Method resolution through impl blocks
- [x] Trait bounds on generic type parameters

### Mutation in Effect Functions
- [x] Mutable field access in assignments
- [x] Mutable index access in assignments
- [x] Verify mutation only occurs in effect functions

### Error Reporting
- [x] Source code snippets in error messages
- [x] "Did you mean?" suggestions for typos
- [x] Color output for terminal diagnostics
- [x] Related info and notes on errors

---

## Phase 2: Developer Experience ✅

**Status:** Complete (2026-03-05)

### LSP Server
- [x] Diagnostics (errors and warnings on save)
- [x] Hover for type information
- [x] Go-to-definition
- [x] Find references
- [x] Completion suggestions

### Formatter
- [x] `kira fmt` command
- [x] Consistent formatting rules matching language conventions
- [x] Format-on-save integration with editors

### REPL Improvements
- [x] `:type` shows actual inferred types
- [x] Multiline input support
- [x] Tab completion
- [x] History persistence

---

## Phase 3: Compilation ✅

**Status:** Complete (2026-03-05)

### Intermediate Representation
- [x] Design IR suited for functional code
- [x] Lower AST to IR after type checking
- [x] IR-level optimizations for pure functions (inlining, constant folding)

### Code Generation
- [x] Implement for-loop IR lowering (iterator protocol)
- [x] Scope `lookupVariantTag` to expected type (variant disambiguation)
- [x] C backend for native executables
- [x] Emit native executables
- [x] `kira build` command
- [x] Runtime system for ADTs and closures

### Optimization
- [x] Memoization of pure functions
- [x] Tail-call optimization
- [x] Dead code elimination
- [x] Closure capture optimization

---

## Phase 4: Ecosystem ✅

**Status:** Complete (2026-03-06)

### Package Management
- [x] Package manifest format (`kira.toml` with version constraints)
- [x] Dependency resolution (path, git, cached; diamond deps, cycle detection)
- [x] `kira init` project scaffolding

### Documentation
- [x] `kira doc` generation from doc comments (`///` and `//!`)
- [x] Searchable API reference output

### Testing Framework
- [x] Property-based testing support (`prop_test` builtin)
- [x] Test coverage reporting
- [x] Benchmark harness

### Interoperability
- [x] Klar interop (C header and Klar extern block generation)
- [x] C FFI for system-level integration
