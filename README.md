# Kira

A functional programming language with explicit types and tracked effects, designed for AI code generation.

**Repository:** https://github.com/PhilipLudington/Kira

## Features

- **Pure by default** - Functions are pure unless explicitly marked with `effect`
- **Explicit types** - No type inference; all types are visible and clear
- **Tracked effects** - IO, State, and Error effects are visible in function signatures
- **Pattern matching** - Full support for algebraic data types
- **Generics** - Explicit type parameters for polymorphic code
- **Module system** - Hierarchical modules with visibility control

## Installation

### Prerequisites

- [Zig](https://ziglang.org/download/) (0.14.0 or later)

### Build from Source

```bash
git clone https://github.com/PhilipLudington/Kira
cd Kira
zig build
```

The executable will be at `zig-out/bin/Kira`.

## Usage

### Run a Program

```bash
zig build run -- examples/hello.ki
# or after building:
./zig-out/bin/Kira run examples/hello.ki
```

### Type-Check Only

```bash
zig build run -- check examples/hello.ki
```

### Interactive REPL

```bash
zig build run
# or
./zig-out/bin/Kira
```

REPL commands:
- `:help` - Show help
- `:quit` - Exit
- `:type <expr>` - Show expression type
- `:load <file>` - Load a .ki file
- `:clear` - Clear environment

### Debug Options

```bash
zig build run -- --tokens examples/hello.ki  # Show token stream
zig build run -- --ast examples/hello.ki     # Show AST
```

## Language Overview

### Hello World

```kira
effect fn main() -> void {
    std.io.println("Hello, Kira!")
}
```

### Variables and Types

```kira
let x: i32 = 42
let name: string = "Alice"
let pi: f64 = 3.14159
let active: bool = true
```

### Functions

Pure functions (default):
```kira
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

fn factorial(n: i32) -> i32 {
    if n <= 1 { return 1 }
    return n * factorial(n - 1)
}
```

Effect functions (can perform I/O):
```kira
effect fn greet(name: string) -> void {
    std.io.println("Hello, " + name + "!")
}
```

### Algebraic Data Types

```kira
type Option[T] =
    | Some(T)
    | None

type List[T] =
    | Cons(T, List[T])
    | Nil

type Point = {
    x: f64,
    y: f64
}
```

### Pattern Matching

```kira
fn describe(opt: Option[i32]) -> string {
    match opt {
        Some(n) if n > 0 => { return "positive" }
        Some(n) if n < 0 => { return "negative" }
        Some(_) => { return "zero" }
        None => { return "nothing" }
    }
}
```

### Higher-Order Functions

```kira
fn map[T, U](list: List[T], f: fn(T) -> U) -> List[U] {
    match list {
        Nil => { return Nil }
        Cons(head, tail) => { return Cons(f(head), map(tail, f)) }
    }
}
```

## Primitive Types

| Type | Description |
|------|-------------|
| `i8`, `i16`, `i32`, `i64`, `i128` | Signed integers |
| `u8`, `u16`, `u32`, `u64`, `u128` | Unsigned integers |
| `f32`, `f64` | Floating point |
| `bool` | Boolean |
| `char` | Character |
| `string` | String |
| `void` | Unit type |

## Standard Library

- `std.io` - Input/output operations
- `std.list` - List operations (map, filter, fold, etc.)
- `std.option` - Option type helpers
- `std.result` - Result type helpers
- `std.string` - String manipulation
- `std.fs` - File system operations

## Examples

The `examples/` directory contains sample programs:

- `hello.ki` - Hello world
- `factorial.ki` - Recursive functions
- `fibonacci.ki` - Multiple recursion approaches
- `binary_tree.ki` - Algebraic data types
- `option_handling.ki` - Option type usage
- `quicksort.ki` - Sorting algorithms
- `calculator.ki` - Expression evaluation
- `fizzbuzz.ki` - Classic algorithm

Run an example:
```bash
zig build run -- examples/factorial.ki
```

## Documentation

- [Language Design](DESIGN.md) - Complete language specification
- [Tutorial](docs/tutorial.md) - Step-by-step guide
- [Standard Library](docs/stdlib.md) - API reference

## Ecosystem

- [kira-pcl](https://github.com/PhilipLudington/kira-pcl) - Kira PCL
- [kira-json](https://github.com/PhilipLudington/kira-json) - JSON parsing and serialization library for Kira
- [Kira-Toolkit](https://github.com/PhilipLudington/Kira-Toolkit) - Toolkit for Kira

## License

See [LICENSE](LICENSE) for details.
