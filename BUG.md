# Kira Bugs

## [ ] Bug 1: Match-as-expression produces broken runtime values

**Status:** Open

**Description:** Using `match` as an expression on the right side of a `let` binding passes type checking but produces void/undefined values at runtime. The variable bound to the match result appears valid to the type checker, but when accessed later (e.g., passed to `std.list.length`), the interpreter throws `error.TypeMismatch`.

**Steps to reproduce:**
1. Write a `let` binding with a `match` expression:
```kira
fn example(opt: Option[i64]) -> List[i64] {
    let result: List[i64] = match opt {
        Some(v) => { Cons(v, Nil) }
        None => { Nil }
    }
    return result
}
```
2. Call the function and use the returned value
3. Runtime error: `error.TypeMismatch` when the value is consumed by stdlib functions

**Expected:** The `let` binding captures the value produced by the matched arm's block expression.

**Actual:** The binding gets a void/undefined value. Any subsequent operation on it (e.g., `std.list.length`, `std.list.fold`) fails with `TypeMismatch`.

**Root cause:** The grammar defines `match` as a statement (`match_stmt`), not an expression. The parser/type checker accept `let x = match ...` without error, but the interpreter evaluates the match as a statement (no return value) rather than as an expression that yields the last value of the matched block.

**Workaround:** Use `var` with imperative assignment instead:
```kira
var result: List[i64] = Nil
match opt {
    Some(v) => { result = Cons(v, Nil) }
    None => {}
}
```

**Discovered in:** `examples/kira_dash.ki` — `record_check` function used `let new_latencies = match latency_ms(result) { ... }`.
