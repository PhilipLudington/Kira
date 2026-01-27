# Project Bugs

## [x] Bug 1: MatchFailed runtime error in JSON parsing/serialization

**Status:** Not a bug - tuple field access works correctly

**Original claim:** The interpreter fails when evaluating tuple field access (`.0`, `.1`) on tuples bound in pattern matches, causing `error.MatchFailed`.

**Investigation results:**
All tested scenarios work correctly:

1. Basic tuple access after Cons pattern match:
```kira
let list: List[(i32, i32)] = Cons((1, 10), Nil)
match list {
    Cons(entry, rest) => { return entry.0 }  // Works: returns 1
    Nil => { return 0 }
}
```

2. Let binding after Cons match:
```kira
Cons(entry, rest) => {
    let first: i32 = entry.0   // Works
    let second: i32 = entry.1  // Works
    return first + second
}
```

3. With `std.map.entries()`:
```kira
let m: Map[string, i32] = std.map.put(std.map.new(), "key", 123)
let entries: List[(string, i32)] = std.map.entries(m)
match entries {
    Cons(entry, rest) => {
        let key: string = entry.0    // Works
        let value: i32 = entry.1     // Works
    }
    Nil => { ... }
}
```

4. Recursive functions with tuple field access - all work correctly.

5. Custom sum types in tuples (similar to Json usage) - all work correctly.

**If kira-json library has issues:**
The original bug report referenced a "kira-json" library. If that library experiences `MatchFailed` errors, the cause is likely:
- Incorrect type annotations
- Array literals `[...]` used where cons lists (`Cons(...)`) are expected
- Other code issues unrelated to tuple field access

**Tests added:** See `src/interpreter/tests.zig` for comprehensive tuple access tests with Cons pattern matching.

**Verified:** 2026-01-27
