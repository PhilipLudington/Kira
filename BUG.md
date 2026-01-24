# Bug: Standard Library Module Resolution Broken After Package System Update

## Summary

After updating the compiler to add the package system, `std.time` and `std.parallel` modules fail at runtime with `error.FieldNotFound`.

## Reproduction

```kira
module test

effect fn main() -> void {
    let start: i64 = std.time.now_ms()
    print(std.string.from_i64(start))
    return
}
```

Run with: `kira run test.ki`

## Expected Behavior

Should print the current timestamp in milliseconds.

## Actual Behavior

```
Runtime error: error.FieldNotFound
Error: error.RuntimeError
```

## Affected Functions

- `std.time.now_ms()` - Returns `error.FieldNotFound`
- `std.parallel.map()` - Returns `error.FieldNotFound`

## Working Functions

These standard library functions still work correctly:
- `std.list.map()`, `std.list.fold()`, `std.list.filter()`, `std.list.foreach()`, etc.
- `std.string.concat()`, `std.string.from_i32()`, `std.string.from_i64()`, etc.
- `print()`

## Environment

- Occurred after compiler update adding package system
- Test file: `examples/std_lib_test.ki`

## Workarounds Applied

The following workarounds were applied to `kira_test` to keep tests passing:

### runners.ki

1. **Lines 228-245** (`run_test_timed`): Replaced `std.time.now_ms()` with hardcoded `0`
2. **Lines 260-272** (`run_test_timed_with_hooks`): Same
3. **Lines 332-425** (parallel runners): Replaced `std.parallel.map()` with sequential `std.list.map()` and recursive helpers

### reporters.ki

1. **Lines 151-177** (`run_and_report_parallel_timed`): Removed `std.time.now_ms()` calls, hardcoded `0`

## Notes

The error `FieldNotFound` suggests the module/field lookup for `std.time` and `std.parallel` is failing, while other `std.*` modules resolve correctly. This may indicate these specific modules aren't being registered properly in the new package system.
