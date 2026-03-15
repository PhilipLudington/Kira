# Kira Bugs

## [x] Bug 1: Match-as-expression produces broken runtime values

**Status:** Fixed

**Resolution:** The parser now rejects `match` in expression position with a clear error message: `'match' cannot be used as an expression; use a variable with assignment inside match arms instead`. This aligns with Kira's "no surprises" philosophy — no implicit returns, no expression-vs-statement ambiguity. `match` is a statement, not an expression.

**Correct pattern:**
```kira
var result: List[i64] = Nil
match opt {
    Some(v) => { result = Cons(v, Nil) }
    None => {}
}
```

**Discovered in:** `examples/kira_dash.ki` — `record_check` function used `let new_latencies = match latency_ms(result) { ... }`.
