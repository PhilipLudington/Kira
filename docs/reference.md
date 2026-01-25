# Kira Language Reference

Complete syntax and semantics reference for the Kira programming language.

## Table of Contents

1. [Overview](#overview)
2. [Lexical Structure](#lexical-structure)
3. [Types](#types)
4. [Expressions](#expressions)
5. [Statements](#statements)
6. [Functions](#functions)
7. [Type Definitions](#type-definitions)
8. [Pattern Matching](#pattern-matching)
9. [Modules and Imports](#modules-and-imports)
10. [Effects System](#effects-system)
11. [Operators](#operators)
12. [Keywords](#keywords)

---

## Overview

Kira is a functional programming language with three core principles:

1. **Explicit Types**: Every binding must have a type annotation. No type inference.
2. **Explicit Effects**: Side effects are tracked and visible in function signatures.
3. **No Surprises**: One obvious way to do things, predictable behavior.

### Philosophy

Kira is designed for clarity and predictability, making it ideal for:
- AI code generation (explicit types make generation more reliable)
- Teams that value readable, self-documenting code
- Applications where side effect tracking matters

---

## Lexical Structure

### Comments

```kira
// Single-line comment

/* Multi-line
   comment */
```

### Identifiers

Identifiers start with a letter or underscore, followed by letters, digits, or underscores.

```
identifier = [a-zA-Z_][a-zA-Z0-9_]*
```

Valid: `x`, `myVar`, `_private`, `count2`
Invalid: `2fast`, `my-var`, `class`

### Literals

#### Integer Literals

```kira
42          // Decimal
0xff        // Hexadecimal
0b1010      // Binary
1_000_000   // With underscores for readability
42i64       // With type suffix
```

**Supported suffixes**: `i8`, `i16`, `i32`, `i64`, `i128`, `u8`, `u16`, `u32`, `u64`, `u128`

#### Float Literals

```kira
3.14        // Decimal
1.0e-10     // Scientific notation
2.5f32      // With type suffix
```

**Supported suffixes**: `f32`, `f64`

#### Boolean Literals

```kira
true
false
```

#### Character Literals

```kira
'A'         // ASCII character
'🎉'        // Unicode character
'\n'        // Escape sequence
'\t'        // Tab
'\\'        // Backslash
'\''        // Single quote
```

#### String Literals

```kira
"Hello, World!"
"Line 1\nLine 2"    // With escape sequences
"Tab:\tHere"
"Quote: \"hi\""
```

**Escape sequences**: `\n` (newline), `\t` (tab), `\\` (backslash), `\"` (quote), `\r` (carriage return)

---

## Types

### Primitive Types

| Type | Description | Range/Size |
|------|-------------|------------|
| `i8` | Signed 8-bit integer | -128 to 127 |
| `i16` | Signed 16-bit integer | -32,768 to 32,767 |
| `i32` | Signed 32-bit integer (default) | -2³¹ to 2³¹-1 |
| `i64` | Signed 64-bit integer | -2⁶³ to 2⁶³-1 |
| `i128` | Signed 128-bit integer | -2¹²⁷ to 2¹²⁷-1 |
| `u8` | Unsigned 8-bit integer | 0 to 255 |
| `u16` | Unsigned 16-bit integer | 0 to 65,535 |
| `u32` | Unsigned 32-bit integer | 0 to 2³²-1 |
| `u64` | Unsigned 64-bit integer | 0 to 2⁶⁴-1 |
| `u128` | Unsigned 128-bit integer | 0 to 2¹²⁸-1 |
| `f32` | 32-bit floating point | IEEE 754 single |
| `f64` | 64-bit floating point (default) | IEEE 754 double |
| `bool` | Boolean | `true` or `false` |
| `char` | Unicode scalar value | U+0000 to U+10FFFF |
| `string` | UTF-8 string | Arbitrary length |
| `void` | No value | Used for functions returning nothing |

### Composite Types

#### Tuples

Fixed-size, heterogeneous collections:

```kira
let pair: (i32, string) = (42, "hello")
let triple: (i32, bool, f64) = (1, true, 3.14)

// Access by index
let first: i32 = pair.0
let second: string = pair.1
```

#### Arrays

Fixed-size, homogeneous collections:

```kira
let numbers: [i32; 5] = [1, 2, 3, 4, 5]
let zeros: [i32; 3] = [0, 0, 0]
```

#### Function Types

```kira
fn(i32, i32) -> i32              // Function taking two i32, returning i32
fn(string) -> void               // Function taking string, returning nothing
fn() -> bool                     // Function taking nothing, returning bool
fn(fn(i32) -> i32, i32) -> i32   // Higher-order function
```

### Generic Types

Type parameters are specified in square brackets:

```kira
Option[T]           // Option containing type T
Result[T, E]        // Result with success type T and error type E
List[T]             // List of type T
(A, B)              // Tuple of A and B
```

### Built-in Generic Types

These types are automatically available:

```kira
type Option[T] =
    | Some(T)
    | None

type Result[T, E] =
    | Ok(T)
    | Err(E)

type List[T] =
    | Cons(T, List[T])
    | Nil
```

---

## Expressions

### Literals

See [Literals](#literals) above.

### Variables

```kira
let x: i32 = 42        // Immutable binding
var y: i32 = 0         // Mutable binding
y = 10                 // Reassignment (only for var)
```

### Arithmetic Expressions

```kira
a + b      // Addition
a - b      // Subtraction
a * b      // Multiplication
a / b      // Division
a % b      // Modulo (remainder)
-a         // Negation
```

### Comparison Expressions

```kira
a == b     // Equal
a != b     // Not equal
a < b      // Less than
a <= b     // Less than or equal
a > b      // Greater than
a >= b     // Greater than or equal
```

### Logical Expressions

```kira
a and b    // Logical AND
a or b     // Logical OR
not a      // Logical NOT
```

### String Concatenation

```kira
"Hello, " + name + "!"
```

### Function Calls

```kira
add(1, 2)                           // Regular call
std.io.println("Hello")             // Qualified call
identity[i32](42)                   // Generic call with type argument
std.list.map[i32, i32](nums, f)     // Generic with multiple type args
```

### Field Access

```kira
point.x           // Record field access
tuple.0           // Tuple element access
user.address.city // Chained access
```

### Constructor Calls

```kira
// Sum type constructors
Some(42)
None
Ok("success")
Err("failure")
Cons(1, Nil)

// Record constructors
Point { x: 3.0, y: 4.0 }
User { id: 1, name: "Alice", email: "alice@example.com" }
```

### Anonymous Functions (Lambdas)

```kira
fn(x: i32) -> i32 { return x * 2 }
fn(a: i32, b: i32) -> i32 { return a + b }
fn() -> void { std.io.println("Hello") }
```

### Null Coalesce Operator

```kira
value ?? default    // Returns value if Some, otherwise default
maybe_name ?? "Anonymous"
```

### Try Operator

```kira
let x: i32 = risky_operation()?   // Propagates Err, unwraps Ok
```

Only usable in effect functions returning `Result`.

---

## Statements

### Let Bindings (Immutable)

```kira
let x: i32 = 42
let name: string = "Alice"
let pair: (i32, i32) = (1, 2)
```

### Var Bindings (Mutable)

```kira
var counter: i32 = 0
counter = counter + 1
```

### Assignment

```kira
counter = 10           // Variable assignment
point.x = 5.0          // Field assignment
```

### If Statements

```kira
if condition {
    // then branch
}

if condition {
    // then branch
} else {
    // else branch
}

if condition1 {
    // first
} else if condition2 {
    // second
} else {
    // default
}
```

### Match Statements

```kira
match value {
    pattern1 => { /* body */ }
    pattern2 => { /* body */ }
    _ => { /* default */ }
}
```

### For Loops

```kira
for item in collection {
    // process item
}

for x in list {
    std.io.println(to_string(x))
}
```

### While Loops

```kira
while condition {
    // body
}

var i: i32 = 0
while i < 10 {
    std.io.println(to_string(i))
    i = i + 1
}
```

### Loop (Infinite)

```kira
loop {
    // body - use break to exit
    if done {
        break
    }
}
```

### Return Statement

```kira
return value    // Return with value
return          // Return void
```

### Break Statement

```kira
break    // Exit loop
```

---

## Functions

### Function Declaration

```kira
fn name(param1: Type1, param2: Type2) -> ReturnType {
    // body
    return result
}
```

**Examples:**

```kira
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

fn greet(name: string) -> void {
    std.io.println("Hello, " + name)
    return
}

fn is_positive(n: i32) -> bool {
    return n > 0
}
```

### Effect Functions

```kira
effect fn name(params) -> ReturnType {
    // can perform side effects
}
```

**Examples:**

```kira
effect fn main() -> void {
    std.io.println("Hello, World!")
}

effect fn read_config() -> Result[Config, string] {
    match std.fs.read_file("config.txt") {
        Ok(content) => { return Ok(parse_config(content)) }
        Err(e) => { return Err(e) }
    }
}
```

### Generic Functions

```kira
fn name[T](param: T) -> T {
    return param
}

fn name[A, B](a: A, b: B) -> (A, B) {
    return (a, b)
}
```

**Examples:**

```kira
fn identity[T](x: T) -> T {
    return x
}

fn swap[A, B](pair: (A, B)) -> (B, A) {
    let (a, b): (A, B) = pair
    return (b, a)
}

fn first[A, B](pair: (A, B)) -> A {
    return pair.0
}
```

### Functions as Values

```kira
let add: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 {
    return a + b
}

let result: i32 = add(1, 2)
```

### Higher-Order Functions

```kira
fn apply(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x)
}

fn make_adder(n: i32) -> fn(i32) -> i32 {
    return fn(x: i32) -> i32 { return x + n }
}
```

---

## Type Definitions

### Sum Types (Tagged Unions)

```kira
type TypeName =
    | Variant1
    | Variant2(Type)
    | Variant3(Type1, Type2)
```

**Examples:**

```kira
type Color =
    | Red
    | Green
    | Blue

type Shape =
    | Circle(f64)
    | Rectangle(f64, f64)
    | Triangle(f64, f64, f64)

type Option[T] =
    | Some(T)
    | None

type Result[T, E] =
    | Ok(T)
    | Err(E)

type List[T] =
    | Cons(T, List[T])
    | Nil
```

### Product Types (Records)

```kira
type TypeName = {
    field1: Type1,
    field2: Type2
}
```

**Examples:**

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

type Config = {
    host: string,
    port: i32,
    debug: bool
}
```

### Creating Values

```kira
// Sum types
let color: Color = Red
let shape: Shape = Circle(5.0)
let opt: Option[i32] = Some(42)
let list: List[i32] = Cons(1, Cons(2, Nil))

// Records
let p: Point = Point { x: 3.0, y: 4.0 }
let user: User = User {
    id: 1,
    name: "Alice",
    email: "alice@example.com",
    active: true
}
```

---

## Pattern Matching

### Match Statement Syntax

```kira
match expression {
    pattern => { body }
    pattern => { body }
}
```

### Pattern Types

#### Wildcard Pattern

```kira
_ => { /* matches anything */ }
```

#### Variable Pattern

```kira
x => { /* binds value to x */ }
n => { return n * 2 }
```

#### Literal Patterns

```kira
0 => { /* matches zero */ }
"hello" => { /* matches string */ }
true => { /* matches true */ }
'a' => { /* matches character */ }
```

#### Constructor Patterns

```kira
Some(x) => { /* matches Some, binds inner to x */ }
None => { /* matches None */ }
Ok(value) => { /* matches Ok */ }
Err(e) => { /* matches Err */ }
Cons(head, tail) => { /* matches non-empty list */ }
Nil => { /* matches empty list */ }
```

#### Record Patterns

```kira
Point { x: 0.0, y: 0.0 } => { /* matches origin */ }
Point { x: x, y: y } => { /* binds fields */ }
User { name: n, active: true } => { /* partial match */ }
```

#### Tuple Patterns

```kira
(0, 0) => { /* matches (0, 0) */ }
(x, y) => { /* binds both elements */ }
(_, y) => { /* ignores first, binds second */ }
```

#### Or Patterns

```kira
1 | 2 | 3 => { /* matches 1, 2, or 3 */ }
Red | Green | Blue => { /* matches any color */ }
```

#### Guard Patterns

```kira
n if n > 0 => { /* matches positive numbers */ }
n if n < 0 => { /* matches negative numbers */ }
Some(x) if x > 10 => { /* conditional match */ }
```

### Destructuring Let

```kira
let (x, y): (i32, i32) = pair
let Point { x: px, y: py }: Point = point
let Cons(head, tail): List[i32] = list
```

### Complete Example

```kira
fn describe(shape: Shape) -> string {
    var result: string = ""
    match shape {
        Circle(r) => { result = "Circle with radius " + to_string(r) }
        Rectangle(w, h) => { result = "Rectangle " + to_string(w) + "x" + to_string(h) }
        Triangle(a, b, c) => { result = "Triangle with sides " + to_string(a) }
    }
    return result
}
```

---

## Modules and Imports

### Module Declaration

```kira
module package.name

// module contents
```

### Import Syntax

```kira
// Import entire module
import std.list

// Import specific items
import std.list.{ map, filter, fold }

// Import with alias
import std.list.{ map as list_map }

// Import types
import std.option.{ Option, Some, None }
```

### Visibility

```kira
pub fn public_function() -> void { }  // Accessible from other modules
fn private_function() -> void { }      // Only accessible in this module

pub type PublicType = { ... }
type PrivateType = { ... }
```

### Module Organization

File: `src/math/vector.ki`
```kira
module math.vector

pub type Vec2 = {
    x: f64,
    y: f64
}

pub fn add(a: Vec2, b: Vec2) -> Vec2 {
    return Vec2 { x: a.x + b.x, y: a.y + b.y }
}

pub fn dot(a: Vec2, b: Vec2) -> f64 {
    return a.x * b.x + a.y * b.y
}

fn helper() -> void { }  // Private
```

Using the module:
```kira
import math.vector.{ Vec2, add, dot }

effect fn main() -> void {
    let v1: Vec2 = Vec2 { x: 1.0, y: 2.0 }
    let v2: Vec2 = Vec2 { x: 3.0, y: 4.0 }
    let sum: Vec2 = add(v1, v2)
    std.io.println("Sum: (" + to_string(sum.x) + ", " + to_string(sum.y) + ")")
}
```

---

## Effects System

### Pure Functions (Default)

Pure functions have no side effects:
- Always return the same output for the same input
- Cannot perform I/O
- Cannot call effect functions

```kira
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

fn factorial(n: i32) -> i32 {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}
```

### Effect Functions

Effect functions can perform side effects:

```kira
effect fn greet(name: string) -> void {
    std.io.println("Hello, " + name + "!")
}

effect fn read_number() -> Result[i32, string] {
    match std.io.read_line() {
        Ok(line) => {
            match std.string.parse_int(line) {
                Some(n) => { return Ok(n) }
                None => { return Err("Invalid number") }
            }
        }
        Err(e) => { return Err(e) }
    }
}
```

### Effect Rules

1. **Pure functions cannot call effect functions**
   ```kira
   // ERROR: Pure function calling effect function
   fn bad() -> void {
       std.io.println("Hello")  // Compile error!
   }
   ```

2. **Effect functions can call both pure and effect functions**
   ```kira
   effect fn good() -> void {
       let x: i32 = add(1, 2)   // OK: calling pure function
       std.io.println(to_string(x))  // OK: we're an effect function
   }
   ```

3. **main() is always an effect function**
   ```kira
   effect fn main() -> void {
       // Entry point
   }
   ```

### Common Effect Patterns

```kira
// File I/O
effect fn read_config(path: string) -> Result[Config, string] {
    let content: string = std.fs.read_file(path)?
    return Ok(parse_config(content))
}

// User interaction
effect fn get_user_input(prompt: string) -> string {
    std.io.print(prompt)
    match std.io.read_line() {
        Ok(line) => { return line }
        Err(_) => { return "" }
    }
}

// Timed operations
effect fn benchmark(f: fn() -> void) -> i64 {
    let start: i64 = std.time.now()
    f()
    let end: i64 = std.time.now()
    return end - start
}
```

---

## Operators

### Arithmetic Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Addition | `a + b` |
| `-` | Subtraction | `a - b` |
| `*` | Multiplication | `a * b` |
| `/` | Division | `a / b` |
| `%` | Modulo | `a % b` |
| `-` (unary) | Negation | `-a` |

### Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `==` | Equal | `a == b` |
| `!=` | Not equal | `a != b` |
| `<` | Less than | `a < b` |
| `<=` | Less than or equal | `a <= b` |
| `>` | Greater than | `a > b` |
| `>=` | Greater than or equal | `a >= b` |

### Logical Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `and` | Logical AND | `a and b` |
| `or` | Logical OR | `a or b` |
| `not` | Logical NOT | `not a` |

### Other Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | String concatenation | `"a" + "b"` |
| `??` | Null coalesce | `opt ?? default` |
| `?` | Try (error propagation) | `result?` |
| `.` | Field/method access | `obj.field` |
| `[]` | Type argument | `List[i32]` |

### Operator Precedence (Highest to Lowest)

1. `.` (field access), `[]` (type arguments)
2. `-` (unary negation), `not`
3. `*`, `/`, `%`
4. `+`, `-`
5. `<`, `<=`, `>`, `>=`
6. `==`, `!=`
7. `and`
8. `or`
9. `??`
10. `?`

---

## Keywords

### Reserved Keywords

| Keyword | Description |
|---------|-------------|
| `and` | Logical AND |
| `break` | Exit loop |
| `effect` | Effect function marker |
| `else` | Else branch |
| `false` | Boolean false |
| `fn` | Function |
| `for` | For loop |
| `if` | Conditional |
| `import` | Import declaration |
| `in` | For loop iterator |
| `let` | Immutable binding |
| `loop` | Infinite loop |
| `match` | Pattern matching |
| `module` | Module declaration |
| `not` | Logical NOT |
| `or` | Logical OR |
| `pub` | Public visibility |
| `return` | Return statement |
| `true` | Boolean true |
| `type` | Type definition |
| `var` | Mutable binding |
| `while` | While loop |

### Built-in Type Names

| Type | Description |
|------|-------------|
| `bool` | Boolean |
| `char` | Unicode character |
| `f32`, `f64` | Floating point |
| `i8`, `i16`, `i32`, `i64`, `i128` | Signed integers |
| `u8`, `u16`, `u32`, `u64`, `u128` | Unsigned integers |
| `string` | UTF-8 string |
| `void` | No value |
| `Option` | Optional value |
| `Result` | Success or error |
| `List` | Linked list |

### Built-in Constructors

| Constructor | Type |
|-------------|------|
| `Some(x)` | `Option[T]` |
| `None` | `Option[T]` |
| `Ok(x)` | `Result[T, E]` |
| `Err(e)` | `Result[T, E]` |
| `Cons(h, t)` | `List[T]` |
| `Nil` | `List[T]` |

---

## Grammar Summary (EBNF)

```ebnf
program        = { declaration } ;

declaration    = type_def | function_def | import_decl | module_decl ;

module_decl    = "module" qualified_name ;
import_decl    = "import" qualified_name [ "{" import_list "}" ] ;
import_list    = import_item { "," import_item } ;
import_item    = identifier [ "as" identifier ] ;

type_def       = "type" identifier [ type_params ] "=" type_body ;
type_params    = "[" identifier { "," identifier } "]" ;
type_body      = sum_type | record_type ;
sum_type       = "|" variant { "|" variant } ;
variant        = identifier [ "(" type_list ")" ] ;
record_type    = "{" field_def { "," field_def } "}" ;
field_def      = identifier ":" type ;

function_def   = [ "pub" ] [ "effect" ] "fn" identifier [ type_params ]
                 "(" [ param_list ] ")" "->" type block ;
param_list     = param { "," param } ;
param          = identifier ":" type ;

type           = primitive_type | identifier [ type_args ] | tuple_type
               | array_type | function_type ;
type_args      = "[" type { "," type } "]" ;
tuple_type     = "(" type "," type { "," type } ")" ;
array_type     = "[" type ";" integer "]" ;
function_type  = "fn" "(" [ type_list ] ")" "->" type ;
type_list      = type { "," type } ;

block          = "{" { statement } "}" ;
statement      = let_stmt | var_stmt | assign_stmt | if_stmt | match_stmt
               | for_stmt | while_stmt | loop_stmt | return_stmt | break_stmt
               | expr_stmt ;

let_stmt       = "let" pattern ":" type "=" expression ;
var_stmt       = "var" identifier ":" type "=" expression ;
assign_stmt    = lvalue "=" expression ;
if_stmt        = "if" expression block [ "else" ( if_stmt | block ) ] ;
match_stmt     = "match" expression "{" { match_arm } "}" ;
match_arm      = pattern [ "if" expression ] "=>" block ;
for_stmt       = "for" identifier "in" expression block ;
while_stmt     = "while" expression block ;
loop_stmt      = "loop" block ;
return_stmt    = "return" [ expression ] ;
break_stmt     = "break" ;
expr_stmt      = expression ;

expression     = /* standard expression grammar with operators */ ;
pattern        = /* pattern grammar for matching */ ;
```
