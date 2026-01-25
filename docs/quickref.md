# Kira Quick Reference

A concise cheat sheet for the Kira programming language.

---

## Program Structure

```kira
// Every program needs a main function
effect fn main() -> void {
    std.io.println("Hello, World!")
}
```

---

## Variables

```kira
let x: i32 = 42          // Immutable
var y: i32 = 0           // Mutable
y = 10                   // Reassignment
```

---

## Types

### Primitives

| Type | Example |
|------|---------|
| `i32` | `42`, `-17` |
| `i64` | `1000000i64` |
| `f64` | `3.14`, `2.5e-3` |
| `bool` | `true`, `false` |
| `char` | `'A'`, `'🎉'` |
| `string` | `"hello"` |
| `void` | (no value) |

### Composite

```kira
(i32, string)          // Tuple
[i32; 5]               // Array
fn(i32) -> i32         // Function
List[i32]              // Generic list
Option[string]         // Optional value
Result[i32, string]    // Success or error
```

---

## Functions

```kira
// Pure function
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// Effect function (can do I/O)
effect fn greet(name: string) -> void {
    std.io.println("Hello, " + name)
}

// Generic function
fn identity[T](x: T) -> T {
    return x
}

// Function as value
let double: fn(i32) -> i32 = fn(x: i32) -> i32 {
    return x * 2
}
```

---

## Control Flow

### If/Else

```kira
if condition {
    // then
} else if other {
    // else if
} else {
    // else
}
```

### Match

```kira
match value {
    0 => { /* zero */ }
    n if n > 0 => { /* positive */ }
    _ => { /* other */ }
}
```

### Loops

```kira
// For loop
for item in list {
    std.io.println(to_string(item))
}

// While loop
while condition {
    // body
}

// Infinite loop
loop {
    if done { break }
}
```

---

## Type Definitions

### Sum Types (Enums)

```kira
type Color = Red | Green | Blue

type Shape =
    | Circle(f64)
    | Rectangle(f64, f64)

type Option[T] =
    | Some(T)
    | None
```

### Record Types (Structs)

```kira
type Point = {
    x: f64,
    y: f64
}

let p: Point = Point { x: 3.0, y: 4.0 }
let x_coord: f64 = p.x
```

---

## Pattern Matching

```kira
// Destructuring
let (a, b): (i32, i32) = (1, 2)
let Point { x: px, y: py }: Point = point

// Match patterns
match opt {
    Some(x) => { /* use x */ }
    None => { /* handle empty */ }
}

// Guards
match n {
    x if x < 0 => { /* negative */ }
    x if x > 0 => { /* positive */ }
    _ => { /* zero */ }
}

// Or patterns
match color {
    Red | Green | Blue => { /* primary */ }
}
```

---

## Option and Result

### Option[T]

```kira
let some_val: Option[i32] = Some(42)
let no_val: Option[i32] = None

// Handle with match
match some_val {
    Some(n) => { /* use n */ }
    None => { /* handle empty */ }
}

// Or use ?? for default
let val: i32 = some_val ?? 0
```

### Result[T, E]

```kira
let success: Result[i32, string] = Ok(42)
let failure: Result[i32, string] = Err("error")

// Handle with match
match result {
    Ok(value) => { /* use value */ }
    Err(e) => { /* handle error */ }
}

// Propagate with ? (in effect functions)
effect fn process() -> Result[i32, string] {
    let x: i32 = risky_op()?  // Propagates Err
    return Ok(x * 2)
}
```

---

## Lists

```kira
// Create
let empty: List[i32] = Nil
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))

// Using stdlib
let nums2: List[i32] = std.list.cons(1, std.list.cons(2, std.list.empty()))

// Operations
let len: i32 = std.list.length(nums)
let doubled: List[i32] = std.list.map(nums, fn(x: i32) -> i32 { return x * 2 })
let evens: List[i32] = std.list.filter(nums, fn(x: i32) -> bool { return x % 2 == 0 })
let sum: i32 = std.list.fold(nums, 0, fn(acc: i32, x: i32) -> i32 { return acc + x })
```

---

## Common Standard Library

### I/O (effect functions)

```kira
std.io.print("no newline")
std.io.println("with newline")
let line: Result[string, string] = std.io.read_line()
```

### Strings

```kira
std.string.length("hello")              // 5
std.string.split("a,b,c", ",")          // List["a", "b", "c"]
std.string.trim("  hi  ")               // "hi"
std.string.contains("hello", "ell")     // true
std.string.to_upper("hello")            // "HELLO"
std.string.replace("hello", "l", "L")   // "heLLo"
std.string.chars("abc")                 // List['a', 'b', 'c']
```

### File System (effect functions)

```kira
let content: Result[string, string] = std.fs.read_file("file.txt")
let result: Result[void, string] = std.fs.write_file("out.txt", "data")
let exists: bool = std.fs.exists("file.txt")
```

### Maps

```kira
let m: HashMap = std.map.new()
let m2: HashMap = std.map.put(m, "key", "value")
let val: Option[string] = std.map.get(m2, "key")
let has: bool = std.map.contains(m2, "key")
```

### Time (effect functions)

```kira
let now: i64 = std.time.now()
std.time.sleep(1000)  // 1 second
```

---

## Built-in Functions

```kira
to_string(42)        // "42"
to_int(3.14)         // 3
to_float(42)         // 42.0
type_of(x)           // Type name as string
abs(-5)              // 5
min(3, 7)            // 3
max(3, 7)            // 7
len(collection)      // Length
assert(condition)    // Panic if false
assert_eq(a, b)      // Panic if not equal
```

---

## Operators

| Category | Operators |
|----------|-----------|
| Arithmetic | `+` `-` `*` `/` `%` |
| Comparison | `==` `!=` `<` `<=` `>` `>=` |
| Logical | `and` `or` `not` |
| Other | `+` (string concat), `??` (coalesce), `?` (try) |

---

## Modules

```kira
// Declare module
module my.package

// Import
import std.list
import std.list.{ map, filter }
import std.list.{ map as list_map }

// Export
pub fn public_function() -> void { }
pub type PublicType = { ... }
```

---

## Effects Summary

| Pure Function | Effect Function |
|---------------|-----------------|
| `fn name() -> T` | `effect fn name() -> T` |
| No side effects | Can do I/O, time, etc. |
| Same input = same output | May vary |
| Cannot call effect functions | Can call any function |

---

## Common Patterns

### Error Handling

```kira
effect fn read_number(path: string) -> Result[i32, string] {
    let content: string = std.fs.read_file(path)?
    match std.string.parse_int(content) {
        Some(n) => { return Ok(n) }
        None => { return Err("Invalid number") }
    }
}
```

### Processing Lists

```kira
fn sum_positives(nums: List[i32]) -> i32 {
    let positives: List[i32] = std.list.filter(nums,
        fn(x: i32) -> bool { return x > 0 })
    return std.list.fold(positives, 0,
        fn(acc: i32, x: i32) -> i32 { return acc + x })
}
```

### Building Strings

```kira
let b: StringBuilder = std.builder.new()
let b2: StringBuilder = std.builder.append(b, "Hello, ")
let b3: StringBuilder = std.builder.append(b2, name)
let b4: StringBuilder = std.builder.append(b3, "!")
let result: string = std.builder.build(b4)
```

### Working with Options

```kira
fn get_or_compute(cache: HashMap, key: string) -> i32 {
    match std.map.get(cache, key) {
        Some(val) => { return val }
        None => { return expensive_compute(key) }
    }
}

// Or simply:
let val: i32 = std.map.get(cache, key) ?? expensive_compute(key)
```
