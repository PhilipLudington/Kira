# Kira Example Programs

This directory contains example programs demonstrating Kira language features.

## Running Examples

```bash
kira run examples/hello.ki
```

Or using the build system:

```bash
zig build run -- run examples/hello.ki
```

## Examples by Category

### Getting Started

| File | Description |
|------|-------------|
| `hello.ki` | Minimal "Hello, World!" program |
| `fizzbuzz.ki` | Classic FizzBuzz problem |

### Functions and Recursion

| File | Description |
|------|-------------|
| `factorial.ki` | Recursive factorial calculation |
| `fibonacci.ki` | Fibonacci sequence (multiple approaches) |

### Data Types

| File | Description |
|------|-------------|
| `temperature.ki` | Unit conversion with custom types |
| `calculator.ki` | Expression AST with sum types |
| `json_builder.ki` | JSON representation with ADTs |
| `binary_tree.ki` | Recursive binary tree structure |
| `stack.ki` | Stack data structure implementation |

### Lists and Collections

| File | Description |
|------|-------------|
| `list_operations.ki` | Basic list manipulation |
| `quicksort.ki` | Quicksort algorithm on lists |

### Pattern Matching

| File | Description |
|------|-------------|
| `option_handling.ki` | Working with Option types |
| `calculator.ki` | Pattern matching on expressions |

### Error Handling

| File | Description |
|------|-------------|
| `error_chain.ki` | Error propagation patterns |
| `option_handling.ki` | Handling missing values |

### Parsing

| File | Description |
|------|-------------|
| `simple_parser.ki` | Basic expression parser |
| `calculator.ki` | Expression evaluation |

### Modules

| File | Description |
|------|-------------|
| `modules_demo.ki` | Module imports and usage |
| `geometry_combined.ki` | Combined geometry operations |

### Testing

| File | Description |
|------|-------------|
| `test_assertions.ki` | Using assertions for testing |
| `test_example.ki` | Example test patterns |

### Advanced Features

| File | Description |
|------|-------------|
| `time_test.ki` | Time operations and benchmarking |
| `parallel_test.ki` | Parallel processing concepts |
| `word_count.ki` | Complete program combining features |

## Example Structure

Most examples follow this pattern:

```kira
// Description comment at top

// Type definitions (if any)
type MyType = ...

// Pure functions
fn helper(...) -> ... { ... }

// Entry point (effect function)
effect fn main() -> void {
    // Main program logic
    std.io.println("Output")
}
```

## Learning Path

1. Start with `hello.ki` and `fizzbuzz.ki`
2. Study `factorial.ki` for recursion
3. Explore `calculator.ki` for ADTs and pattern matching
4. Read `error_chain.ki` for error handling
5. Try `word_count.ki` for a complete program

## Creating Your Own

Use these examples as templates. Remember:

- Every function needs explicit types
- Use `effect fn` for functions with I/O
- Handle all cases in match statements
- Pure functions cannot call effect functions
