# Kira Documentation

Welcome to the Kira programming language documentation.

Kira is a functional programming language with **explicit types**, **explicit effects**, and **no surprises**. It's designed for clarity and predictability, making it ideal for AI code generation and teams that value readable code.

## Documentation Overview

| Document | Description | Best For |
|----------|-------------|----------|
| [tutorial.md](tutorial.md) | Step-by-step introduction | New users learning the language |
| [reference.md](reference.md) | Complete syntax and semantics | Looking up language details |
| [stdlib.md](stdlib.md) | Standard library API reference | Finding functions and types |
| [quickref.md](quickref.md) | Concise cheat sheet | Quick lookup while coding |

## Quick Start

### Installation

```bash
git clone https://github.com/PhilipLudington/Kira.git
cd Kira
zig build
```

### Hello World

Create `hello.ki`:

```kira
effect fn main() -> void {
    std.io.println("Hello, Kira!")
}
```

Run it:

```bash
kira run hello.ki
```

## Core Concepts

### 1. Explicit Types

Every variable, parameter, and return type must be annotated:

```kira
let x: i32 = 42
fn add(a: i32, b: i32) -> i32 { return a + b }
```

### 2. Explicit Effects

Side effects are tracked in function signatures:

```kira
// Pure function - no side effects
fn double(n: i32) -> i32 { return n * 2 }

// Effect function - can perform I/O
effect fn greet(name: string) -> void {
    std.io.println("Hello, " + name)
}
```

### 3. Pattern Matching

Work with data safely using exhaustive pattern matching:

```kira
match result {
    Ok(value) => { std.io.println("Success: " + to_string(value)) }
    Err(e) => { std.io.println("Error: " + e) }
}
```

### 4. Algebraic Data Types

Define your own types with sum (enum) and product (record) types:

```kira
type Shape =
    | Circle(f64)
    | Rectangle(f64, f64)

type Point = { x: f64, y: f64 }
```

## Standard Library Modules

| Module | Description |
|--------|-------------|
| `std.io` | Console I/O (print, read) |
| `std.fs` | File system operations |
| `std.list` | List operations (map, filter, fold) |
| `std.option` | Optional value operations |
| `std.result` | Error handling operations |
| `std.string` | String manipulation |
| `std.builder` | Efficient string building |
| `std.map` | Hash map (dictionary) |
| `std.char` | Character operations |
| `std.math` | Mathematical operations |
| `std.time` | Time and timing |
| `std.assert` | Assertions for testing |

## Example Programs

The `examples/` directory contains working programs demonstrating various features:

- `hello.ki` - Basic program structure
- `factorial.ki` - Recursion
- `fibonacci.ki` - Multiple approaches
- `list_operations.ki` - Working with lists
- `option_handling.ki` - Optional values
- `calculator.ki` - Expression evaluation with ADTs
- `json_builder.ki` - String building and sum types
- `error_chain.ki` - Error handling patterns
- And more...

## Learning Path

1. **Start here**: Read [tutorial.md](tutorial.md) from beginning to end
2. **Practice**: Try the examples in `examples/`
3. **Reference**: Use [stdlib.md](stdlib.md) to explore available functions
4. **Quick lookup**: Keep [quickref.md](quickref.md) handy while coding
5. **Deep dive**: Consult [reference.md](reference.md) for language details

## Need Help?

- Check the examples for working code patterns
- Read the standard library documentation for function signatures
- Look at the language reference for syntax questions

---

*Kira: Pure clarity for functional programming.*
