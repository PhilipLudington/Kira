# Kira Language Tutorial

Welcome to Kira! This tutorial will guide you through the language from the basics to advanced features.

Kira is a functional programming language with explicit types, explicit effects, and no surprises. It's designed for clarity and predictability, making it ideal for AI code generation and teams that value explicit, readable code.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Your First Program](#your-first-program)
3. [Basic Types](#basic-types)
4. [Functions](#functions)
5. [Algebraic Data Types](#algebraic-data-types)
6. [Pattern Matching](#pattern-matching)
7. [Control Flow](#control-flow)
8. [The Effects System](#the-effects-system)
9. [Higher-Order Functions](#higher-order-functions)
10. [Working with Lists](#working-with-lists)
11. [Error Handling](#error-handling)
12. [Modules and Imports](#modules-and-imports)

---

## Getting Started

### Installation

Build Kira from source:

```bash
git clone https://github.com/PhilipLudington/Kira.git
cd Kira
./build.sh
```

### Running Programs

```bash
# Run a Kira file
kira run examples/hello.ki

# Type check without running
kira check examples/hello.ki

# Start the REPL
kira
```

### REPL Commands

When in the REPL, you can use these commands:

- `:help` - Show help message
- `:type <expr>` - Show the type of an expression
- `:load <file>` - Load a `.ki` file
- `:quit` - Exit the REPL

---

## Your First Program

Create a file called `hello.ki`:

```kira
// hello.ki - Your first Kira program

effect fn main() -> void {
    std.io.println("Hello, Kira!")
}
```

Run it:

```bash
kira run hello.ki
```

Output:

```
Hello, Kira!
```

Let's break this down:

- `effect fn main()` declares an **effect function** named `main`
- `-> void` means it returns nothing
- `std.io.println` is a standard library function for printing
- The `effect` keyword indicates this function performs side effects (I/O)

---

## Basic Types

Kira has explicit types everywhere. Every binding must have a type annotation.

### Numeric Types

```kira
// Signed integers
let a: i8 = 127
let b: i16 = 32000
let c: i32 = 42
let d: i64 = 1000000
let e: i128 = 170141183460469231731687303715884105727

// Unsigned integers
let f: u8 = 255
let g: u16 = 65535
let h: u32 = 4294967295
let i: u64 = 18446744073709551615

// Floating point
let pi: f32 = 3.14159
let precise_pi: f64 = 3.141592653589793

// Integer literals with underscores for readability
let million: i32 = 1_000_000

// Different bases
let hex: i32 = 0xff        // 255 in decimal
let binary: i32 = 0b1010   // 10 in decimal

// Type suffixes
let explicit: i64 = 42i64
let float32: f32 = 3.14f32
```

### Boolean and Character Types

```kira
let flag: bool = true
let is_ready: bool = false

let letter: char = 'A'
let emoji: char = '🎉'
```

### Strings

```kira
let greeting: string = "Hello, World!"
let multiline: string = "Line 1\nLine 2\nLine 3"

// Escape sequences
let escaped: string = "Tab:\tNewline:\nQuote:\""
```

### Tuples

Tuples are fixed-size collections of heterogeneous values:

```kira
let pair: (i32, string) = (42, "hello")
let triple: (i32, bool, f64) = (1, true, 3.14)

// Access tuple elements by index
let first: i32 = pair.0      // 42
let second: string = pair.1  // "hello"
```

### Arrays

Arrays have a fixed size known at compile time:

```kira
let numbers: [i32; 5] = [1, 2, 3, 4, 5]
let zeroes: [i32; 3] = [0, 0, 0]
```

---

## Functions

In Kira, functions are values. Every function has an explicit type signature.

### Function Syntax

There are two ways to define functions:

**Declaration style (top-level):**

```kira
fn add(a: i32, b: i32) -> i32 {
    return a + b
}
```

**Expression style (as values):**

```kira
let add: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 {
    return a + b
}
```

### Function Rules

1. **All parameters must have explicit types**
2. **Return type must be explicit**
3. **Use explicit `return` statements**

```kira
// Multi-line function
fn factorial(n: i32) -> i32 {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}

// Function returning nothing
fn greet(name: string) -> void {
    std.io.println("Hello, " + name + "!")
    return
}
```

### Generic Functions

Use type parameters in square brackets:

```kira
// Generic identity function
fn identity[T](x: T) -> T {
    return x
}

// Call with explicit type argument
let n: i32 = identity[i32](42)
let s: string = identity[string]("hello")
```

---

## Algebraic Data Types

Kira supports sum types (tagged unions) and product types (records).

### Sum Types

Sum types represent a value that can be one of several variants:

```kira
// Option type - a value that may or may not exist
type Option[T] =
    | Some(T)
    | None

// Result type - success or failure
type Result[T, E] =
    | Ok(T)
    | Err(E)

// List type - recursive linked list
type List[T] =
    | Cons(T, List[T])
    | Nil

// Custom sum type
type Shape =
    | Circle(f64)
    | Rectangle(f64, f64)
    | Triangle(f64, f64, f64)
```

Creating sum type values:

```kira
let some_value: Option[i32] = Some(42)
let no_value: Option[i32] = None

let success: Result[i32, string] = Ok(100)
let failure: Result[i32, string] = Err("Something went wrong")

let numbers: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
```

### Product Types (Records)

Product types are records with named fields:

```kira
type Point = {
    x: f64,
    y: f64
}

type User = {
    id: i64,
    name: string,
    email: string,
    active: bool
}
```

Creating and accessing records:

```kira
let origin: Point = Point { x: 0.0, y: 0.0 }
let p: Point = Point { x: 3.0, y: 4.0 }

// Access fields with dot notation
let x_coord: f64 = p.x
let y_coord: f64 = p.y

let user: User = User {
    id: 1,
    name: "Alice",
    email: "alice@example.com",
    active: true
}
```

---

## Pattern Matching

Pattern matching is how you work with sum types and destructure data.

### Match Statement

```kira
fn describe_option(opt: Option[i32]) -> string {
    var result: string = ""
    match opt {
        Some(n) => { result = "Has value: " + to_string(n) }
        None => { result = "Empty" }
    }
    return result
}

fn area(shape: Shape) -> f64 {
    var result: f64 = 0.0
    match shape {
        Circle(r) => { result = 3.14159 * r * r }
        Rectangle(w, h) => { result = w * h }
        Triangle(a, b, c) => {
            // Heron's formula
            let s: f64 = (a + b + c) / 2.0
            result = sqrt(s * (s - a) * (s - b) * (s - c))
        }
    }
    return result
}
```

### Pattern Types

**Literal patterns:**

```kira
match value {
    0 => { result = "zero" }
    1 => { result = "one" }
    _ => { result = "other" }
}
```

**Constructor patterns:**

```kira
match option {
    Some(x) => { result = x }
    None => { result = 0 }
}
```

**Record patterns:**

```kira
match point {
    Point { x: 0.0, y: 0.0 } => { result = "origin" }
    Point { x: 0.0, y: y } => { result = "on y-axis" }
    Point { x: x, y: 0.0 } => { result = "on x-axis" }
    Point { x: x, y: y } => { result = "general point" }
}
```

**Tuple patterns:**

```kira
match pair {
    (0, 0) => { result = "origin" }
    (x, 0) => { result = "on x-axis" }
    (0, y) => { result = "on y-axis" }
    (x, y) => { result = "general" }
}
```

**Or patterns:**

```kira
match value {
    1 | 2 | 3 => { result = "small" }
    4 | 5 | 6 => { result = "medium" }
    _ => { result = "large" }
}
```

**Guard patterns:**

```kira
match value {
    n if n < 0 => { result = "negative" }
    n if n > 100 => { result = "large" }
    n => { result = "normal" }
}
```

### Destructuring in Let

```kira
let p: Point = Point { x: 3.0, y: 4.0 }
let Point { x: px, y: py }: Point = p

let pair: (i32, string) = (42, "hello")
let (n, s): (i32, string) = pair
```

---

## Control Flow

Control flow constructs in Kira are statements, not expressions.

### If Statements

```kira
fn max(a: i32, b: i32) -> i32 {
    if a > b {
        return a
    }
    return b
}

fn sign(n: i32) -> string {
    var result: string = ""
    if n > 0 {
        result = "positive"
    } else if n < 0 {
        result = "negative"
    } else {
        result = "zero"
    }
    return result
}
```

### For Loops

For loops iterate over collections:

```kira
fn sum_list(items: List[i32]) -> i32 {
    var total: i32 = 0
    for item in items {
        total = total + item
    }
    return total
}
```

### Return and Break

```kira
fn find_first_even(items: List[i32]) -> Option[i32] {
    for item in items {
        if item % 2 == 0 {
            return Some(item)
        }
    }
    return None
}
```

---

## The Effects System

Kira tracks effects in types. This is one of its most important features.

### Pure Functions (Default)

By default, functions are **pure**. Pure functions:

- Always return the same output for the same input
- Have no side effects (no I/O, no mutation)
- Can be freely memoized, parallelized, or reordered

```kira
// Pure function - no side effects
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// Pure function - complex computation
fn fibonacci(n: i32) -> i32 {
    if n <= 1 {
        return n
    }
    return fibonacci(n - 1) + fibonacci(n - 2)
}
```

### Effect Functions

Effect functions are marked with the `effect` keyword. They can perform side effects like I/O:

```kira
// Effect function - performs I/O
effect fn greet(name: string) -> void {
    std.io.println("Hello, " + name + "!")
}

// Effect function with IO type
effect fn read_input() -> IO[string] {
    return std.io.read_line()
}
```

### Effect Rules

1. **Pure functions cannot call effect functions**
2. **Effect functions can call both pure and effect functions**
3. **The main function is always an effect function**

```kira
// This is a compile error:
fn bad_function() -> i32 {
    std.io.println("Hello")  // ERROR: pure function cannot perform I/O
    return 42
}

// This is correct:
effect fn good_function() -> void {
    let x: i32 = add(1, 2)      // OK: calling pure function
    std.io.println("Sum: " + to_string(x))  // OK: we're an effect function
}
```

### The Main Function

The entry point is always an effect function:

```kira
effect fn main() -> void {
    // Pure computation
    let result: i32 = factorial(5)

    // Effectful I/O
    std.io.println("5! = " + to_string(result))
}
```

---

## Higher-Order Functions

Functions are first-class values in Kira. You can pass them as arguments and return them from other functions.

### Passing Functions as Arguments

```kira
fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

let double: fn(i32) -> i32 = fn(x: i32) -> i32 { return x * 2 }
let result: i32 = apply(double, 5)  // 10
```

### Returning Functions

```kira
fn make_adder(n: i32) -> fn(i32) -> i32 {
    return fn(x: i32) -> i32 { return x + n }
}

let add_five: fn(i32) -> i32 = make_adder(5)
let result: i32 = add_five(10)  // 15
```

### Common Higher-Order Functions

```kira
// Map: transform each element
let numbers: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let doubled: List[i32] = std.list.map[i32, i32](
    numbers,
    fn(x: i32) -> i32 { return x * 2 }
)
// [2, 4, 6]

// Filter: keep elements matching a predicate
let evens: List[i32] = std.list.filter[i32](
    numbers,
    fn(x: i32) -> bool { return x % 2 == 0 }
)
// [2]

// Fold: reduce to a single value
let sum: i32 = std.list.fold[i32, i32](
    numbers,
    0,
    fn(acc: i32, x: i32) -> i32 { return acc + x }
)
// 6
```

---

## Working with Lists

The `List[T]` type is a fundamental data structure in Kira.

### Creating Lists

```kira
// Empty list
let empty: List[i32] = Nil

// Single element
let single: List[i32] = Cons(42, Nil)

// Multiple elements (constructed right-to-left)
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))

// Using standard library
let empty2: List[i32] = std.list.empty[i32]()
let single2: List[i32] = std.list.singleton[i32](42)
```

### List Operations

```kira
import std.list

// Length
let len: i32 = list.length[i32](nums)  // 3

// Reverse
let rev: List[i32] = list.reverse[i32](nums)  // [3, 2, 1]

// Concatenate
let combined: List[i32] = list.concat[i32](nums, rev)

// Take first n elements
let first_two: List[i32] = list.take[i32](nums, 2)  // [1, 2]

// Drop first n elements
let rest: List[i32] = list.drop[i32](nums, 2)  // [3]

// Find element matching predicate
let found: Option[i32] = list.find[i32](
    nums,
    fn(x: i32) -> bool { return x > 1 }
)  // Some(2)

// Check if any/all elements match
let has_even: bool = list.any[i32](nums, fn(x: i32) -> bool { return x % 2 == 0 })
let all_positive: bool = list.all[i32](nums, fn(x: i32) -> bool { return x > 0 })
```

---

## Error Handling

Kira uses the `Result[T, E]` type for error handling instead of exceptions.

### The Result Type

```kira
type Result[T, E] =
    | Ok(T)
    | Err(E)
```

### Working with Results

```kira
fn divide(a: i32, b: i32) -> Result[i32, string] {
    if b == 0 {
        return Err("Division by zero")
    }
    return Ok(a / b)
}

effect fn main() -> void {
    let result: Result[i32, string] = divide(10, 2)
    match result {
        Ok(n) => { std.io.println("Result: " + to_string(n)) }
        Err(e) => { std.io.println("Error: " + e) }
    }
}
```

### The Try Operator

In effect functions, use `?` to propagate errors:

```kira
effect fn process() -> Result[i32, string] {
    let a: i32 = divide(10, 2)?   // Propagates Err if division fails
    let b: i32 = divide(a, 2)?    // Propagates Err if this fails
    return Ok(b)
}
```

### The Option Type

For values that may not exist:

```kira
fn find_user(id: i64) -> Option[User] {
    // Return Some(user) if found, None otherwise
}

effect fn main() -> void {
    let user: Option[User] = find_user(42)
    match user {
        Some(u) => { std.io.println("Found: " + u.name) }
        None => { std.io.println("User not found") }
    }
}
```

### Null Coalesce Operator

Use `??` to provide a default value:

```kira
let value: i32 = maybe_value ?? 0  // Use 0 if maybe_value is None
```

---

## Modules and Imports

### Declaring a Module

Each file can declare what module it belongs to:

```kira
// src/math/vector.ki
module math.vector

pub type Vec2 = {
    x: f64,
    y: f64
}

pub fn add(a: Vec2, b: Vec2) -> Vec2 {
    return Vec2 { x: a.x + b.x, y: a.y + b.y }
}

// Private function (no pub keyword)
fn helper(x: f64) -> f64 {
    return x * x
}
```

### Importing

```kira
// Import entire module
import std.list

// Import specific items
import std.list.{ map, filter, fold }

// Import with alias
import math.vector.{ Vec2, add as vec_add }
```

### Visibility

- `pub` makes an item public (accessible from other modules)
- Without `pub`, items are private to the module

```kira
pub type PublicType = { ... }   // Accessible everywhere
type PrivateType = { ... }       // Only in this module

pub fn public_function() -> void { ... }
fn private_function() -> void { ... }
```

---

## Complete Example: Word Counter

Here's a complete program that counts words in a file:

```kira
// word_count.ki
module word_count

import std.list.{ map, filter, fold }
import std.string.{ split, trim, length }
import std.io.{ println }
import std.fs.{ read_file }

type WordCount = {
    word: string,
    count: i32
}

// Pure function - processes text
fn count_words(text: string) -> i32 {
    let words: List[string] = split(text, " ")
    let trimmed: List[string] = map[string, string](
        words,
        fn(w: string) -> string { return trim(w) }
    )
    let non_empty: List[string] = filter[string](
        trimmed,
        fn(w: string) -> bool { return length(w) > 0 }
    )
    return std.list.length[string](non_empty)
}

// Effect function - entry point
effect fn main() -> void {
    match read_file("input.txt") {
        Ok(content) => {
            let count: i32 = count_words(content)
            println("Word count: " + to_string(count))
        }
        Err(e) => {
            println("Error reading file: " + e)
        }
    }
}
```

---

## More Standard Library Features

Kira's standard library includes several additional modules beyond what we've covered:

### String Builder

For efficient string concatenation when building large strings:

```kira
effect fn build_greeting(names: List[string]) -> string {
    var b: StringBuilder = std.builder.new()
    b = std.builder.append(b, "Hello to: ")

    for name in names {
        b = std.builder.append(b, name)
        b = std.builder.append(b, ", ")
    }

    return std.builder.build(b)
}
```

### Hash Maps

For key-value storage with O(1) lookups:

```kira
fn count_words(words: List[string]) -> HashMap {
    var counts: HashMap = std.map.new()

    for word in words {
        let current: i32 = std.map.get(counts, word) ?? 0
        counts = std.map.put(counts, word, current + 1)
    }

    return counts
}
```

### Character Operations

For working with individual characters:

```kira
fn is_vowel(c: char) -> bool {
    let code: i32 = std.char.to_i32(c)
    // Check for a, e, i, o, u (lowercase)
    return code == 97 or code == 101 or code == 105 or code == 111 or code == 117
}

fn process_chars(s: string) -> List[char] {
    return std.string.chars(s)
}
```

### Time Operations

For timing and delays:

```kira
effect fn timed_operation() -> void {
    let start: i64 = std.time.now()

    // Do some work...
    std.time.sleep(100)  // Sleep 100ms

    let elapsed: i64 = std.time.elapsed(start, std.time.now())
    std.io.println("Operation took " + to_string(elapsed) + "ms")
}
```

---

## Next Steps

Now that you've learned the basics of Kira, you can:

1. **Explore the Standard Library** - See [stdlib.md](stdlib.md) for all available functions
2. **Read the Language Reference** - See [reference.md](reference.md) for complete syntax details
3. **Use the Quick Reference** - Keep [quickref.md](quickref.md) handy while coding
4. **Read Example Programs** - Check the `examples/` directory
5. **Build Something!** - The best way to learn is by doing

Happy coding with Kira!
