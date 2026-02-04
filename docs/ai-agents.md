# Kira for AI Agents

This guide explains why Kira was designed for AI code generation and how AI agents can leverage its features effectively.

## Why Kira for AI?

Traditional programming languages evolved for human programmers, accumulating implicit behaviors, syntactic sugar, and "magic" that experienced developers understand intuitively. AI models, however, benefit from **explicitness** and **consistency**.

Kira addresses the key challenges AI agents face when generating code:

| Challenge | Traditional Languages | Kira's Solution |
|-----------|----------------------|-----------------|
| Type inference | Types hidden, errors unclear | All types explicit and visible |
| Implicit conversions | Silent type coercion | No implicit conversions |
| Multiple syntax forms | Many ways to do the same thing | One obvious way per construct |
| Hidden side effects | Effects happen anywhere | Effects tracked in type system |
| Context-dependent behavior | Meaning varies by context | Consistent semantics everywhere |

## Core Design Principles for AI

### 1. Explicit Types Everywhere

Every binding, parameter, and return type is explicitly declared. This means:

- **AI can verify correctness locally** - no need to trace through inference chains
- **Error messages are precise** - mismatches are caught at the point of declaration
- **Code is self-documenting** - types serve as always-accurate documentation

```kira
// GOOD: Clear, unambiguous types
fn process_user(user_id: i64, options: ProcessOptions) -> Result[User, ApiError] {
    // ...
}

// What AI agents see:
// - Input: user_id is a 64-bit integer, options is a ProcessOptions record
// - Output: Either a User on success or an ApiError on failure
// - No hidden state, no implicit conversions
```

### 2. Effects Are Visible

Pure functions (the default) cannot perform I/O or mutation. Effect functions are explicitly marked:

```kira
// Pure function - AI knows this is deterministic and side-effect-free
fn calculate_total(items: List[LineItem]) -> f64 {
    return std.list.fold(items, 0.0, fn(sum: f64, item: LineItem) -> f64 {
        return sum + item.price * to_float(item.quantity)
    })
}

// Effect function - AI knows this interacts with the outside world
effect fn save_order(order: Order) -> IO[Result[OrderId, DbError]] {
    // Database interaction
}
```

This separation allows AI agents to:
- **Reason about pure code algebraically** - same inputs always produce same outputs
- **Identify side-effect boundaries** - know exactly where external state is involved
- **Refactor pure code safely** - reordering, inlining, and extraction are always safe

### 3. One Way to Do Things

Kira deliberately limits syntactic choices to reduce ambiguity:

```kira
// Only one way to define a function
fn add(a: i32, b: i32) -> i32 {
    return a + b
}

// Only one way to return values
return result

// Only one way to handle optional values
match maybe_value {
    Some(v) => { /* use v */ }
    None => { /* handle absence */ }
}
```

No implicit returns, no ternary operators, no expression-vs-statement ambiguity. AI agents can pattern-match on these consistent structures.

### 4. Pattern Matching Over Conditionals

Sum types and pattern matching provide exhaustiveness checking:

```kira
type ApiResponse =
    | Success(Data)
    | NotFound(string)
    | Unauthorized
    | RateLimited(i32)

fn handle_response(response: ApiResponse) -> string {
    // Compiler ensures all cases are handled
    match response {
        Success(data) => { return format_data(data) }
        NotFound(resource) => { return "Not found: " + resource }
        Unauthorized => { return "Access denied" }
        RateLimited(seconds) => { return "Retry after " + to_string(seconds) + "s" }
    }
}
```

AI agents benefit from:
- **Exhaustiveness checking** - compiler catches missing cases
- **Structured branching** - each case is independent and explicit
- **Data extraction** - pattern variables bind safely to the correct types

## AI-Friendly Patterns

### Structured Error Handling

Use `Result[T, E]` for operations that can fail:

```kira
type ValidationError =
    | EmptyField(string)
    | InvalidFormat(string, string)
    | ValueOutOfRange(string, i64, i64, i64)

fn validate_user_input(input: UserInput) -> Result[ValidatedInput, ValidationError] {
    if std.string.length(input.name) == 0 {
        return Err(EmptyField("name"))
    }
    if input.age < 0 {
        return Err(ValueOutOfRange("age", to_i64(input.age), 0i64, 150i64))
    }
    // ...validation logic...
    return Ok(ValidatedInput { name: input.name, age: input.age })
}
```

This pattern:
- **Documents failure modes** - error variants are part of the type
- **Forces error handling** - callers must handle the Result
- **Enables error propagation** - the `?` operator chains errors cleanly

### Data Transformation Pipelines

Compose pure functions for data processing:

```kira
fn process_orders(orders: List[Order]) -> Summary {
    let valid_orders: List[Order] = std.list.filter(orders,
        fn(o: Order) -> bool { return o.status == OrderStatus.Confirmed })

    let totals: List[f64] = std.list.map(valid_orders,
        fn(o: Order) -> f64 { return calculate_order_total(o) })

    let grand_total: f64 = std.list.fold(totals, 0.0,
        fn(sum: f64, t: f64) -> f64 { return sum + t })

    let order_count: i32 = std.list.length(valid_orders)

    return Summary {
        total_orders: order_count,
        total_revenue: grand_total,
        average_order: if order_count > 0 { grand_total / to_float(order_count) } else { 0.0 }
    }
}
```

Each step is:
- **Independently testable** - pure functions with clear inputs/outputs
- **Composable** - can be rearranged without side-effect concerns
- **Traceable** - intermediate values can be inspected

### State Machines with Sum Types

Model state transitions explicitly:

```kira
type ConnectionState =
    | Disconnected
    | Connecting(string, i32)  // host, port
    | Connected(Socket)
    | Reconnecting(i32)        // attempt count

fn handle_event(state: ConnectionState, event: NetworkEvent) -> ConnectionState {
    match (state, event) {
        (Disconnected, Connect(host, port)) => {
            return Connecting(host, port)
        }
        (Connecting(host, port), Connected(socket)) => {
            return Connected(socket)
        }
        (Connecting(_, _), Timeout) => {
            return Disconnected
        }
        (Connected(socket), Disconnect) => {
            close_socket(socket)
            return Disconnected
        }
        (Connected(_), Error(_)) => {
            return Reconnecting(1)
        }
        (_, _) => {
            return state  // Ignore invalid transitions
        }
    }
}
```

This approach:
- **Makes states explicit** - impossible states are unrepresentable
- **Documents transitions** - match arms show all valid state changes
- **Supports reasoning** - AI can analyze the state machine formally

## Generating Kira Code

### Prompting Guidelines

When asking an AI to generate Kira code, be explicit about:

1. **Input types** - What data structures are available?
2. **Output types** - What should the function return?
3. **Effect requirements** - Does the function need I/O?
4. **Error conditions** - What can go wrong?

Example prompt structure:

```
Write a Kira function that:
- Takes a List[User] and a minimum age (i32)
- Returns a List[string] of email addresses
- Only includes users who are at least the minimum age
- Pure function (no effects needed)
```

### Common Generation Patterns

**List transformation:**
```kira
fn extract_emails_over_age(users: List[User], min_age: i32) -> List[string] {
    let filtered: List[User] = std.list.filter(users,
        fn(u: User) -> bool { return u.age >= min_age })
    return std.list.map(filtered,
        fn(u: User) -> string { return u.email })
}
```

**Validation with Result:**
```kira
fn parse_config(raw: string) -> Result[Config, ConfigError] {
    let parts: List[string] = std.string.split(raw, "=")
    if std.list.length(parts) != 2 {
        return Err(ConfigError.InvalidFormat("Expected key=value"))
    }
    // ...
    return Ok(config)
}
```

**Recursive data processing:**
```kira
fn sum_tree(tree: Tree[i32]) -> i32 {
    match tree {
        Leaf(value) => { return value }
        Node(left, right) => {
            return sum_tree(left) + sum_tree(right)
        }
    }
}
```

## Testing AI-Generated Code

Kira's explicitness makes testing straightforward:

```kira
fn test_extraction() -> void {
    let users: List[User] = Cons(
        User { name: "Alice", age: 30, email: "alice@example.com" },
        Cons(
            User { name: "Bob", age: 17, email: "bob@example.com" },
            Cons(
                User { name: "Carol", age: 25, email: "carol@example.com" },
                Nil
            )
        )
    )

    let result: List[string] = extract_emails_over_age(users, 21)

    assert_eq(std.list.length(result), 2)
    // First should be Alice (age 30 >= 21)
    // Second should be Carol (age 25 >= 21)
    // Bob (age 17) should be filtered out
}
```

## Summary

Kira's design choices optimize for AI code generation:

| Feature | Benefit for AI |
|---------|----------------|
| Explicit types | Local verification, clear contracts |
| No inference | Predictable behavior, no hidden complexity |
| Effect tracking | Clear separation of pure and effectful code |
| Single syntax | Pattern-matchable, consistent generation |
| Sum types | Exhaustive handling, impossible states unrepresentable |
| Pattern matching | Structured branching, safe data extraction |
| Explicit returns | Unambiguous control flow |

When working with Kira, AI agents can generate more reliable code with fewer ambiguities, and humans can more easily verify AI-generated code by inspection.
