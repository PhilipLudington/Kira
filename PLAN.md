# Kira Language Implementation Plan

A functional programming language with explicit types, explicit effects, and no surprises.

> Implementation in Zig for performance and integration with CarbideZig standards.

## Status

| Phase | Status | Progress |
|-------|--------|----------|
| 1. Project Setup | Complete | 4/4 |
| 2. Lexer | Complete | 10/10 |
| 3. AST Definition | Complete | 7/7 |
| 4. Parser | Complete | 20/20 |
| 5. Symbol Table | Complete | 8/8 |
| 6. Type Checker | Complete | 15/15 |
| 7. Effect Checker | Complete | 9/9 |
| 8. Pattern Matching | Complete | 9/9 |
| 9. Interpreter | Complete | 12/12 |
| 10. Standard Library | Complete | 7/7 |
| 11. REPL & CLI | Complete | 8/8 |
| 12. Documentation | Complete | 4/4 |

**Build:** `zig build` | **Test:** `zig build test` | **Run:** `zig build run`

---

## Phase 1: Project Setup
- [x] Initialize Zig project with build.zig
- [x] Set up build system with test configuration
- [x] Create directory structure: `src/lexer`, `src/parser`, `src/typechecker`, `src/effects`, `src/codegen`
- [x] Set up CLI entry point with basic REPL skeleton

## Phase 2: Lexer
- [x] Define token types enum (keywords, operators, literals, punctuation)
- [x] Implement source location tracking (line, column, span)
- [x] Implement keyword recognition: `fn`, `let`, `type`, `module`, `import`, `pub`, `effect`, `trait`, `impl`, `const`, `if`, `else`, `match`, `for`, `return`, `break`, `true`, `false`, `self`, `Self`, `and`, `or`, `not`, `is`, `in`, `as`, `where`, `var`
- [x] Implement operator scanning: arithmetic (`+`, `-`, `*`, `/`, `%`), comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`), special (`?`, `??`, `..`, `..=`, `->`, `=>`, `:`, `::`, `|`)
- [x] Implement integer literals (decimal, hex `0x`, binary `0b`, with underscores, type suffixes)
- [x] Implement float literals (with optional `f32`/`f64` suffix)
- [x] Implement string literals with escape sequences (`\n`, `\t`, `\\`, `\"`)
- [x] Implement comment handling: line (`//`), block (`/* */`), doc (`///`, `//!`)
- [x] Implement newline-as-terminator logic (significant newlines)
- [x] Write lexer tests for all token types

## Phase 3: AST Definition
- [x] Define expression nodes: literals, identifiers, binary ops, unary ops, function calls, field access, index access, tuple access, closures, match expressions
- [x] Define statement nodes: let bindings, var bindings, assignments, if statements, for loops, match statements, return, break
- [x] Define type nodes: primitive types, named types, generic types, function types, tuple types, array types
- [x] Define declaration nodes: function declarations, type declarations (sum types, product types), trait declarations, impl blocks, module declarations, imports
- [x] Define pattern nodes: literal patterns, identifier patterns, constructor patterns, record patterns, tuple patterns, or patterns, wildcard patterns, guard patterns
- [x] Define effect annotations on function types
- [x] Implement pretty-printer for AST debugging

## Phase 4: Parser
- [x] Implement recursive descent parser framework with error recovery
- [x] Parse type annotations: primitives, named types, generics (`List[T]`), function types (`fn(A, B) -> C`), tuples, arrays
- [x] Parse let bindings with explicit type: `let name: Type = expr`
- [x] Parse var bindings: `var name: Type = expr`
- [x] Parse function literals: `fn(params) -> ReturnType { body }`
- [x] Parse effect function declarations: `effect fn name(params) -> EffectType { body }`
- [x] Parse sum type definitions: `type Name[T] = | Variant1(T) | Variant2`
- [x] Parse product type definitions: `type Name = { field1: Type1, field2: Type2 }`
- [x] Parse if statements (not expressions): `if cond { } else { }`
- [x] Parse for loops: `for item in iterable { }`
- [x] Parse match statements with all pattern types
- [x] Parse return and break statements
- [x] Parse binary and unary expressions with correct precedence
- [x] Parse function calls with explicit generic arguments: `func[T](args)`
- [x] Parse field access and method calls
- [x] Parse module declarations: `module path.name`
- [x] Parse imports: `import path.{ item1, item2 as alias }`
- [x] Parse pub visibility modifier
- [x] Parse string interpolation: `"text {expr} more"` (basic support, full interpolation TBD)
- [x] Write comprehensive parser tests

## Phase 5: Symbol Table & Scoping
- [x] Implement symbol table with nested scopes
- [x] Track variable bindings with types
- [x] Track function bindings with signatures
- [x] Track type definitions (sum types, product types, type aliases)
- [x] Track trait definitions and implementations
- [x] Implement module namespace management
- [x] Resolve imports and visibility (pub vs private)
- [x] Detect duplicate definitions and shadowing rules

## Phase 6: Type Checker
- [x] Implement type representation: primitives, named, generic, function, tuple, array
- [x] Verify all let/var bindings have explicit type annotations
- [x] Verify all function parameters have explicit type annotations
- [x] Verify all function return types are explicit
- [x] Check type compatibility in assignments
- [x] Type check binary and unary operations
- [x] Type check function calls with generic instantiation
- [x] Type check pattern matching for exhaustiveness
- [x] Type check record field access
- [x] Type check tuple indexing
- [x] Verify no implicit type conversions (require explicit `.as[T]`)
- [x] Check generic type parameter constraints
- [x] Validate trait implementations match trait signatures
- [x] Produce clear error messages with source locations
- [x] Write type checker tests

## Phase 7: Effect Checker
- [x] Define effect types: `IO`, `Result[T, E]`, pure (no effect)
- [x] Track effect annotations on function types
- [x] Verify pure functions only call pure functions
- [x] Verify effect functions can call both pure and effectful code
- [x] Check `?` operator usage only in effect functions returning `Result`
- [x] Validate main function has `IO` effect
- [x] Track effect propagation through call chains
- [x] Produce clear error messages for purity violations
- [x] Write effect checker tests

## Phase 8: Pattern Match Compiler
- [x] Implement exhaustiveness checking for match statements
- [x] Check for unreachable patterns (dead code)
- [x] Compile constructor patterns with binding extraction
- [x] Compile record patterns with field matching
- [x] Compile tuple patterns
- [x] Compile or-patterns (`|`)
- [x] Compile guard patterns (`if` conditions)
- [x] Handle nested patterns
- [x] Write pattern matching tests

## Phase 9: Tree-Walking Interpreter
- [x] Implement runtime value representation (numbers, strings, bools, functions, ADT values, tuples, arrays)
- [x] Implement environment with lexical scoping
- [x] Evaluate let bindings
- [x] Evaluate var bindings and assignments
- [x] Evaluate arithmetic and comparison operations
- [x] Evaluate function calls and closures
- [x] Evaluate if statements
- [x] Evaluate for loops
- [x] Evaluate match statements with pattern matching
- [x] Implement built-in types: `Option[T]`, `Result[T, E]`, `List[T]`
- [x] Implement `?` operator for error propagation
- [x] Write interpreter tests

## Phase 10: Standard Library (Core)
- [x] Implement `std.list`: `empty`, `singleton`, `cons`, `map`, `filter`, `fold`, `fold_right`, `find`, `any`, `all`, `length`, `reverse`, `concat`, `flatten`, `take`, `drop`, `zip`
- [x] Implement `std.option`: `map`, `and_then`, `unwrap_or`, `is_some`, `is_none`
- [x] Implement `std.result`: `map`, `map_err`, `and_then`, `unwrap_or`, `is_ok`, `is_err`
- [x] Implement `std.string`: `length`, `split`, `trim`, `concat`, `contains`, `starts_with`, `ends_with`
- [x] Implement `std.io` (effect module): `print`, `println`, `read_line`
- [x] Implement `std.fs` (effect module): `read_file`, `write_file`, `exists`, `remove`
- [x] Write standard library tests

## Phase 11: REPL & CLI
- [x] Implement REPL with basic command history (readline-style editing deferred)
- [x] Add `:type` command to show expression types
- [x] Add `:load` command to load `.ki` files
- [x] Add `:help` command
- [x] Implement `kira run <file.ki>` command
- [x] Implement `kira check <file.ki>` for type/effect checking without execution
- [x] Add error formatting with source context and suggestions
- [x] Support `--version` and `--help` flags

## Phase 12: Documentation & Examples
- [x] Write language tutorial
- [x] Document all standard library functions
- [x] Create example programs: factorial, fibonacci, word count, simple parser
- [x] Add syntax highlighting definition for common editors

## Future Phases (Not in Initial Scope)
Compilation to bytecode or native code
Trait system with associated types
Async/await with effect tracking
LSP server for IDE integration
Package manager
