# Kira JSON Project: std.bytes Migration Guide

This document provides instructions for updating the kira-json project to use the new `std.bytes` module for handling untrusted input data.

## Background

Kira now has a `std.bytes` module that provides:
- Safe handling of untrusted byte data (files, network, etc.)
- UTF-8 validation at boundaries with detailed error reporting
- Conversion between bytes and strings with explicit validation

This is the recommended way to handle external input before parsing as JSON.

## API Reference

### std.bytes Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `std.bytes.new()` | `() -> Bytes` | Create empty Bytes |
| `std.bytes.from_string(s)` | `(string) -> Bytes` | Convert validated string to Bytes |
| `std.bytes.to_string(b)` | `(Bytes) -> Result[string, ByteError]` | Validate UTF-8 and convert |
| `std.bytes.length(b)` | `(Bytes) -> i64` | Get byte count |
| `std.bytes.get(b, i)` | `(Bytes, i64) -> Option[i64]` | Get byte at index (0-255) |
| `std.bytes.slice(b, start, end)` | `(Bytes, i64, i64) -> Option[Bytes]` | Extract byte slice |
| `std.bytes.concat(b1, b2)` | `(Bytes, Bytes) -> Bytes` | Concatenate two Bytes |
| `std.bytes.from_array(arr)` | `(Array[i64]) -> Bytes` | Create from byte values (0-255) |
| `std.bytes.to_array(b)` | `(Bytes) -> Array[i64]` | Convert to array of byte values |
| `std.bytes.is_empty(b)` | `(Bytes) -> bool` | Check if empty |

### ByteError Record

When `to_string` fails, it returns an error record:
```kira
{ kind: string, position: i64 }
```

Error kinds:
- `"InvalidStartByte"` - Invalid UTF-8 start byte at position
- `"TruncatedSequence"` - Incomplete UTF-8 sequence at position
- `"InvalidContinuationByte"` - Invalid continuation byte at position

## Migration Tasks

### 1. Update JSON Parser Input Handling

**Before** (if accepting raw strings from files):
```kira
fn parse_json(input: string) -> Result[JsonValue, ParseError] {
    // Assumes input is valid UTF-8
    // ...
}
```

**After** (validate at boundary):
```kira
fn parse_json_bytes(input: Bytes) -> Result[JsonValue, ParseError] {
    match std.bytes.to_string(input) {
        Ok(s) => { parse_json_string(s) }
        Err(e) => { Err(ParseError.InvalidUtf8(e.position)) }
    }
}

fn parse_json_string(input: string) -> Result[JsonValue, ParseError] {
    // Input is guaranteed valid UTF-8
    // ...
}
```

### 2. Add Bytes-Based Entry Points

If kira-json has file reading functionality, add bytes-aware versions:

```kira
// Read and parse JSON from file
effect fn parse_json_file(path: string) -> Result[JsonValue, JsonError] {
    match std.fs.read_file(path) {
        Ok(content) => {
            let bytes: Bytes = std.bytes.from_string(content)
            parse_json_bytes(bytes)
        }
        Err(e) => { Err(JsonError.FileError(e)) }
    }
}
```

### 3. Update Error Types

Add UTF-8 validation errors to your error type:

```kira
type JsonError =
    | ParseError(string)
    | InvalidUtf8(i64)      // Position of invalid byte
    | FileError(string)
    | UnexpectedEof
```

### 4. Handle Byte-Level Operations (if needed)

For JSON parsers that need byte-level access (e.g., for escape sequences):

```kira
// Check for specific byte patterns
fn is_escape_sequence(bytes: Bytes, pos: i64) -> bool {
    match std.bytes.get(bytes, pos) {
        Some(b) => { b == 92 }  // backslash = 92
        None => { false }
    }
}

// Extract a slice for processing
fn extract_string_content(bytes: Bytes, start: i64, end: i64) -> Option[Bytes] {
    std.bytes.slice(bytes, start, end)
}
```

### 5. Testing Recommendations

Add tests for:

1. **Valid UTF-8 input**
```kira
let input: Bytes = std.bytes.from_string("{\"key\": \"value\"}")
// Should parse successfully
```

2. **Invalid UTF-8 input**
```kira
let invalid: Bytes = std.bytes.from_array([123, 34, 0x80, 34, 125])  // { " <invalid> " }
match parse_json_bytes(invalid) {
    Ok(_) => { std.assert.fail("Should have failed") }
    Err(e) => {
        // Verify error includes position info
        std.assert.equal(2, e.position)
    }
}
```

3. **Empty input**
```kira
let empty: Bytes = std.bytes.new()
// Should return appropriate error
```

4. **Unicode in JSON strings**
```kira
let unicode: Bytes = std.bytes.from_string("{\"emoji\": \"😀\"}")
// Should parse correctly, emoji is valid UTF-8
```

## Example: Complete Parse Function

```kira
type JsonValue =
    | JsonNull
    | JsonBool(bool)
    | JsonNumber(f64)
    | JsonString(string)
    | JsonArray(Array[JsonValue])
    | JsonObject(Map[string, JsonValue])

type ParseError =
    | InvalidUtf8(i64)
    | UnexpectedToken(string, i64)
    | UnexpectedEof
    | InvalidNumber(i64)
    | InvalidEscape(i64)

fn parse(input: Bytes) -> Result[JsonValue, ParseError] {
    // Validate UTF-8 at the boundary
    match std.bytes.to_string(input) {
        Ok(s) => { parse_string(s, 0).map(fn(r) => r.0) }
        Err(e) => { Err(ParseError.InvalidUtf8(e.position)) }
    }
}

// Internal parsing on validated string
fn parse_string(input: string, pos: i64) -> Result[(JsonValue, i64), ParseError] {
    // ... parsing implementation
    // Can safely use std.string functions - input is valid UTF-8
}
```

## Checklist

- [ ] Add `Bytes` type annotations where needed
- [ ] Update entry points to accept `Bytes` or provide `Bytes` variants
- [ ] Add `InvalidUtf8` to error types with position info
- [ ] Validate UTF-8 at input boundaries using `std.bytes.to_string`
- [ ] Add tests for invalid UTF-8 input
- [ ] Update documentation to mention UTF-8 validation
- [ ] Consider adding convenience functions that accept strings directly (for REPL use)

## Notes

- The `Bytes` type is represented as a record internally, but should be treated as opaque
- All byte values from `get` and `to_array` are in range 0-255 (returned as `i64`)
- `from_array` will fail if any value is outside 0-255 range
- Position values in errors are byte offsets, not codepoint indices
