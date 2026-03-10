# Kira Programming Language Specification

> **"Pure clarity."**

Kira is a functional programming language designed for AI code generation. It applies Klar's "no ambiguity, no surprises" philosophy to the functional paradigm.

---

## Table of Contents

1. [Lexical Elements](#lexical-elements)
2. [Syntax and Grammar](#syntax-and-grammar)
3. [Type System](#type-system)
4. [Effects System](#effects-system)
5. [Pattern Matching](#pattern-matching)
6. [Higher-Order Functions](#higher-order-functions)
7. [Standard Library](#standard-library)
8. [Module System](#module-system)
9. [Implementation Notes](#implementation-notes)

See [IDEA.md](IDEA.md) for the concept and motivation behind Kira, and [PHILOSOPHY.md](PHILOSOPHY.md) for the principles that guide its design.

---

## Lexical Elements

### File Extension

`.ki`

### Keywords

```
// Declarations
fn       let      type     module   import   pub
effect   trait    impl     const    shadow
test     bench    memo     var

// Control flow
if       else     match    for      return   break
while    loop

// Expressions
true     false    self     Self

// Operators (word-form)
and      or       not      is       in       as

// Special
where
```

### Operators

```
// Arithmetic
+   -   *   /   %

// Comparison
==  !=  <   >   <=  >=

// Logical
and  or  not

// Special
?       ??      ..      ..=
->      =>      :       ::
|
```

### Literals

```kira
// Integers
42                  // i32 default
42_000              // underscores allowed
0xff                // hex
0b1010              // binary
42i64               // explicit type suffix

// Floats
3.14                // f64 default
3.14f32             // explicit type

// Strings
"hello"             // regular string
"line 1\nline 2"    // escape sequences

// Boolean
true
false
```

### Comments

```kira
// Line comment

/* Block comment */

/// Documentation comment (for next item)
/// Supports **markdown**

//! Module-level documentation
```

---

## Syntax and Grammar

### Basic Syntax Rules

- **No semicolons** — newline-terminated
- **4-space indentation** (convention)
- **Explicit types on all bindings**
- **Explicit return statements**
- **Statement-based control flow**

### Bindings

All bindings require explicit type annotations.

```kira
// Immutable binding (the only kind in pure Kira)
let x: i32 = 42
let name: string = "Alice"
let items: List[i32] = List.empty()
```

### Mutable Bindings (`var`)

Use `var` for local mutable bindings within function bodies. `var` cannot appear at
the module level — top-level bindings are always immutable (`let` or `const`).

```kira
var count: i32 = 0          // initialized
var result: string          // uninitialized (must assign before use)
count = count + 1           // reassignment
```

`var` takes a simple identifier (no destructuring patterns, unlike `let`). Local
rebinding with `var` is allowed in both pure and effect functions — only field/index
mutation and I/O require `effect`.

### Constants

Use `const` for top-level, compile-time known values. Constants require explicit type
annotations and an initializer.

```kira
const PI: f64 = 3.14159265358979
const MAX_RETRIES: i32 = 3
pub const VERSION: string = "1.0.0"
```

**`const` vs `let`:**

| | `const` | `let` |
|---|---|---|
| Scope | Top-level only | Top-level or local |
| Generics | No | Yes (`let identity[T]: ...`) |
| Mutability | Immutable | Immutable |
| Initializer | Required | Required |
| `pub` | Yes | Yes |

Use `const` for simple named values (numbers, strings). Use `let` for function bindings
and generic definitions.

### Explicit Shadowing

Kira does **not** allow implicit variable shadowing. If a binding in an inner scope
would shadow a name from an outer scope, the compiler rejects it:

```kira
let x: i32 = 10
if true {
    let x: i32 = 20    // ERROR: shadowing 'x' requires 'shadow' binding
}
```

To shadow intentionally, use the `shadow` keyword as a prefix:

```kira
let x: i32 = 10
if true {
    shadow let x: i32 = 20    // OK: explicitly opted in to shadowing
}
```

`shadow` works with both `let` and `var` bindings:

```kira
let name: string = "Alice"
shadow let name: string = "Bob"      // OK

var count: i32 = 0
shadow var count: i32 = 100          // OK
```

Shadowing within the same scope (re-declaration) is always an error, even with `shadow`.
The `shadow` keyword only permits shadowing names from **outer** scopes.

### Test and Bench Declarations

Tests and benchmarks are top-level declarations with a string name and a block body.
They cannot be `pub`.

```kira
test "addition works" {
    std.assert.assert_eq(5, add(2, 3))
    std.assert.assert_eq(0, add(-1, 1))
}

bench "fibonacci 20" {
    fibonacci(20)
}
```

Test and bench bodies are implicitly treated as effect functions — they can call
effectful code (assertions, IO) without an `effect` annotation.

Run tests and benchmarks from the CLI:

```
kira test file.ki               // run tests
kira test --coverage file.ki    // run tests with coverage
kira bench file.ki              // run benchmarks
kira bench --iterations 1000 file.ki
```

### Functions

Functions are values with explicit signatures. All functions use explicit `return`.

```kira
// Function binding with full type annotation
let add: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 {
    return a + b
}

// Multi-line function
let factorial: fn(i32) -> i32 = fn(n: i32) -> i32 {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}

// Function that returns nothing
let greet: fn(string) -> void = fn(name: string) -> void {
    // This would be an effect function in practice
    return
}
```

### Memoized Functions

The `memo` modifier caches function results by argument values. Memoized functions
must be pure — combining `memo` with `effect` is a compile error.

```kira
memo fn fibonacci(n: i32) -> i32 {
    if n <= 1 {
        return n
    }
    return fibonacci(n - 1) + fibonacci(n - 2)
}
```

Memoized functions cannot be generic (different type instantiations would alias
cache entries).

```kira
memo effect fn bad() -> IO[void] { }  // ERROR: memo + effect cannot be combined
memo fn bad2[T](x: T) -> T { }        // ERROR: memo functions cannot be generic
```

### Algebraic Data Types

```kira
// Sum types (tagged unions)
type Option[T] =
    | Some(T)
    | None

type Result[T, E] =
    | Ok(T)
    | Err(E)

type List[T] =
    | Cons(T, List[T])
    | Nil

// Product types (records)
type Point = {
    x: f64,
    y: f64
}

type User = {
    id: i64,
    name: string,
    email: string
}

// Creating values
let origin: Point = Point { x: 0.0, y: 0.0 }
let maybe: Option[i32] = Some(42)
let empty: Option[i32] = None
let user: User = User { id: 1, name: "Alice", email: "alice@example.com" }
```

### Control Flow

Control flow constructs are statements, not expressions.

```kira
// If statement
let max: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 {
    if a > b {
        return a
    }
    return b
}

// If-else statement
let sign: fn(i32) -> string = fn(n: i32) -> string {
    var result: string
    if n > 0 {
        result = "positive"
    } else if n < 0 {
        result = "negative"
    } else {
        result = "zero"
    }
    return result
}

// For loop (over iterables)
let sum_list: fn(List[i32]) -> i32 = fn(items: List[i32]) -> i32 {
    var total: i32 = 0
    for item in items {
        total = total + item
    }
    return total
}

// While loop (condition checked each iteration)
var i: i32 = 0
while i < 10 {
    std.io.println(std.int.to_string(i))
    i = i + 1
}

// Infinite loop (exit with break or return)
loop {
    let input: string = read_line()
    if input == "quit" {
        break
    }
}
```

Use `for` to iterate over collections, `while` when you have a boolean condition,
and `loop` for infinite loops that exit via `break` or `return`.

### Closures

Closures follow the same rules as functions: explicit parameter types, explicit return types, and explicit `return` statements.

```kira
// Closure with full type annotations
let double: fn(i32) -> i32 = fn(x: i32) -> i32 { return x * 2 }

// Multi-line closure
let process: fn(i32) -> i32 = fn(x: i32) -> i32 {
    let y: i32 = x * 2
    return y + 1
}

// Closure capturing environment
let make_adder: fn(i32) -> fn(i32) -> i32 = fn(n: i32) -> fn(i32) -> i32 {
    return fn(x: i32) -> i32 { return x + n }
}

let add_five: fn(i32) -> i32 = make_adder(5)
let result: i32 = add_five(10)  // 15
```

---

## Type System

### Primitive Types

```kira
// Integers
i8, i16, i32, i64, i128    // signed
u8, u16, u32, u64, u128    // unsigned

// Floats
f32, f64

// Other
bool
char                        // Unicode scalar value
string                      // UTF-8 string
void                        // No value
```

### Composite Types

```kira
// Tuples
let pair: (i32, string) = (42, "hello")
let first: i32 = pair.0
let second: string = pair.1

// Arrays (fixed size)
let arr: [i32; 5] = [1, 2, 3, 4, 5]

// Function types
let f: fn(i32, i32) -> i32 = add
```

### Generic Types

```kira
// Generic type definition
type Pair[A, B] = {
    first: A,
    second: B
}

// Using generic types
let p: Pair[i32, string] = Pair { first: 42, second: "hello" }

// Generic functions
let identity[T]: fn(T) -> T = fn(x: T) -> T {
    return x
}

let n: i32 = identity[i32](42)
let s: string = identity[string]("hello")
```

### No Implicit Conversions

```kira
let x: i32 = 5
let y: i64 = x              // ERROR: type mismatch

let y: i64 = x.as[i64]      // OK: explicit conversion
```

### Null Coalesce Operator (`??`)

The `??` operator unwraps an `Option[T]`, returning the inner value if `Some` or a
default value if `None`:

```kira
let name: Option[string] = get_name()
let display: string = name ?? "anonymous"
```

The left operand must be `Option[T]` and the right operand must be type `T`. The
result type is `T`. The default expression is only evaluated if the left is `None`.

```kira
let a: Option[i32] = Some(42)
let b: i32 = a ?? 0          // 42

let c: Option[i32] = None
let d: i32 = c ?? 0          // 0
```

`??` works only with `Option` types, not `Result`. For `Result`, use `match` or `?`.

---

## Effects System

Effects are explicit in types. No function can perform effects unless declared with `effect`.

### Pure Functions (Default)

```kira
// Pure functions cannot perform IO, mutation, or other effects
// The compiler verifies this

let add: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 {
    return a + b
}

let factorial: fn(i32) -> i32 = fn(n: i32) -> i32 {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}

// This would be a compile error - pure function cannot do IO:
// let bad: fn(i32) -> i32 = fn(x: i32) -> i32 {
//     io.println("hello")  // ERROR: pure function cannot perform IO
//     return x
// }
```

### Effect Functions

```kira
// Effect functions can perform side effects
// The effect is visible in the return type

// IO effect - can read/write to world
effect fn print_line(msg: string) -> IO[void] {
    return io.println(msg)
}

// Functions that can fail
effect fn parse_int(s: string) -> Result[i32, ParseError] {
    // ... parsing logic
}

// IO + failure
effect fn read_file(path: string) -> IO[Result[string, IoError]] {
    return fs.read_string(path)
}

// Combining effects
effect fn fetch_user(id: i64) -> IO[Result[User, ApiError]] {
    let response: Result[Response, HttpError] = http.get("/users/${id}").await
    match response {
        Ok(r) => {
            let user: Result[User, JsonError] = r.json[User]()
            match user {
                Ok(u) => { return Ok(u) }
                Err(e) => { return Err(ApiError.Json(e)) }
            }
        }
        Err(e) => { return Err(ApiError.Http(e)) }
    }
}
```

### Effect Propagation

```kira
// Pure code cannot call effectful code
// This is a compile error:
let bad: fn(i32) -> i32 = fn(x: i32) -> i32 {
    print_line("hello")  // ERROR: pure function cannot call effect function
    return x
}

// Effectful code can call both pure and effectful code
effect fn process(x: i32) -> IO[i32] {
    let doubled: i32 = x * 2        // OK: calling pure computation
    print_line("processing ${x}")     // OK: IO in IO context
    return doubled
}

// The ? operator propagates errors in effect functions
effect fn process_file() -> IO[Result[Data, Error]] {
    let content: string = read_file("data.txt")?   // Propagates IoError
    let data: Data = parse(content)?               // Propagates ParseError
    return Ok(data)
}
```

### Main Function

The main function is always an effect function.

```kira
effect fn main() -> IO[void] {
    let result: i32 = factorial(5)      // OK: calling pure from effect
    print_line("Result: ${result}")       // OK: IO in IO context
    return
}

// Main with error handling
effect fn main() -> IO[Result[void, Error]] {
    let data: Data = load_config()?
    run_application(data)?
    return Ok(())
}
```

---

## Pattern Matching

### Match Statement

Match is a statement that assigns to a variable. All cases must be handled.

```kira
let describe_option: fn(Option[i32]) -> string = fn(opt: Option[i32]) -> string {
    var result: string
    match opt {
        Some(n) => { result = "has value: ${n}" }
        None => { result = "empty" }
    }
    return result
}

let describe_result: fn(Result[i32, string]) -> string =
    fn(res: Result[i32, string]) -> string {
        var result: string
        match res {
            Ok(n) => { result = "success: ${n}" }
            Err(e) => { result = "error: ${e}" }
        }
        return result
    }
```

### Pattern Types

```kira
// Literal patterns
match value {
    0 => { result = "zero" }
    1 => { result = "one" }
    _ => { result = "other" }
}

// Constructor patterns
match option {
    Some(x) => { result = x }
    None => { result = 0 }
}

// Record patterns
match point {
    Point { x: 0, y: 0 } => { result = "origin" }
    Point { x: 0, y: y } => { result = "on y-axis at ${y}" }
    Point { x: x, y: 0 } => { result = "on x-axis at ${x}" }
    Point { x: x, y: y } => { result = "at (${x}, ${y})" }
}

// Tuple patterns
match pair {
    (0, 0) => { result = "origin" }
    (x, 0) => { result = "x = ${x}" }
    (0, y) => { result = "y = ${y}" }
    (x, y) => { result = "(${x}, ${y})" }
}

// Or patterns
match value {
    1 | 2 | 3 => { result = "small" }
    _ => { result = "other" }
}

// Guard patterns
match value {
    n if n < 0 => { result = "negative" }
    n if n > 100 => { result = "large" }
    n => { result = "normal: ${n}" }
}

// Range patterns (integers and chars)
match code {
    0..10 => { result = "single digit" }      // exclusive end
    10..=99 => { result = "two digits" }       // inclusive end
    _ => { result = "large" }
}

match ch {
    'a'..='z' => { result = "lowercase" }
    'A'..='Z' => { result = "uppercase" }
    '0'..='9' => { result = "digit" }
    _ => { result = "other" }
}

// Rest pattern in records (ignore unmatched fields)
match user {
    User { name: n, .. } => { result = n }     // ignores other fields
}
```

### Destructuring in Let

```kira
// Destructure records
let p: Point = Point { x: 3.0, y: 4.0 }
let Point { x: px, y: py }: Point = p

// Destructure tuples
let pair: (i32, string) = (42, "hello")
let (n, s): (i32, string) = pair
```

---

## Higher-Order Functions

### Functions as Values

```kira
// Functions are first-class values
let add: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 {
    return a + b
}

let subtract: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 {
    return a - b
}

// Passing functions as arguments
let apply: fn(fn(i32, i32) -> i32, i32, i32) -> i32 =
    fn(f: fn(i32, i32) -> i32, a: i32, b: i32) -> i32 {
        return f(a, b)
    }

let sum: i32 = apply(add, 5, 3)        // 8
let diff: i32 = apply(subtract, 5, 3)  // 2
```

### Map, Filter, Fold

```kira
// Map over a list
let map[A, B]: fn(List[A], fn(A) -> B) -> List[B] =
    fn(list: List[A], f: fn(A) -> B) -> List[B] {
        match list {
            Nil => { return Nil }
            Cons(head, tail) => {
                let new_head: B = f(head)
                let new_tail: List[B] = map[A, B](tail, f)
                return Cons(new_head, new_tail)
            }
        }
    }

// Filter a list
let filter[A]: fn(List[A], fn(A) -> bool) -> List[A] =
    fn(list: List[A], pred: fn(A) -> bool) -> List[A] {
        match list {
            Nil => { return Nil }
            Cons(head, tail) => {
                let rest: List[A] = filter[A](tail, pred)
                if pred(head) {
                    return Cons(head, rest)
                }
                return rest
            }
        }
    }

// Fold a list
let fold[A, B]: fn(List[A], B, fn(B, A) -> B) -> B =
    fn(list: List[A], init: B, f: fn(B, A) -> B) -> B {
        match list {
            Nil => { return init }
            Cons(head, tail) => {
                let acc: B = f(init, head)
                return fold[A, B](tail, acc, f)
            }
        }
    }
```

### Using Higher-Order Functions

```kira
let numbers: List[i32] = Cons(1, Cons(2, Cons(3, Cons(4, Cons(5, Nil)))))

// Double all numbers
let doubled: List[i32] = map[i32, i32](
    numbers,
    fn(x: i32) -> i32 { return x * 2 }
)

// Keep only even numbers
let evens: List[i32] = filter[i32](
    numbers,
    fn(x: i32) -> bool { return x % 2 == 0 }
)

// Sum all numbers
let total: i32 = fold[i32, i32](
    numbers,
    0,
    fn(acc: i32, x: i32) -> i32 { return acc + x }
)
```

### Composition (Explicit)

```kira
// No implicit composition operators
// Composition is explicit

let compose[A, B, C]: fn(fn(B) -> C, fn(A) -> B) -> fn(A) -> C =
    fn(f: fn(B) -> C, g: fn(A) -> B) -> fn(A) -> C {
        return fn(x: A) -> C {
            let intermediate: B = g(x)
            return f(intermediate)
        }
    }

// Usage
let add_one: fn(i32) -> i32 = fn(x: i32) -> i32 { return x + 1 }
let double: fn(i32) -> i32 = fn(x: i32) -> i32 { return x * 2 }

let add_then_double: fn(i32) -> i32 = compose[i32, i32, i32](double, add_one)
let result: i32 = add_then_double(5)  // (5 + 1) * 2 = 12

// Or just call directly (often clearer for AI)
let result2: i32 = double(add_one(5))
```

---

## Standard Library

### Core Types (Auto-imported)

```kira
// Primitive types
bool, i8, i16, i32, i64, i128
u8, u16, u32, u64, u128
f32, f64
char, string, void

// Core types
type Option[T] = Some(T) | None
type Result[T, E] = Ok(T) | Err(E)
type List[T] = Cons(T, List[T]) | Nil

// Core traits
trait Eq {
    fn eq(self: Self, other: Self) -> bool
}

trait Ord: Eq {
    fn compare(self: Self, other: Self) -> Ordering
}

// Multiple supertraits use `+` separator
trait Printable: Show + Eq {
    fn display(self: Self) -> string
}

trait Show {
    fn show(self: Self) -> string
}
```

### std.list

```kira
module std.list

pub let empty[A]: fn() -> List[A]
pub let singleton[A]: fn(A) -> List[A]
pub let cons[A]: fn(A, List[A]) -> List[A]

pub let map[A, B]: fn(List[A], fn(A) -> B) -> List[B]
pub let filter[A]: fn(List[A], fn(A) -> bool) -> List[A]
pub let fold[A, B]: fn(List[A], B, fn(B, A) -> B) -> B
pub let fold_right[A, B]: fn(List[A], B, fn(A, B) -> B) -> B

pub let find[A]: fn(List[A], fn(A) -> bool) -> Option[A]
pub let any[A]: fn(List[A], fn(A) -> bool) -> bool
pub let all[A]: fn(List[A], fn(A) -> bool) -> bool

pub let length[A]: fn(List[A]) -> i32
pub let reverse[A]: fn(List[A]) -> List[A]
pub let concat[A]: fn(List[A], List[A]) -> List[A]
pub let flatten[A]: fn(List[List[A]]) -> List[A]

pub let take[A]: fn(List[A], i32) -> List[A]
pub let drop[A]: fn(List[A], i32) -> List[A]
pub let zip[A, B]: fn(List[A], List[B]) -> List[(A, B)]
```

### std.option

```kira
module std.option

pub let map[A, B]: fn(Option[A], fn(A) -> B) -> Option[B]
pub let and_then[A, B]: fn(Option[A], fn(A) -> Option[B]) -> Option[B]
pub let unwrap_or[A]: fn(Option[A], A) -> A
pub let is_some[A]: fn(Option[A]) -> bool
pub let is_none[A]: fn(Option[A]) -> bool
```

### std.result

```kira
module std.result

pub let map[T, E, U]: fn(Result[T, E], fn(T) -> U) -> Result[U, E]
pub let map_err[T, E, F]: fn(Result[T, E], fn(E) -> F) -> Result[T, F]
pub let and_then[T, E, U]: fn(Result[T, E], fn(T) -> Result[U, E]) -> Result[U, E]
pub let unwrap_or[T, E]: fn(Result[T, E], T) -> T
pub let is_ok[T, E]: fn(Result[T, E]) -> bool
pub let is_err[T, E]: fn(Result[T, E]) -> bool
```

### std.io (Effect Module)

```kira
module std.io

pub effect fn print(msg: string) -> IO[void]
pub effect fn println(msg: string) -> IO[void]
pub effect fn read_line() -> IO[string]
```

### std.fs (Effect Module)

```kira
module std.fs

pub effect fn read_file(path: string) -> IO[Result[string, IoError]]
pub effect fn write_file(path: string, content: string) -> IO[Result[void, IoError]]
pub effect fn exists(path: string) -> IO[bool]
pub effect fn remove(path: string) -> IO[Result[void, IoError]]
```

---

## Module System

### Module Declaration

```kira
// src/math/vector.ki
module math.vector

pub type Vec2 = {
    x: f64,
    y: f64
}

pub let add: fn(Vec2, Vec2) -> Vec2 = fn(a: Vec2, b: Vec2) -> Vec2 {
    return Vec2 { x: a.x + b.x, y: a.y + b.y }
}

pub let scale: fn(Vec2, f64) -> Vec2 = fn(v: Vec2, s: f64) -> Vec2 {
    return Vec2 { x: v.x * s, y: v.y * s }
}

// Private function (no pub)
let helper: fn(f64) -> f64 = fn(x: f64) -> f64 {
    return x * x
}
```

### Imports

```kira
import std.list
import std.list.{ map, filter, fold }
import std.option.{ Option, Some, None }
import math.vector.{ Vec2, add as vec_add }
```

### Visibility

```kira
pub type PublicType = { ... }      // Public type
type PrivateType = { ... }          // Private type

pub let public_fn: fn(...) = ...    // Public function
let private_fn: fn(...) = ...       // Private function
```

---

## Complete Example

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

// Pure function - counts words
let count_words: fn(string) -> List[WordCount] = fn(text: string) -> List[WordCount] {
    let words: List[string] = split(text, " ")
    let trimmed: List[string] = map[string, string](
        words,
        fn(w: string) -> string { return trim(w) }
    )
    let non_empty: List[string] = filter[string](
        trimmed,
        fn(w: string) -> bool { return length(w) > 0 }
    )
    // Count logic would go here
    return count_unique(non_empty)
}

// Pure function - formats output
let format_counts: fn(List[WordCount]) -> string = fn(counts: List[WordCount]) -> string {
    let lines: List[string] = map[WordCount, string](
        counts,
        fn(wc: WordCount) -> string {
            return "{wc.word}: {wc.count}"
        }
    )
    return join(lines, "\n")
}

// Effect function - entry point
pub effect fn main() -> IO[Result[void, Error]] {
    let content: string = read_file("input.txt")?

    // Pure computation - AI can reason about this completely
    let counts: List[WordCount] = count_words(content)
    let output: string = format_counts(counts)

    // Effect - clearly marked
    println(output)

    return Ok(())
}
```

---

## Implementation Notes

### Compiler Phases

1. **Parsing** — Build AST (shared infrastructure with Klar)
2. **Type checking** — Verify all types explicit and correct
3. **Effect checking** — Verify purity constraints
4. **Optimization** — Pure functions enable aggressive optimization
5. **Code generation** — Target same backend as Klar

---

*Document version: 1.1*
