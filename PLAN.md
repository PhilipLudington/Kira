# Kira Language Implementation Plan

A functional programming language with explicit types, explicit effects, and no surprises.

## Phase 1: Project Setup
- [ ] Initialize TypeScript project with strict mode
- [ ] Set up build system (esbuild or tsc)
- [ ] Configure test framework (Vitest)
- [ ] Create directory structure: `src/lexer`, `src/parser`, `src/typechecker`, `src/effects`, `src/codegen`
- [ ] Set up CLI entry point with basic REPL skeleton

## Phase 2: Lexer
- [ ] Define token types enum (keywords, operators, literals, punctuation)
- [ ] Implement source location tracking (line, column, span)
- [ ] Implement keyword recognition: `fn`, `let`, `type`, `module`, `import`, `pub`, `effect`, `trait`, `impl`, `const`, `if`, `else`, `match`, `for`, `return`, `break`, `true`, `false`, `self`, `Self`, `and`, `or`, `not`, `is`, `in`, `as`, `where`, `var`
- [ ] Implement operator scanning: arithmetic (`+`, `-`, `*`, `/`, `%`), comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`), special (`?`, `??`, `..`, `..=`, `->`, `=>`, `:`, `::`, `|`)
- [ ] Implement integer literals (decimal, hex `0x`, binary `0b`, with underscores, type suffixes)
- [ ] Implement float literals (with optional `f32`/`f64` suffix)
- [ ] Implement string literals with escape sequences (`\n`, `\t`, `\\`, `\"`)
- [ ] Implement comment handling: line (`//`), block (`/* */`), doc (`///`, `//!`)
- [ ] Implement newline-as-terminator logic (significant newlines)
- [ ] Write lexer tests for all token types

## Phase 3: AST Definition
- [ ] Define expression nodes: literals, identifiers, binary ops, unary ops, function calls, field access, index access, tuple access, closures, match expressions
- [ ] Define statement nodes: let bindings, var bindings, assignments, if statements, for loops, match statements, return, break
- [ ] Define type nodes: primitive types, named types, generic types, function types, tuple types, array types
- [ ] Define declaration nodes: function declarations, type declarations (sum types, product types), trait declarations, impl blocks, module declarations, imports
- [ ] Define pattern nodes: literal patterns, identifier patterns, constructor patterns, record patterns, tuple patterns, or patterns, wildcard patterns, guard patterns
- [ ] Define effect annotations on function types
- [ ] Implement pretty-printer for AST debugging

## Phase 4: Parser
- [ ] Implement recursive descent parser framework with error recovery
- [ ] Parse type annotations: primitives, named types, generics (`List[T]`), function types (`fn(A, B) -> C`), tuples, arrays
- [ ] Parse let bindings with explicit type: `let name: Type = expr`
- [ ] Parse var bindings: `var name: Type = expr`
- [ ] Parse function literals: `fn(params) -> ReturnType { body }`
- [ ] Parse effect function declarations: `effect fn name(params) -> EffectType { body }`
- [ ] Parse sum type definitions: `type Name[T] = | Variant1(T) | Variant2`
- [ ] Parse product type definitions: `type Name = { field1: Type1, field2: Type2 }`
- [ ] Parse if statements (not expressions): `if cond { } else { }`
- [ ] Parse for loops: `for item in iterable { }`
- [ ] Parse match statements with all pattern types
- [ ] Parse return and break statements
- [ ] Parse binary and unary expressions with correct precedence
- [ ] Parse function calls with explicit generic arguments: `func[T](args)`
- [ ] Parse field access and method calls
- [ ] Parse module declarations: `module path.name`
- [ ] Parse imports: `import path.{ item1, item2 as alias }`
- [ ] Parse pub visibility modifier
- [ ] Parse string interpolation: `"text {expr} more"`
- [ ] Write comprehensive parser tests

## Phase 5: Symbol Table & Scoping
- [ ] Implement symbol table with nested scopes
- [ ] Track variable bindings with types
- [ ] Track function bindings with signatures
- [ ] Track type definitions (sum types, product types, type aliases)
- [ ] Track trait definitions and implementations
- [ ] Implement module namespace management
- [ ] Resolve imports and visibility (pub vs private)
- [ ] Detect duplicate definitions and shadowing rules

## Phase 6: Type Checker
- [ ] Implement type representation: primitives, named, generic, function, tuple, array
- [ ] Verify all let/var bindings have explicit type annotations
- [ ] Verify all function parameters have explicit type annotations
- [ ] Verify all function return types are explicit
- [ ] Check type compatibility in assignments
- [ ] Type check binary and unary operations
- [ ] Type check function calls with generic instantiation
- [ ] Type check pattern matching for exhaustiveness
- [ ] Type check record field access
- [ ] Type check tuple indexing
- [ ] Verify no implicit type conversions (require explicit `.as[T]`)
- [ ] Check generic type parameter constraints
- [ ] Validate trait implementations match trait signatures
- [ ] Produce clear error messages with source locations
- [ ] Write type checker tests

## Phase 7: Effect Checker
- [ ] Define effect types: `IO`, `Result[T, E]`, pure (no effect)
- [ ] Track effect annotations on function types
- [ ] Verify pure functions only call pure functions
- [ ] Verify effect functions can call both pure and effectful code
- [ ] Check `?` operator usage only in effect functions returning `Result`
- [ ] Validate main function has `IO` effect
- [ ] Track effect propagation through call chains
- [ ] Produce clear error messages for purity violations
- [ ] Write effect checker tests

## Phase 8: Pattern Match Compiler
- [ ] Implement exhaustiveness checking for match statements
- [ ] Check for unreachable patterns (dead code)
- [ ] Compile constructor patterns with binding extraction
- [ ] Compile record patterns with field matching
- [ ] Compile tuple patterns
- [ ] Compile or-patterns (`|`)
- [ ] Compile guard patterns (`if` conditions)
- [ ] Handle nested patterns
- [ ] Write pattern matching tests

## Phase 9: Tree-Walking Interpreter
- [ ] Implement runtime value representation (numbers, strings, bools, functions, ADT values, tuples, arrays)
- [ ] Implement environment with lexical scoping
- [ ] Evaluate let bindings
- [ ] Evaluate var bindings and assignments
- [ ] Evaluate arithmetic and comparison operations
- [ ] Evaluate function calls and closures
- [ ] Evaluate if statements
- [ ] Evaluate for loops
- [ ] Evaluate match statements with pattern matching
- [ ] Implement built-in types: `Option[T]`, `Result[T, E]`, `List[T]`
- [ ] Implement `?` operator for error propagation
- [ ] Write interpreter tests

## Phase 10: Standard Library (Core)
- [ ] Implement `std.list`: `empty`, `singleton`, `cons`, `map`, `filter`, `fold`, `fold_right`, `find`, `any`, `all`, `length`, `reverse`, `concat`, `flatten`, `take`, `drop`, `zip`
- [ ] Implement `std.option`: `map`, `and_then`, `unwrap_or`, `is_some`, `is_none`
- [ ] Implement `std.result`: `map`, `map_err`, `and_then`, `unwrap_or`, `is_ok`, `is_err`
- [ ] Implement `std.string`: `length`, `split`, `trim`, `concat`, `contains`, `starts_with`, `ends_with`
- [ ] Implement `std.io` (effect module): `print`, `println`, `read_line`
- [ ] Implement `std.fs` (effect module): `read_file`, `write_file`, `exists`, `remove`
- [ ] Write standard library tests

## Phase 11: REPL & CLI
- [ ] Implement REPL with readline support
- [ ] Add `:type` command to show expression types
- [ ] Add `:load` command to load `.ki` files
- [ ] Add `:help` command
- [ ] Implement `kira run <file.ki>` command
- [ ] Implement `kira check <file.ki>` for type/effect checking without execution
- [ ] Add error formatting with source context and suggestions
- [ ] Support `--version` and `--help` flags

## Phase 12: Documentation & Examples
- [ ] Write language tutorial
- [ ] Document all standard library functions
- [ ] Create example programs: factorial, fibonacci, word count, simple parser
- [ ] Add syntax highlighting definition for common editors

## Future Phases (Not in Initial Scope)
Compilation to bytecode or native code
Trait system with associated types
Async/await with effect tracking
LSP server for IDE integration
Package manager
