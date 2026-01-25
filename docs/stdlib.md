# Kira Standard Library Reference

This document provides complete documentation for all functions in the Kira standard library.

## Table of Contents

1. [Core Types](#core-types)
2. [std.io](#stdio)
3. [std.list](#stdlist)
4. [std.option](#stdoption)
5. [std.result](#stdresult)
6. [std.string](#stdstring)
7. [std.fs](#stdfs)
8. [std.builder](#stdbuilder)
9. [std.map](#stdmap)
10. [std.char](#stdchar)
11. [std.math](#stdmath)
12. [std.time](#stdtime)
13. [std.assert](#stdassert)
14. [Built-in Functions](#built-in-functions)

---

## Core Types

These types are automatically available in every Kira program.

### Primitive Types

| Type | Description | Example |
|------|-------------|---------|
| `i8` | 8-bit signed integer | `-128` to `127` |
| `i16` | 16-bit signed integer | `-32768` to `32767` |
| `i32` | 32-bit signed integer (default) | `42`, `-100` |
| `i64` | 64-bit signed integer | `1000000i64` |
| `i128` | 128-bit signed integer | Very large values |
| `u8` | 8-bit unsigned integer | `0` to `255` |
| `u16` | 16-bit unsigned integer | `0` to `65535` |
| `u32` | 32-bit unsigned integer | `0` to `4294967295` |
| `u64` | 64-bit unsigned integer | Large positive values |
| `u128` | 128-bit unsigned integer | Very large positive values |
| `f32` | 32-bit floating point | `3.14f32` |
| `f64` | 64-bit floating point (default) | `3.14159` |
| `bool` | Boolean | `true`, `false` |
| `char` | Unicode scalar value | `'A'`, `'🎉'` |
| `string` | UTF-8 string | `"hello"` |
| `void` | No value | Used for functions with no return |

### Option[T]

Represents a value that may or may not exist.

```kira
type Option[T] =
    | Some(T)
    | None
```

**Usage:**

```kira
let value: Option[i32] = Some(42)
let empty: Option[i32] = None

match value {
    Some(n) => { /* use n */ }
    None => { /* handle absence */ }
}
```

### Result[T, E]

Represents either success (`Ok`) or failure (`Err`).

```kira
type Result[T, E] =
    | Ok(T)
    | Err(E)
```

**Usage:**

```kira
let success: Result[i32, string] = Ok(42)
let failure: Result[i32, string] = Err("Something went wrong")

match success {
    Ok(n) => { /* use n */ }
    Err(e) => { /* handle error e */ }
}
```

### List[T]

A singly-linked list.

```kira
type List[T] =
    | Cons(T, List[T])
    | Nil
```

**Usage:**

```kira
let empty: List[i32] = Nil
let numbers: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
```

---

## std.io

I/O operations for reading and writing to standard streams.

> **Note:** All functions in `std.io` are effect functions and require an `effect fn` context.

### print

```kira
pub effect fn print(msg: string) -> IO[void]
```

Prints a string to standard output without a trailing newline.

**Example:**

```kira
effect fn main() -> void {
    std.io.print("Hello, ")
    std.io.print("World!")
    // Output: Hello, World!
}
```

### println

```kira
pub effect fn println(msg: string) -> IO[void]
```

Prints a string to standard output with a trailing newline.

**Example:**

```kira
effect fn main() -> void {
    std.io.println("Hello, World!")
    std.io.println("Second line")
}
```

### read_line

```kira
pub effect fn read_line() -> IO[Result[string, string]]
```

Reads a line from standard input. Returns `Ok(string)` with the line content (without trailing newline), or `Err(string)` with an error message.

**Example:**

```kira
effect fn main() -> void {
    std.io.print("Enter your name: ")
    match std.io.read_line() {
        Ok(name) => { std.io.println("Hello, " + name + "!") }
        Err(e) => { std.io.println("Error: " + e) }
    }
}
```

### eprint

```kira
pub effect fn eprint(msg: string) -> IO[void]
```

Prints a string to standard error without a trailing newline.

### eprintln

```kira
pub effect fn eprintln(msg: string) -> IO[void]
```

Prints a string to standard error with a trailing newline.

**Example:**

```kira
effect fn main() -> void {
    std.io.eprintln("Warning: this is an error message")
}
```

---

## std.list

Operations on the `List[T]` type.

### Accessor Functions

#### head

```kira
pub fn head[A](list: List[A]) -> Option[A]
```

Returns the first element of the list, or `None` if empty.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
match std.list.head[i32](nums) {
    Some(first) => { std.io.println("First: " + to_string(first)) }  // 1
    None => { std.io.println("Empty list") }
}
```

#### tail

```kira
pub fn tail[A](list: List[A]) -> Option[List[A]]
```

Returns the list without its first element, or `None` if empty.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
match std.list.tail[i32](nums) {
    Some(rest) => {
        // rest is Cons(2, Cons(3, Nil))
        std.io.println("Tail length: " + to_string(std.list.length[i32](rest)))
    }
    None => { std.io.println("Empty list") }
}
```

### Construction Functions

#### empty

```kira
pub fn empty[A]() -> List[A]
```

Creates an empty list.

**Example:**

```kira
let nums: List[i32] = std.list.empty[i32]()  // Nil
```

#### singleton

```kira
pub fn singleton[A](value: A) -> List[A]
```

Creates a list containing a single element.

**Example:**

```kira
let one: List[i32] = std.list.singleton[i32](42)  // Cons(42, Nil)
```

#### cons

```kira
pub fn cons[A](head: A, tail: List[A]) -> List[A]
```

Prepends an element to a list.

**Example:**

```kira
let nums: List[i32] = std.list.cons[i32](1, std.list.singleton[i32](2))
// Cons(1, Cons(2, Nil))
```

### Transformation Functions

#### map

```kira
pub fn map[A, B](list: List[A], f: fn(A) -> B) -> List[B]
```

Applies a function to each element of a list, returning a new list.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let doubled: List[i32] = std.list.map[i32, i32](
    nums,
    fn(x: i32) -> i32 { return x * 2 }
)
// Cons(2, Cons(4, Cons(6, Nil)))
```

#### filter

```kira
pub fn filter[A](list: List[A], pred: fn(A) -> bool) -> List[A]
```

Returns a new list containing only elements that satisfy the predicate.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Cons(4, Nil))))
let evens: List[i32] = std.list.filter[i32](
    nums,
    fn(x: i32) -> bool { return x % 2 == 0 }
)
// Cons(2, Cons(4, Nil))
```

#### fold

```kira
pub fn fold[A, B](list: List[A], init: B, f: fn(B, A) -> B) -> B
```

Left fold: reduces a list to a single value by applying a function from left to right.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let sum: i32 = std.list.fold[i32, i32](
    nums,
    0,
    fn(acc: i32, x: i32) -> i32 { return acc + x }
)
// 6
```

#### fold_right

```kira
pub fn fold_right[A, B](list: List[A], init: B, f: fn(A, B) -> B) -> B
```

Right fold: reduces a list to a single value by applying a function from right to left.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let result: string = std.list.fold_right[i32, string](
    nums,
    "",
    fn(x: i32, acc: string) -> string { return to_string(x) + acc }
)
// "123"
```

### Query Functions

#### find

```kira
pub fn find[A](list: List[A], pred: fn(A) -> bool) -> Option[A]
```

Returns the first element that satisfies the predicate, or `None` if not found.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let first_even: Option[i32] = std.list.find[i32](
    nums,
    fn(x: i32) -> bool { return x % 2 == 0 }
)
// Some(2)
```

#### any

```kira
pub fn any[A](list: List[A], pred: fn(A) -> bool) -> bool
```

Returns `true` if any element satisfies the predicate.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let has_even: bool = std.list.any[i32](
    nums,
    fn(x: i32) -> bool { return x % 2 == 0 }
)
// true
```

#### all

```kira
pub fn all[A](list: List[A], pred: fn(A) -> bool) -> bool
```

Returns `true` if all elements satisfy the predicate.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let all_positive: bool = std.list.all[i32](
    nums,
    fn(x: i32) -> bool { return x > 0 }
)
// true
```

### Basic Operations

#### length

```kira
pub fn length[A](list: List[A]) -> i32
```

Returns the number of elements in the list.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let len: i32 = std.list.length[i32](nums)  // 3
```

#### reverse

```kira
pub fn reverse[A](list: List[A]) -> List[A]
```

Returns a new list with elements in reverse order.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let rev: List[i32] = std.list.reverse[i32](nums)
// Cons(3, Cons(2, Cons(1, Nil)))
```

#### concat

```kira
pub fn concat[A](list1: List[A], list2: List[A]) -> List[A]
```

Concatenates two lists.

**Example:**

```kira
let a: List[i32] = Cons(1, Cons(2, Nil))
let b: List[i32] = Cons(3, Cons(4, Nil))
let combined: List[i32] = std.list.concat[i32](a, b)
// Cons(1, Cons(2, Cons(3, Cons(4, Nil))))
```

#### flatten

```kira
pub fn flatten[A](lists: List[List[A]]) -> List[A]
```

Flattens a list of lists into a single list.

**Example:**

```kira
let nested: List[List[i32]] = Cons(
    Cons(1, Cons(2, Nil)),
    Cons(Cons(3, Cons(4, Nil)), Nil)
)
let flat: List[i32] = std.list.flatten[i32](nested)
// Cons(1, Cons(2, Cons(3, Cons(4, Nil))))
```

### Slicing Operations

#### take

```kira
pub fn take[A](list: List[A], n: i32) -> List[A]
```

Returns the first `n` elements of the list.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Cons(4, Nil))))
let first_two: List[i32] = std.list.take[i32](nums, 2)
// Cons(1, Cons(2, Nil))
```

#### drop

```kira
pub fn drop[A](list: List[A], n: i32) -> List[A]
```

Returns the list without the first `n` elements.

**Example:**

```kira
let nums: List[i32] = Cons(1, Cons(2, Cons(3, Cons(4, Nil))))
let last_two: List[i32] = std.list.drop[i32](nums, 2)
// Cons(3, Cons(4, Nil))
```

#### zip

```kira
pub fn zip[A, B](list1: List[A], list2: List[B]) -> List[(A, B)]
```

Combines two lists into a list of pairs. Stops at the shorter list.

**Example:**

```kira
let a: List[i32] = Cons(1, Cons(2, Cons(3, Nil)))
let b: List[string] = Cons("a", Cons("b", Cons("c", Nil)))
let zipped: List[(i32, string)] = std.list.zip[i32, string](a, b)
// Cons((1, "a"), Cons((2, "b"), Cons((3, "c"), Nil)))
```

---

## std.option

Operations on the `Option[T]` type.

### map

```kira
pub fn map[A, B](opt: Option[A], f: fn(A) -> B) -> Option[B]
```

Applies a function to the value inside `Some`, or returns `None` if the option is `None`.

**Example:**

```kira
let some_val: Option[i32] = Some(5)
let doubled: Option[i32] = std.option.map[i32, i32](
    some_val,
    fn(x: i32) -> i32 { return x * 2 }
)
// Some(10)

let none_val: Option[i32] = None
let result: Option[i32] = std.option.map[i32, i32](
    none_val,
    fn(x: i32) -> i32 { return x * 2 }
)
// None
```

### and_then

```kira
pub fn and_then[A, B](opt: Option[A], f: fn(A) -> Option[B]) -> Option[B]
```

Applies a function that returns an `Option` to the value inside `Some`, flattening the result. Also known as `flatMap` or `bind`.

**Example:**

```kira
fn safe_divide(a: i32, b: i32) -> Option[i32] {
    if b == 0 {
        return None
    }
    return Some(a / b)
}

let val: Option[i32] = Some(10)
let result: Option[i32] = std.option.and_then[i32, i32](
    val,
    fn(x: i32) -> Option[i32] { return safe_divide(x, 2) }
)
// Some(5)
```

### unwrap_or

```kira
pub fn unwrap_or[A](opt: Option[A], default: A) -> A
```

Returns the value inside `Some`, or the default value if `None`.

**Example:**

```kira
let some_val: Option[i32] = Some(42)
let none_val: Option[i32] = None

let a: i32 = std.option.unwrap_or[i32](some_val, 0)  // 42
let b: i32 = std.option.unwrap_or[i32](none_val, 0)  // 0
```

### is_some

```kira
pub fn is_some[A](opt: Option[A]) -> bool
```

Returns `true` if the option is `Some`.

**Example:**

```kira
let val: Option[i32] = Some(42)
let check: bool = std.option.is_some[i32](val)  // true
```

### is_none

```kira
pub fn is_none[A](opt: Option[A]) -> bool
```

Returns `true` if the option is `None`.

**Example:**

```kira
let val: Option[i32] = None
let check: bool = std.option.is_none[i32](val)  // true
```

---

## std.result

Operations on the `Result[T, E]` type.

### map

```kira
pub fn map[T, E, U](res: Result[T, E], f: fn(T) -> U) -> Result[U, E]
```

Applies a function to the value inside `Ok`, or passes through `Err` unchanged.

**Example:**

```kira
let ok_val: Result[i32, string] = Ok(5)
let doubled: Result[i32, string] = std.result.map[i32, string, i32](
    ok_val,
    fn(x: i32) -> i32 { return x * 2 }
)
// Ok(10)

let err_val: Result[i32, string] = Err("error")
let result: Result[i32, string] = std.result.map[i32, string, i32](
    err_val,
    fn(x: i32) -> i32 { return x * 2 }
)
// Err("error")
```

### map_err

```kira
pub fn map_err[T, E, F](res: Result[T, E], f: fn(E) -> F) -> Result[T, F]
```

Applies a function to the error inside `Err`, or passes through `Ok` unchanged.

**Example:**

```kira
let err_val: Result[i32, string] = Err("error")
let mapped: Result[i32, i32] = std.result.map_err[i32, string, i32](
    err_val,
    fn(e: string) -> i32 { return std.string.length(e) }
)
// Err(5)
```

### and_then

```kira
pub fn and_then[T, E, U](res: Result[T, E], f: fn(T) -> Result[U, E]) -> Result[U, E]
```

Applies a function that returns a `Result` to the value inside `Ok`, flattening the result.

**Example:**

```kira
fn safe_divide(a: i32, b: i32) -> Result[i32, string] {
    if b == 0 {
        return Err("Division by zero")
    }
    return Ok(a / b)
}

let val: Result[i32, string] = Ok(10)
let result: Result[i32, string] = std.result.and_then[i32, string, i32](
    val,
    fn(x: i32) -> Result[i32, string] { return safe_divide(x, 2) }
)
// Ok(5)
```

### unwrap_or

```kira
pub fn unwrap_or[T, E](res: Result[T, E], default: T) -> T
```

Returns the value inside `Ok`, or the default value if `Err`.

**Example:**

```kira
let ok_val: Result[i32, string] = Ok(42)
let err_val: Result[i32, string] = Err("error")

let a: i32 = std.result.unwrap_or[i32, string](ok_val, 0)   // 42
let b: i32 = std.result.unwrap_or[i32, string](err_val, 0)  // 0
```

### is_ok

```kira
pub fn is_ok[T, E](res: Result[T, E]) -> bool
```

Returns `true` if the result is `Ok`.

### is_err

```kira
pub fn is_err[T, E](res: Result[T, E]) -> bool
```

Returns `true` if the result is `Err`.

---

## std.string

String manipulation functions.

### length

```kira
pub fn length(s: string) -> i32
```

Returns the length of the string in characters.

**Example:**

```kira
let len: i32 = std.string.length("hello")  // 5
```

### split

```kira
pub fn split(s: string, delimiter: string) -> List[string]
```

Splits a string by the delimiter into a list of strings.

**Example:**

```kira
let parts: List[string] = std.string.split("a,b,c", ",")
// Cons("a", Cons("b", Cons("c", Nil)))
```

### trim

```kira
pub fn trim(s: string) -> string
```

Removes leading and trailing whitespace.

**Example:**

```kira
let trimmed: string = std.string.trim("  hello  ")  // "hello"
```

### concat

```kira
pub fn concat(a: string, b: string) -> string
```

Concatenates two strings. Note: you can also use the `+` operator.

**Example:**

```kira
let full: string = std.string.concat("hello", " world")  // "hello world"
// Or: let full: string = "hello" + " world"
```

### contains

```kira
pub fn contains(s: string, substring: string) -> bool
```

Returns `true` if the string contains the substring.

**Example:**

```kira
let has_ll: bool = std.string.contains("hello", "ll")  // true
```

### starts_with

```kira
pub fn starts_with(s: string, prefix: string) -> bool
```

Returns `true` if the string starts with the prefix.

**Example:**

```kira
let check: bool = std.string.starts_with("hello", "he")  // true
```

### ends_with

```kira
pub fn ends_with(s: string, suffix: string) -> bool
```

Returns `true` if the string ends with the suffix.

**Example:**

```kira
let check: bool = std.string.ends_with("hello", "lo")  // true
```

### to_upper

```kira
pub fn to_upper(s: string) -> string
```

Converts the string to uppercase.

**Example:**

```kira
let upper: string = std.string.to_upper("hello")  // "HELLO"
```

### to_lower

```kira
pub fn to_lower(s: string) -> string
```

Converts the string to lowercase.

**Example:**

```kira
let lower: string = std.string.to_lower("HELLO")  // "hello"
```

### replace

```kira
pub fn replace(s: string, old: string, new: string) -> string
```

Replaces all occurrences of `old` with `new`.

**Example:**

```kira
let result: string = std.string.replace("hello", "l", "L")  // "heLLo"
```

### substring

```kira
pub fn substring(s: string, start: i32, end: i32) -> string
```

Returns a substring from index `start` (inclusive) to `end` (exclusive).

**Example:**

```kira
let sub: string = std.string.substring("hello", 1, 4)  // "ell"
```

### char_at

```kira
pub fn char_at(s: string, index: i32) -> Option[char]
```

Returns the character at the given index, or `None` if out of bounds.

**Example:**

```kira
let c: Option[char] = std.string.char_at("hello", 1)  // Some('e')
```

### index_of

```kira
pub fn index_of(s: string, substring: string) -> Option[i32]
```

Returns the index of the first occurrence of the substring, or `None` if not found.

**Example:**

```kira
let idx: Option[i32] = std.string.index_of("hello", "ll")  // Some(2)
```

### chars

```kira
pub fn chars(s: string) -> List[char]
```

Converts a string to a list of Unicode characters. Each character in the resulting list is a Unicode code point.

**Example:**

```kira
let chars_list: List[char] = std.string.chars("abc")
// Result: Cons('a', Cons('b', Cons('c', Nil)))

// Works with Unicode
let emoji_chars: List[char] = std.string.chars("Hi!")
// Result: Cons('H', Cons('i', Cons('!', Nil)))

// Iterate over characters
for c in std.string.chars("hello") {
    std.io.println(to_string(c))
}
```

### parse_int

```kira
pub fn parse_int(s: string) -> Option[i64]
```

Parses a string as an integer. Returns `None` if the string is not a valid integer.

**Example:**

```kira
match std.string.parse_int("42") {
    Some(n) => { std.io.println("Parsed: " + to_string(n)) }  // 42
    None => { std.io.println("Invalid number") }
}

let invalid: Option[i64] = std.string.parse_int("abc")  // None
```

---

## std.fs

File system operations.

> **Note:** All functions in `std.fs` are effect functions and require an `effect fn` context.

### read_file

```kira
pub effect fn read_file(path: string) -> IO[Result[string, string]]
```

Reads the entire contents of a file as a string.

**Example:**

```kira
effect fn main() -> void {
    match std.fs.read_file("data.txt") {
        Ok(content) => { std.io.println(content) }
        Err(e) => { std.io.println("Error: " + e) }
    }
}
```

### write_file

```kira
pub effect fn write_file(path: string, content: string) -> IO[Result[void, string]]
```

Writes a string to a file, creating it if it doesn't exist or overwriting if it does.

**Example:**

```kira
effect fn main() -> void {
    match std.fs.write_file("output.txt", "Hello, file!") {
        Ok(_) => { std.io.println("File written successfully") }
        Err(e) => { std.io.println("Error: " + e) }
    }
}
```

### exists

```kira
pub effect fn exists(path: string) -> IO[bool]
```

Returns `true` if the file or directory exists.

**Example:**

```kira
effect fn main() -> void {
    if std.fs.exists("config.txt") {
        std.io.println("Config file found")
    } else {
        std.io.println("Config file not found")
    }
}
```

### remove

```kira
pub effect fn remove(path: string) -> IO[Result[void, string]]
```

Deletes a file.

**Example:**

```kira
effect fn main() -> void {
    match std.fs.remove("temp.txt") {
        Ok(_) => { std.io.println("File deleted") }
        Err(e) => { std.io.println("Error: " + e) }
    }
}
```

---

## std.builder

Efficient string building operations. The builder uses an immutable, functional API - each operation returns a new builder.

### new

```kira
pub fn new() -> StringBuilder
```

Creates a new empty string builder.

**Example:**

```kira
let builder: StringBuilder = std.builder.new()
```

### append

```kira
pub fn append(builder: StringBuilder, s: string) -> StringBuilder
```

Appends a string to the builder, returning a new builder.

**Example:**

```kira
let b1: StringBuilder = std.builder.new()
let b2: StringBuilder = std.builder.append(b1, "Hello")
let b3: StringBuilder = std.builder.append(b2, ", World!")
let result: string = std.builder.build(b3)  // "Hello, World!"
```

### append_char

```kira
pub fn append_char(builder: StringBuilder, c: char) -> StringBuilder
```

Appends a single character to the builder.

**Example:**

```kira
let b: StringBuilder = std.builder.new()
let b2: StringBuilder = std.builder.append_char(b, 'H')
let b3: StringBuilder = std.builder.append_char(b2, 'i')
let result: string = std.builder.build(b3)  // "Hi"
```

### append_int

```kira
pub fn append_int(builder: StringBuilder, n: i32) -> StringBuilder
```

Appends an integer as its string representation.

**Example:**

```kira
let b: StringBuilder = std.builder.new()
let b2: StringBuilder = std.builder.append(b, "Count: ")
let b3: StringBuilder = std.builder.append_int(b2, 42)
let result: string = std.builder.build(b3)  // "Count: 42"
```

### append_float

```kira
pub fn append_float(builder: StringBuilder, f: f64) -> StringBuilder
```

Appends a float as its string representation.

**Example:**

```kira
let b: StringBuilder = std.builder.new()
let b2: StringBuilder = std.builder.append(b, "Pi: ")
let b3: StringBuilder = std.builder.append_float(b2, 3.14159)
let result: string = std.builder.build(b3)  // "Pi: 3.14159"
```

### build

```kira
pub fn build(builder: StringBuilder) -> string
```

Returns the final built string.

**Example:**

```kira
let b: StringBuilder = std.builder.new()
let b2: StringBuilder = std.builder.append(b, "Done!")
let result: string = std.builder.build(b2)  // "Done!"
```

### clear

```kira
pub fn clear(builder: StringBuilder) -> StringBuilder
```

Returns an empty builder (clears all content).

**Example:**

```kira
let b: StringBuilder = std.builder.append(std.builder.new(), "text")
let empty: StringBuilder = std.builder.clear(b)
let len: i32 = std.builder.length(empty)  // 0
```

### length

```kira
pub fn length(builder: StringBuilder) -> i32
```

Returns the current length of the built string.

**Example:**

```kira
let b: StringBuilder = std.builder.append(std.builder.new(), "hello")
let len: i32 = std.builder.length(b)  // 5
```

---

## std.map

Hash map with string keys and values of any type. Uses immutable, functional API - operations return new maps.

### new

```kira
pub fn new() -> HashMap
```

Creates a new empty hash map.

**Example:**

```kira
let map: HashMap = std.map.new()
```

### put

```kira
pub fn put(map: HashMap, key: string, value: any) -> HashMap
```

Inserts or updates a key-value pair, returning a new map.

**Example:**

```kira
let m1: HashMap = std.map.new()
let m2: HashMap = std.map.put(m1, "name", "Alice")
let m3: HashMap = std.map.put(m2, "age", 30)
```

### get

```kira
pub fn get(map: HashMap, key: string) -> Option[any]
```

Returns the value for a key, or `None` if not found.

**Example:**

```kira
let map: HashMap = std.map.put(std.map.new(), "name", "Alice")
match std.map.get(map, "name") {
    Some(value) => { std.io.println("Found: " + value) }
    None => { std.io.println("Not found") }
}
```

### contains

```kira
pub fn contains(map: HashMap, key: string) -> bool
```

Returns `true` if the key exists in the map.

**Example:**

```kira
let map: HashMap = std.map.put(std.map.new(), "key", "value")
let exists: bool = std.map.contains(map, "key")  // true
let missing: bool = std.map.contains(map, "other")  // false
```

### remove

```kira
pub fn remove(map: HashMap, key: string) -> HashMap
```

Returns a new map without the specified key.

**Example:**

```kira
let m1: HashMap = std.map.put(std.map.new(), "a", 1)
let m2: HashMap = std.map.put(m1, "b", 2)
let m3: HashMap = std.map.remove(m2, "a")  // only has "b"
```

### keys

```kira
pub fn keys(map: HashMap) -> List[string]
```

Returns a list of all keys in the map.

**Example:**

```kira
let map: HashMap = std.map.put(std.map.put(std.map.new(), "a", 1), "b", 2)
let all_keys: List[string] = std.map.keys(map)
```

### values

```kira
pub fn values(map: HashMap) -> List[any]
```

Returns a list of all values in the map.

**Example:**

```kira
let map: HashMap = std.map.put(std.map.put(std.map.new(), "x", 10), "y", 20)
let all_values: List[i32] = std.map.values(map)
```

### entries

```kira
pub fn entries(map: HashMap) -> List[(string, any)]
```

Returns a list of all (key, value) tuples.

**Example:**

```kira
let map: HashMap = std.map.put(std.map.new(), "name", "Bob")
let all_entries: List[(string, string)] = std.map.entries(map)
```

### size

```kira
pub fn size(map: HashMap) -> i32
```

Returns the number of entries in the map.

**Example:**

```kira
let map: HashMap = std.map.put(std.map.put(std.map.new(), "a", 1), "b", 2)
let count: i32 = std.map.size(map)  // 2
```

### is_empty

```kira
pub fn is_empty(map: HashMap) -> bool
```

Returns `true` if the map has no entries.

**Example:**

```kira
let empty: HashMap = std.map.new()
let check: bool = std.map.is_empty(empty)  // true
```

---

## std.char

Character operations for Unicode support.

### from_i32

```kira
pub fn from_i32(code_point: i32) -> Option[char]
```

Converts an integer Unicode code point to a character. Returns `None` for invalid code points (negative, > 0x10FFFF, or surrogate range 0xD800-0xDFFF).

**Example:**

```kira
match std.char.from_i32(65) {
    Some(c) => { std.io.println("Character: " + to_string(c)) }  // 'A'
    None => { std.io.println("Invalid code point") }
}

// Unicode snowman U+2603
match std.char.from_i32(0x2603) {
    Some(c) => { std.io.println("Snowman: " + to_string(c)) }
    None => {}
}

// Invalid code points return None
let invalid: Option[char] = std.char.from_i32(-1)  // None
let too_large: Option[char] = std.char.from_i32(0x110000)  // None
```

### to_i32

```kira
pub fn to_i32(c: char) -> i32
```

Converts a character to its Unicode code point.

**Example:**

```kira
let code: i32 = std.char.to_i32('A')  // 65
let emoji_code: i32 = std.char.to_i32('🎉')  // 127881
```

---

## std.math

Mathematical operations.

### trunc_to_i64

```kira
pub fn trunc_to_i64(f: f64) -> i64
```

Truncates a floating-point number towards zero, returning an integer. Returns an error for NaN or Infinity values. Integers are passed through unchanged.

**Example:**

```kira
let a: i64 = std.math.trunc_to_i64(3.7)   // 3
let b: i64 = std.math.trunc_to_i64(3.2)   // 3
let c: i64 = std.math.trunc_to_i64(-2.9)  // -2
let d: i64 = std.math.trunc_to_i64(-2.1)  // -2
let e: i64 = std.math.trunc_to_i64(42)    // 42 (integer passthrough)
```

---

## std.time

Time operations. Note that `now` and `sleep` are effect functions.

### now

```kira
pub effect fn now() -> i64
```

Returns the current timestamp in milliseconds since Unix epoch. This is an effect function (non-deterministic).

**Example:**

```kira
effect fn main() -> void {
    let start: i64 = std.time.now()
    // ... do some work ...
    let end: i64 = std.time.now()
    std.io.println("Elapsed: " + to_string(end - start) + "ms")
}
```

### sleep

```kira
pub effect fn sleep(ms: i64) -> void
```

Pauses execution for the specified number of milliseconds. This is an effect function (side effect).

**Example:**

```kira
effect fn main() -> void {
    std.io.println("Starting...")
    std.time.sleep(1000)  // Sleep for 1 second
    std.io.println("Done!")
}
```

### elapsed

```kira
pub fn elapsed(start: i64, end: i64) -> i64
```

Calculates elapsed time between two timestamps. This is a pure function.

**Example:**

```kira
effect fn main() -> void {
    let start: i64 = std.time.now()
    // ... work ...
    let end: i64 = std.time.now()
    let duration: i64 = std.time.elapsed(start, end)
    std.io.println("Duration: " + to_string(duration) + "ms")
}
```

---

## std.assert

Assertion functions for testing and debugging.

### assert

```kira
pub fn assert(condition: bool) -> void
```

Panics if the condition is false. Use for testing invariants.

**Example:**

```kira
fn test_addition() -> void {
    std.assert.assert(2 + 2 == 4)  // OK
}
```

### assert_eq

```kira
pub fn assert_eq(a: any, b: any) -> void
```

Panics if the two values are not equal. Provides better error messages than plain `assert`.

**Example:**

```kira
fn test_values() -> void {
    std.assert.assert_eq(2 + 2, 4)      // OK
    std.assert.assert_eq("hello", "hello")  // OK
}
```

---

## Built-in Functions

These functions are always available without importing.

### Type Operations

#### type_of

```kira
fn type_of(value: any) -> string
```

Returns a string representation of the value's type.

**Example:**

```kira
let t: string = type_of(42)      // "i32"
let t2: string = type_of("hi")   // "string"
```

### Conversions

#### to_string

```kira
fn to_string(value: any) -> string
```

Converts a value to its string representation.

**Example:**

```kira
let s: string = to_string(42)    // "42"
let s2: string = to_string(true) // "true"
```

#### to_int

```kira
fn to_int(value: any) -> i128
```

Converts a value to an integer.

**Example:**

```kira
let n: i128 = to_int(3.14)    // 3
let n2: i128 = to_int("42")   // 42
```

#### to_float

```kira
fn to_float(value: any) -> f64
```

Converts a value to a float.

**Example:**

```kira
let f: f64 = to_float(42)     // 42.0
let f2: f64 = to_float("3.14") // 3.14
```

### Math Operations

#### abs

```kira
fn abs(n: number) -> number
```

Returns the absolute value.

**Example:**

```kira
let a: i32 = abs(-5)   // 5
let b: f64 = abs(-3.14) // 3.14
```

#### min

```kira
fn min(a: number, b: number) -> number
```

Returns the smaller of two values.

**Example:**

```kira
let m: i32 = min(3, 7)  // 3
```

#### max

```kira
fn max(a: number, b: number) -> number
```

Returns the larger of two values.

**Example:**

```kira
let m: i32 = max(3, 7)  // 7
```

### Collection Operations

#### len

```kira
fn len(collection: any) -> i32
```

Returns the length of a collection (list, array, or string).

**Example:**

```kira
let l: i32 = len("hello")  // 5
let l2: i32 = len(Cons(1, Cons(2, Nil)))  // 2
```

#### head

```kira
fn head[T](list: List[T]) -> T
```

Returns the first element of a list. Errors if the list is empty.

#### tail

```kira
fn tail[T](list: List[T]) -> List[T]
```

Returns the list without its first element.

#### reverse

```kira
fn reverse[T](list: List[T]) -> List[T]
```

Returns a reversed copy of the list.

### Assertions

#### assert

```kira
fn assert(condition: bool) -> void
```

Panics if the condition is false. Used for testing.

**Example:**

```kira
assert(2 + 2 == 4)  // OK
assert(2 + 2 == 5)  // Panics!
```

#### assert_eq

```kira
fn assert_eq(a: any, b: any) -> void
```

Panics if the two values are not equal. Used for testing.

**Example:**

```kira
assert_eq(2 + 2, 4)  // OK
assert_eq("hello", "hello")  // OK
```

### Type Constructors

These constructors are available for creating instances of the core types:

| Constructor | Type | Example |
|-------------|------|---------|
| `Some(x)` | `Option[T]` | `Some(42)` |
| `None` | `Option[T]` | `None` |
| `Ok(x)` | `Result[T, E]` | `Ok(42)` |
| `Err(e)` | `Result[T, E]` | `Err("error")` |
| `Cons(h, t)` | `List[T]` | `Cons(1, Nil)` |
| `Nil` | `List[T]` | `Nil` |

---

## Index of All Functions

### std.io
- `print(msg: string)` - Print without newline
- `println(msg: string)` - Print with newline
- `read_line()` - Read line from stdin
- `eprint(msg: string)` - Print to stderr
- `eprintln(msg: string)` - Print to stderr with newline

### std.list
- `head[A](list)` - Get first element (returns Option)
- `tail[A](list)` - Get rest of list (returns Option)
- `empty[A]()` - Create empty list
- `singleton[A](value)` - Create single-element list
- `cons[A](head, tail)` - Prepend element
- `map[A, B](list, f)` - Transform elements
- `filter[A](list, pred)` - Keep matching elements
- `fold[A, B](list, init, f)` - Left fold
- `fold_right[A, B](list, init, f)` - Right fold
- `find[A](list, pred)` - Find first matching
- `any[A](list, pred)` - Check if any match
- `all[A](list, pred)` - Check if all match
- `length[A](list)` - Count elements
- `reverse[A](list)` - Reverse list
- `concat[A](list1, list2)` - Join lists
- `flatten[A](lists)` - Flatten nested lists
- `take[A](list, n)` - Take first n
- `drop[A](list, n)` - Skip first n
- `zip[A, B](list1, list2)` - Pair up elements

### std.option
- `map[A, B](opt, f)` - Transform value if present
- `and_then[A, B](opt, f)` - Chain operations
- `unwrap_or[A](opt, default)` - Get value or default
- `is_some[A](opt)` - Check if has value
- `is_none[A](opt)` - Check if empty

### std.result
- `map[T, E, U](res, f)` - Transform success value
- `map_err[T, E, F](res, f)` - Transform error value
- `and_then[T, E, U](res, f)` - Chain operations
- `unwrap_or[T, E](res, default)` - Get value or default
- `is_ok[T, E](res)` - Check if success
- `is_err[T, E](res)` - Check if error

### std.string
- `length(s)` - String length
- `split(s, delim)` - Split by delimiter
- `trim(s)` - Remove whitespace
- `concat(a, b)` - Join strings
- `contains(s, sub)` - Check for substring
- `starts_with(s, prefix)` - Check prefix
- `ends_with(s, suffix)` - Check suffix
- `to_upper(s)` - Convert to uppercase
- `to_lower(s)` - Convert to lowercase
- `replace(s, old, new)` - Replace substrings
- `substring(s, start, end)` - Extract substring
- `char_at(s, index)` - Get character at index
- `index_of(s, sub)` - Find substring position
- `chars(s)` - Convert to list of characters
- `parse_int(s)` - Parse string to integer

### std.fs
- `read_file(path)` - Read file contents
- `write_file(path, content)` - Write to file
- `exists(path)` - Check if file exists
- `remove(path)` - Delete file

### std.builder
- `new()` - Create empty string builder
- `append(builder, s)` - Append string
- `append_char(builder, c)` - Append character
- `append_int(builder, n)` - Append integer
- `append_float(builder, f)` - Append float
- `build(builder)` - Get final string
- `clear(builder)` - Clear contents
- `length(builder)` - Get current length

### std.map
- `new()` - Create empty hash map
- `put(map, key, value)` - Insert/update entry
- `get(map, key)` - Get value (returns Option)
- `contains(map, key)` - Check if key exists
- `remove(map, key)` - Remove entry
- `keys(map)` - Get all keys as list
- `values(map)` - Get all values as list
- `entries(map)` - Get all (key, value) tuples
- `size(map)` - Get entry count
- `is_empty(map)` - Check if empty

### std.char
- `from_i32(code)` - Code point to char (returns Option)
- `to_i32(c)` - Char to code point

### std.math
- `trunc_to_i64(f)` - Truncate float to integer

### std.time
- `now()` - Get current timestamp (effect)
- `sleep(ms)` - Sleep for milliseconds (effect)
- `elapsed(start, end)` - Calculate elapsed time

### std.assert
- `assert(condition)` - Assert condition is true
- `assert_eq(a, b)` - Assert values are equal
