//! std.bytes - Byte array operations for the Kira standard library.
//!
//! Handles untrusted byte data with UTF-8 validation at boundaries.
//! Use this module when working with raw bytes from files, network, etc.
//! Convert to string with to_string() which validates UTF-8.
//!
//! Provides operations on Bytes:
//!   - new: Create empty Bytes
//!   - from_string: Convert validated string to Bytes
//!   - to_string: Validate UTF-8 and convert to string (returns Result)
//!   - length: Get byte count
//!   - get: Get byte at index (returns Option)
//!   - slice: Extract byte slice (returns Option)
//!   - concat: Concatenate two Bytes
//!   - from_array: Create from array of integers
//!   - to_array: Convert to array of integers
//!   - is_empty: Check if empty

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Bytes type marker
const bytes_type_name = "Bytes";

/// Create the std.bytes module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "new", root.makeBuiltin("new", &bytesNew));
    try fields.put(allocator, "from_string", root.makeBuiltin("from_string", &bytesFromString));
    try fields.put(allocator, "to_string", root.makeBuiltin("to_string", &bytesToString));
    try fields.put(allocator, "length", root.makeBuiltin("length", &bytesLength));
    try fields.put(allocator, "get", root.makeBuiltin("get", &bytesGet));
    try fields.put(allocator, "slice", root.makeBuiltin("slice", &bytesSlice));
    try fields.put(allocator, "concat", root.makeBuiltin("concat", &bytesConcat));
    try fields.put(allocator, "from_array", root.makeBuiltin("from_array", &bytesFromArray));
    try fields.put(allocator, "to_array", root.makeBuiltin("to_array", &bytesToArray));
    try fields.put(allocator, "is_empty", root.makeBuiltin("is_empty", &bytesIsEmpty));

    return Value{
        .record = .{
            .type_name = "std.bytes",
            .fields = fields,
        },
    };
}

// ============================================================================
// Helper functions
// ============================================================================

/// Check if a value is a Bytes record
fn isBytes(val: Value) bool {
    return switch (val) {
        .record => |r| if (r.type_name) |name| std.mem.eql(u8, name, bytes_type_name) else false,
        else => false,
    };
}

/// Get the raw data from a Bytes record
fn getData(bytes: Value) ?[]const u8 {
    const record = switch (bytes) {
        .record => |r| r,
        else => return null,
    };
    const data_val = record.fields.get("_data") orelse return null;
    return switch (data_val) {
        .string => |s| s,
        else => null,
    };
}

/// Create a Bytes record from raw data
fn makeBytes(allocator: Allocator, data: []const u8) InterpreterError!Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(allocator, "_data", Value{ .string = data }) catch return error.OutOfMemory;
    fields.put(allocator, "_type", Value{ .string = bytes_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = bytes_type_name,
            .fields = fields,
        },
    };
}

/// Create a ByteError record with kind and position
fn makeByteError(allocator: Allocator, kind: []const u8, position: usize) InterpreterError!Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(allocator, "kind", Value{ .string = kind }) catch return error.OutOfMemory;
    fields.put(allocator, "position", Value{ .integer = @intCast(position) }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = "ByteError",
            .fields = fields,
        },
    };
}

/// Create an Ok value
fn makeOk(allocator: Allocator, value: Value) InterpreterError!Value {
    const ok_val = allocator.create(Value) catch return error.OutOfMemory;
    ok_val.* = value;
    return Value{ .ok = ok_val };
}

/// Create an Err value
fn makeErr(allocator: Allocator, value: Value) InterpreterError!Value {
    const err_val = allocator.create(Value) catch return error.OutOfMemory;
    err_val.* = value;
    return Value{ .err = err_val };
}

/// Create a Some value
fn makeSome(allocator: Allocator, value: Value) InterpreterError!Value {
    const inner = allocator.create(Value) catch return error.OutOfMemory;
    inner.* = value;
    return Value{ .some = inner };
}

// ============================================================================
// Builtin implementations
// ============================================================================

/// Create a new empty Bytes: new() -> Bytes
fn bytesNew(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 0) return error.ArityMismatch;
    return makeBytes(ctx.allocator, "");
}

/// Convert string to Bytes: from_string(str) -> Bytes
fn bytesFromString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return makeBytes(ctx.allocator, str);
}

/// Validate UTF-8 and convert to string: to_string(bytes) -> Result[string, ByteError]
fn bytesToString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    if (!isBytes(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    // Validate UTF-8 using Utf8View.init (validates, unlike initUnchecked)
    _ = std.unicode.Utf8View.init(data) catch {
        // Find the exact error position
        var pos: usize = 0;
        while (pos < data.len) {
            const len = std.unicode.utf8ByteSequenceLength(data[pos]) catch {
                // Invalid start byte
                const err_record = try makeByteError(ctx.allocator, "InvalidStartByte", pos);
                return makeErr(ctx.allocator, err_record);
            };

            if (pos + len > data.len) {
                // Truncated sequence
                const err_record = try makeByteError(ctx.allocator, "TruncatedSequence", pos);
                return makeErr(ctx.allocator, err_record);
            }

            // Check continuation bytes
            _ = std.unicode.utf8Decode(data[pos..][0..len]) catch {
                const err_record = try makeByteError(ctx.allocator, "InvalidContinuationByte", pos);
                return makeErr(ctx.allocator, err_record);
            };

            pos += len;
        }

        // Fallback (should not reach here, but just in case)
        const err_record = try makeByteError(ctx.allocator, "InvalidUtf8", 0);
        return makeErr(ctx.allocator, err_record);
    };

    // UTF-8 is valid, return Ok(string)
    return makeOk(ctx.allocator, Value{ .string = data });
}

/// Get byte count: length(bytes) -> i64
fn bytesLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    if (!isBytes(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    return Value{ .integer = @intCast(data.len) };
}

/// Get byte at index: get(bytes, index) -> Option[i64]
fn bytesGet(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isBytes(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    const index_raw = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    if (index_raw < 0 or index_raw > std.math.maxInt(usize)) return Value{ .none = {} };
    const index: usize = @intCast(index_raw);

    if (index >= data.len) return Value{ .none = {} };

    return makeSome(ctx.allocator, Value{ .integer = @intCast(data[index]) });
}

/// Extract byte slice: slice(bytes, start, end) -> Option[Bytes]
fn bytesSlice(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    if (!isBytes(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    const start_raw = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const end_raw = switch (args[2]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // Bounds checking
    if (start_raw < 0 or end_raw < 0) return Value{ .none = {} };
    if (start_raw > std.math.maxInt(usize) or end_raw > std.math.maxInt(usize)) return Value{ .none = {} };
    const start: usize = @intCast(start_raw);
    const end: usize = @intCast(end_raw);

    if (start > end or end > data.len) return Value{ .none = {} };

    const sliced = try makeBytes(ctx.allocator, data[start..end]);
    return makeSome(ctx.allocator, sliced);
}

/// Concatenate two Bytes: concat(bytes1, bytes2) -> Bytes
fn bytesConcat(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isBytes(args[0])) return error.TypeMismatch;
    const data1 = getData(args[0]) orelse return error.TypeMismatch;

    if (!isBytes(args[1])) return error.TypeMismatch;
    const data2 = getData(args[1]) orelse return error.TypeMismatch;

    const result = ctx.allocator.alloc(u8, data1.len + data2.len) catch return error.OutOfMemory;
    @memcpy(result[0..data1.len], data1);
    @memcpy(result[data1.len..], data2);

    return makeBytes(ctx.allocator, result);
}

/// Create Bytes from array of integers: from_array(array) -> Bytes
fn bytesFromArray(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const arr = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const result = ctx.allocator.alloc(u8, arr.len) catch return error.OutOfMemory;

    for (arr, 0..) |elem, i| {
        const byte_val = switch (elem) {
            .integer => |n| n,
            else => return error.TypeMismatch,
        };

        // Ensure value is in byte range (0-255)
        if (byte_val < 0 or byte_val > 255) return error.InvalidOperation;
        result[i] = @intCast(byte_val);
    }

    return makeBytes(ctx.allocator, result);
}

/// Convert Bytes to array of integers: to_array(bytes) -> Array[i64]
fn bytesToArray(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    if (!isBytes(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    const arr = ctx.allocator.alloc(Value, data.len) catch return error.OutOfMemory;
    for (data, 0..) |byte, i| {
        arr[i] = Value{ .integer = @intCast(byte) };
    }

    return Value{ .array = arr };
}

/// Check if Bytes is empty: is_empty(bytes) -> bool
fn bytesIsEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    if (!isBytes(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    return Value{ .boolean = data.len == 0 };
}

// ============================================================================
// Tests
// ============================================================================

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
        .env_args = null,
    };
}

test "bytes new and is_empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const bytes = try bytesNew(ctx, &.{});
    try std.testing.expect(isBytes(bytes));

    const is_empty = try bytesIsEmpty(ctx, &.{bytes});
    try std.testing.expect(is_empty.boolean);
}

test "bytes from_string and length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const bytes = try bytesFromString(ctx, &.{Value{ .string = "hello" }});
    try std.testing.expect(isBytes(bytes));

    const len = try bytesLength(ctx, &.{bytes});
    try std.testing.expectEqual(@as(i128, 5), len.integer);

    const not_empty = try bytesIsEmpty(ctx, &.{bytes});
    try std.testing.expect(!not_empty.boolean);
}

test "bytes to_string valid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const bytes = try bytesFromString(ctx, &.{Value{ .string = "hello world" }});
    const result = try bytesToString(ctx, &.{bytes});

    try std.testing.expect(result == .ok);
    try std.testing.expectEqualStrings("hello world", result.ok.*.string);
}

test "bytes to_string valid UTF-8 multibyte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // UTF-8 string: "héllo" (é is 2 bytes)
    const bytes = try bytesFromString(ctx, &.{Value{ .string = "héllo" }});
    const result = try bytesToString(ctx, &.{bytes});

    try std.testing.expect(result == .ok);
    try std.testing.expectEqualStrings("héllo", result.ok.*.string);
}

test "bytes to_string invalid UTF-8 start byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // Create bytes with invalid UTF-8 (0x80 is invalid start byte)
    const invalid_bytes = try bytesFromArray(ctx, &.{Value{ .array = &[_]Value{
        Value{ .integer = 0x80 },
    } }});

    const result = try bytesToString(ctx, &.{invalid_bytes});
    try std.testing.expect(result == .err);

    const err_record = result.err.*.record;
    const kind = err_record.fields.get("kind").?.string;
    const pos = err_record.fields.get("position").?.integer;

    try std.testing.expectEqualStrings("InvalidStartByte", kind);
    try std.testing.expectEqual(@as(i128, 0), pos);
}

test "bytes to_string invalid UTF-8 truncated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // Create bytes with truncated UTF-8 sequence (0xC3 starts 2-byte seq)
    const invalid_bytes = try bytesFromArray(ctx, &.{Value{ .array = &[_]Value{
        Value{ .integer = 0xC3 }, // Start of 2-byte sequence
        // Missing continuation byte
    } }});

    const result = try bytesToString(ctx, &.{invalid_bytes});
    try std.testing.expect(result == .err);

    const err_record = result.err.*.record;
    const kind = err_record.fields.get("kind").?.string;

    try std.testing.expectEqualStrings("TruncatedSequence", kind);
}

test "bytes get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const bytes = try bytesFromString(ctx, &.{Value{ .string = "abc" }});

    // Get first byte
    const first = try bytesGet(ctx, &.{ bytes, Value{ .integer = 0 } });
    try std.testing.expect(first == .some);
    try std.testing.expectEqual(@as(i128, 'a'), first.some.*.integer);

    // Get last byte
    const last = try bytesGet(ctx, &.{ bytes, Value{ .integer = 2 } });
    try std.testing.expect(last == .some);
    try std.testing.expectEqual(@as(i128, 'c'), last.some.*.integer);

    // Out of bounds
    const oob = try bytesGet(ctx, &.{ bytes, Value{ .integer = 10 } });
    try std.testing.expect(oob == .none);

    // Negative index
    const neg = try bytesGet(ctx, &.{ bytes, Value{ .integer = -1 } });
    try std.testing.expect(neg == .none);
}

test "bytes slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const bytes = try bytesFromString(ctx, &.{Value{ .string = "hello world" }});

    // Valid slice
    const sliced = try bytesSlice(ctx, &.{ bytes, Value{ .integer = 0 }, Value{ .integer = 5 } });
    try std.testing.expect(sliced == .some);
    const sliced_data = getData(sliced.some.*).?;
    try std.testing.expectEqualStrings("hello", sliced_data);

    // Out of bounds
    const oob = try bytesSlice(ctx, &.{ bytes, Value{ .integer = 0 }, Value{ .integer = 100 } });
    try std.testing.expect(oob == .none);

    // Negative index
    const neg = try bytesSlice(ctx, &.{ bytes, Value{ .integer = -1 }, Value{ .integer = 5 } });
    try std.testing.expect(neg == .none);

    // Start > end
    const invalid = try bytesSlice(ctx, &.{ bytes, Value{ .integer = 5 }, Value{ .integer = 2 } });
    try std.testing.expect(invalid == .none);
}

test "bytes concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const bytes1 = try bytesFromString(ctx, &.{Value{ .string = "hello" }});
    const bytes2 = try bytesFromString(ctx, &.{Value{ .string = " world" }});

    const result = try bytesConcat(ctx, &.{ bytes1, bytes2 });
    try std.testing.expect(isBytes(result));

    const data = getData(result).?;
    try std.testing.expectEqualStrings("hello world", data);
}

test "bytes from_array and to_array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // Create from array
    const arr = &[_]Value{
        Value{ .integer = 72 }, // H
        Value{ .integer = 105 }, // i
    };
    const bytes = try bytesFromArray(ctx, &.{Value{ .array = arr }});
    try std.testing.expect(isBytes(bytes));

    const data = getData(bytes).?;
    try std.testing.expectEqualStrings("Hi", data);

    // Convert back to array
    const arr_result = try bytesToArray(ctx, &.{bytes});
    try std.testing.expect(arr_result == .array);
    try std.testing.expectEqual(@as(usize, 2), arr_result.array.len);
    try std.testing.expectEqual(@as(i128, 72), arr_result.array[0].integer);
    try std.testing.expectEqual(@as(i128, 105), arr_result.array[1].integer);
}

test "bytes from_array out of range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // Value > 255 should fail
    const arr_high = &[_]Value{Value{ .integer = 256 }};
    try std.testing.expectError(error.InvalidOperation, bytesFromArray(ctx, &.{Value{ .array = arr_high }}));

    // Negative value should fail
    const arr_neg = &[_]Value{Value{ .integer = -1 }};
    try std.testing.expectError(error.InvalidOperation, bytesFromArray(ctx, &.{Value{ .array = arr_neg }}));
}
