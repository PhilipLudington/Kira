# Bug: Kira Runtime Panics on Invalid UTF-8 Input

## Status: FIXED

**Fixed in commit**: 8075771

## Summary

~~The Kira runtime panics when processing strings containing invalid UTF-8 bytes, preventing graceful error handling of malformed input.~~

**FIXED**: String functions now validate UTF-8 and return `Result` types with `Err("InvalidUtf8")` instead of panicking.

## Severity

~~**High** - Causes unrecoverable runtime crash instead of returning an error.~~

**Resolved** - Invalid UTF-8 input now returns an error that can be handled gracefully.

## Reproduction

Any file containing invalid UTF-8 bytes will trigger this when read and processed:

```kira
effect fn main() -> IO[void] {
    // Read a file containing invalid UTF-8 (e.g., raw 0x80 byte)
    match std.fs.read_file("file_with_invalid_utf8.txt") {
        Ok(content) => {
            // This line crashes the runtime:
            let len: i32 = std.string.length(content)
            std.io.println(std.int.to_string(len))
        }
        Err(e) => {
            std.io.println(e)
        }
    }
    return
}
```

**Error:**
```
thread panic: attempt to unwrap error: Utf8InvalidStartByte
```

## Root Cause

In `src/stdlib/string.zig`, the `stringLength` function uses Zig's UTF-8 iterator which panics on invalid sequences:

```zig
fn stringLength(ctx: builinContext, args: []const Value) InterpreterError!Value {
    // ...
    var iter = std.unicode.Utf8Iterator{ .bytes = s };
    while (iter.nextCodepoint()) |_| {  // Panics on invalid UTF-8
        len += 1;
    }
    // ...
}
```

The same issue likely affects other string functions: `std.string.chars`, `std.string.substring`, etc.

## Impact

This bug prevents:
1. **Graceful error handling** - Programs cannot catch and handle invalid input
2. **Security validation** - Cannot reject malformed input safely
3. **Testing** - Cannot test parser behavior on invalid UTF-8 (25 JSONTestSuite tests skipped)

### Affected JSONTestSuite Files (25)

```
i_string_UTF-8_invalid_sequence.json
i_string_invalid_utf-8.json
i_string_iso_latin_1.json
i_string_lone_utf8_continuation_byte.json
i_string_not_in_unicode_range.json
i_string_overlong_sequence_2_bytes.json
i_string_overlong_sequence_6_bytes.json
i_string_overlong_sequence_6_bytes_null.json
i_string_truncated-utf-8.json
i_string_UTF-16LE_with_BOM.json
i_string_UTF8_surrogate_U+D800.json
i_string_utf16BE_no_BOM.json
i_string_utf16LE_no_BOM.json
n_array_a_invalid_utf8.json
n_array_invalid_utf8.json
n_number_invalid-utf-8-in-bigger-int.json
n_number_invalid-utf-8-in-exponent.json
n_number_invalid-utf-8-in-int.json
n_number_real_with_invalid_utf8_after_e.json
n_object_lone_continuation_byte_in_key_and_trailing_comma.json
n_string_invalid-utf-8-in-escape.json
n_string_invalid_utf8_after_escape.json
n_structure_incomplete_UTF8_BOM.json
n_structure_lone-invalid-utf-8.json
n_structure_single_eacute.json
```

## Proposed Fix

### Option A: Return Error (Recommended)

String functions should return `Result[T, StringError]` or handle invalid UTF-8 gracefully:

```zig
fn stringLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    const s = switch (args[0]) {
        .string => |str| str,
        else => return error.TypeMismatch,
    };

    var len: i32 = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = s };
    while (true) {
        const codepoint = iter.nextCodepoint() catch {
            // Return error instead of panicking
            return makeError(ctx.allocator, "InvalidUtf8");
        };
        if (codepoint == null) break;
        len += 1;
    }
    return Value{ .integer = len };
}
```

### Option B: Add Validation Function

Add `std.string.is_valid_utf8(s) -> bool` so users can check before processing:

```kira
effect fn safe_process(content: string) -> IO[void] {
    if not std.string.is_valid_utf8(content) {
        std.io.println("Invalid UTF-8 input")
        return
    }
    // Safe to process
    let len: i32 = std.string.length(content)
    // ...
}
```

### Option C: Add Byte-Level API

Add `std.fs.read_file_bytes(path) -> Result[List[u8], string]` for raw byte access:

```kira
effect fn handle_raw(path: string) -> IO[void] {
    match std.fs.read_file_bytes(path) {
        Ok(bytes) => {
            // Process raw bytes, validate UTF-8 manually
        }
        Err(e) => { ... }
    }
}
```

## Workaround

Currently, the only workaround is to skip files known to contain invalid UTF-8:

```kira
let should_skip_file: fn(string) -> bool = fn(filename: string) -> bool {
    if std.string.contains(filename, "invalid_utf") { return true }
    if std.string.contains(filename, "invalid-utf") { return true }
    // ... etc
    return false
}
```

This is unsatisfactory because it requires knowing which files are problematic in advance.

## References

- JSONTestSuite: https://github.com/nst/JSONTestSuite
- Kira stdlib implementation: `~/Fun/Kira/src/stdlib/string.zig`
- Test file demonstrating issue: `tests/test_json_testsuite.ki`

---

## Implemented Fix

**Option A was implemented**: String functions now return `Result` types with proper error handling.

### API Changes

The following functions now return `Result[T, string]` instead of `T` directly:

| Function | Old Return Type | New Return Type |
|----------|----------------|-----------------|
| `std.string.length(str)` | `int` | `Result[int, string]` |
| `std.string.substring(str, start, end)` | `string` | `Result[string, string]` |
| `std.string.char_at(str, index)` | `Option[char]` | `Result[Option[char], string]` |
| `std.string.index_of(str, substr)` | `Option[int]` | `Result[Option[int], string]` |
| `std.string.chars(str)` | `List[char]` | `Result[List[char], string]` |

### New Functions Added

- `std.string.is_valid_utf8(str) -> bool` - Check if string is valid UTF-8
- `std.string.byte_length(str) -> int` - Get byte count (works on any string)

### Usage Example

```kira
effect fn safe_process(content: string) -> IO[void] {
    // Option 1: Check first with is_valid_utf8
    if not std.string.is_valid_utf8(content) {
        std.io.println("Invalid UTF-8 input")
        return
    }

    // Option 2: Handle Result from string functions
    match std.string.length(content) {
        Ok(len) => std.io.println("Length: " ++ std.int.to_string(len))
        Err(e) => std.io.println("Error: " ++ e)
    }
}
```

### Implementation Details

Changed `Utf8View.initUnchecked()` to `Utf8View.init()` which validates UTF-8 and returns an error on invalid sequences. Error handling uses Kira-level `Result` types (`Ok`/`Err` values) rather than Zig-level panics.
