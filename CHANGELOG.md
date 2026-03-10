# Changelog

## [0.4.0] - 2026-01-22

### Added
- Add numeric-to-string conversion functions to std.string module: from_i32, from_i64, from_int, from_f32, from_f64, from_float, from_bool, and to_string
- Add std.time module with time operations:
  - `now()` - Get current timestamp in milliseconds (effect function)
  - `sleep(ms)` - Sleep for specified milliseconds (effect function) 
  - `elapsed(start, end)` - Calculate elapsed time between timestamps (pure function)
- Add parallel collection functions to std.list module:
  - `parallel_map(list, fn)` - Apply pure function to each element in parallel
  - `parallel_filter(list, fn)` - Filter elements using pure predicate in parallel
  - `parallel_fold(list, init, fn)` - Fold list using pure associative function with parallel reduction
- Add foreach function to std.list module

### Fixed
- Fix higher-order functions to properly support user-defined closures and named functions
- Fix TypeMismatch errors when using std.list.map, filter, and fold with inline closures or named functions
- Fix argument order in list higher-order functions to use data-first convention (list, function)

### Changed
- Update builtin function signatures to use BuiltinContext instead of plain Allocator
- Enable builtin functions to call back into interpreter for invoking user-defined closures
- Parallel functions automatically fall back to sequential execution for user-defined functions (interpreter is not thread-safe) and small lists

## [v0.2.0] - 2026-01-20

### Added

- 10 new example programs demonstrating core Kira language features including:
  - stack.ki: List operations using std.list module
  - binary_tree.ki: Recursive algebraic data types and tree traversal algorithms
  - calculator.ki: Expression evaluation with pattern matching on sum types
  - list_operations.ki: List construction and manipulation using std.list
  - option_handling.ki: Option type patterns for safe null handling
  - error_chain.ki: Result type and error handling patterns
  - fizzbuzz.ki: Recursive functions and conditionals
  - temperature.ki: Product types (records) and sum types for temperature conversion
  - quicksort.ki: Comparison functions and sorting algorithms
  - json_builder.ki: String manipulation and JSON data structure building
- Support for qualified record construction syntax (e.g., `module.TypeName { field: value }`)
- Detailed parse error reporting with line/column numbers and source context
- Module namespace registration for qualified imports (e.g., `src.json.TypeName`)

### Fixed

- Memory leaks in AST parser, stdlib interpreter, and symbol table management
- Module import resolution for nested module paths and qualified names
- Parse error messages now include source line context and caret positioning
- Memory management for diagnostic messages in TypeChecker and Resolver

## [v0.1.1] - 2026-01-20

### Added

- Add `std.int` module with essential integer operations including `to_string()`, `parse()`, `abs()`, `min()`, `max()`, and `sign()` functions for integer-to-string conversion and mathematical operations
- Add `Program.deinit()` method for proper cleanup of parsed AST structures
- Add arena allocator to `Program` struct for automatic memory management of all AST node allocations

### Fixed

- Fix sum type and generic type parsing to properly handle multi-line type definitions by adding `skipNewlines()` calls in parser
- Fix pattern matching crashes by parsing numeric literal values in the lexer instead of leaving them as `.none`, which caused undefined access when matching integer patterns
- Fix all memory leaks in the codebase - all 164 tests now pass with 0 memory leaks (previously 37)
- Fix parser to correctly parse integer and float literals with hex, binary, underscores, and type suffixes
- Fix memory cleanup by using interpreter's arena allocator for stdlib and builtin registration

### Changed

- Update `Program.deinit()` API to no longer require an allocator parameter - arena allocator handles all cleanup automatically
- Improve lexer to parse numeric literal values during tokenization for better pattern matching support

## v0.1.0

No changes in this release.
