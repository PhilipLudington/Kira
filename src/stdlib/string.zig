//! std.string - String operations for the Kira standard library.
//!
//! Provides operations on strings:
//!   - length: Get string length
//!   - split: Split by delimiter
//!   - trim: Remove whitespace
//!   - concat: Concatenate strings
//!   - contains: Check for substring
//!   - starts_with, ends_with: Check prefix/suffix

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;

/// Create the std.string module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "length", root.makeBuiltin("length", &stringLength));
    try fields.put(allocator, "split", root.makeBuiltin("split", &stringSplit));
    try fields.put(allocator, "trim", root.makeBuiltin("trim", &stringTrim));
    try fields.put(allocator, "concat", root.makeBuiltin("concat", &stringConcat));
    try fields.put(allocator, "contains", root.makeBuiltin("contains", &stringContains));
    try fields.put(allocator, "starts_with", root.makeBuiltin("starts_with", &stringStartsWith));
    try fields.put(allocator, "ends_with", root.makeBuiltin("ends_with", &stringEndsWith));

    // Additional string functions
    try fields.put(allocator, "to_upper", root.makeBuiltin("to_upper", &stringToUpper));
    try fields.put(allocator, "to_lower", root.makeBuiltin("to_lower", &stringToLower));
    try fields.put(allocator, "replace", root.makeBuiltin("replace", &stringReplace));
    try fields.put(allocator, "substring", root.makeBuiltin("substring", &stringSubstring));
    try fields.put(allocator, "char_at", root.makeBuiltin("char_at", &stringCharAt));
    try fields.put(allocator, "index_of", root.makeBuiltin("index_of", &stringIndexOf));
    try fields.put(allocator, "equals", root.makeBuiltin("equals", &stringEquals));

    return Value{
        .record = .{
            .type_name = "std.string",
            .fields = fields,
        },
    };
}

/// Get string length: length(str) -> int
fn stringLength(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .integer = @intCast(str.len) };
}

/// Split string by delimiter: split(str, delim) -> array of strings
fn stringSplit(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const delim = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    var parts = std.ArrayListUnmanaged(Value){};
    errdefer parts.deinit(allocator);

    var iter = std.mem.splitSequence(u8, str, delim);
    while (iter.next()) |part| {
        parts.append(allocator, Value{ .string = part }) catch return error.OutOfMemory;
    }

    return Value{ .array = parts.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

/// Trim whitespace: trim(str) -> str
fn stringTrim(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .string = std.mem.trim(u8, str, " \t\n\r") };
}

/// Concatenate strings: concat(str1, str2) -> str
fn stringConcat(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const str1 = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const str2 = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = allocator.alloc(u8, str1.len + str2.len) catch return error.OutOfMemory;
    @memcpy(result[0..str1.len], str1);
    @memcpy(result[str1.len..], str2);

    return Value{ .string = result };
}

/// Check for substring: contains(str, substr) -> bool
fn stringContains(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const haystack = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const needle = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .boolean = std.mem.indexOf(u8, haystack, needle) != null };
}

/// Check prefix: starts_with(str, prefix) -> bool
fn stringStartsWith(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const prefix = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .boolean = std.mem.startsWith(u8, str, prefix) };
}

/// Check suffix: ends_with(str, suffix) -> bool
fn stringEndsWith(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const suffix = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .boolean = std.mem.endsWith(u8, str, suffix) };
}

/// Convert to uppercase: to_upper(str) -> str
fn stringToUpper(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = allocator.alloc(u8, str.len) catch return error.OutOfMemory;
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }

    return Value{ .string = result };
}

/// Convert to lowercase: to_lower(str) -> str
fn stringToLower(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = allocator.alloc(u8, str.len) catch return error.OutOfMemory;
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }

    return Value{ .string = result };
}

/// Replace all occurrences: replace(str, old, new) -> str
fn stringReplace(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const old = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const new = switch (args[2]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (old.len == 0) return Value{ .string = str };

    // Count occurrences
    var count: usize = 0;
    var i: usize = 0;
    while (i <= str.len - old.len) {
        if (std.mem.eql(u8, str[i .. i + old.len], old)) {
            count += 1;
            i += old.len;
        } else {
            i += 1;
        }
    }

    if (count == 0) return Value{ .string = str };

    // Allocate result
    const new_len = str.len - (count * old.len) + (count * new.len);
    const result = allocator.alloc(u8, new_len) catch return error.OutOfMemory;

    // Build result
    var src_idx: usize = 0;
    var dst_idx: usize = 0;
    while (src_idx < str.len) {
        if (src_idx <= str.len - old.len and std.mem.eql(u8, str[src_idx .. src_idx + old.len], old)) {
            @memcpy(result[dst_idx .. dst_idx + new.len], new);
            dst_idx += new.len;
            src_idx += old.len;
        } else {
            result[dst_idx] = str[src_idx];
            dst_idx += 1;
            src_idx += 1;
        }
    }

    return Value{ .string = result };
}

/// Get substring: substring(str, start, end) -> str
fn stringSubstring(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const start_raw = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const end_raw = switch (args[2]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    if (start_raw < 0 or end_raw < 0) return error.IndexOutOfBounds;
    const start: usize = @intCast(start_raw);
    const end: usize = @intCast(end_raw);

    if (start > str.len or end > str.len or start > end) return error.IndexOutOfBounds;

    return Value{ .string = str[start..end] };
}

/// Get character at index: char_at(str, index) -> Option[char]
fn stringCharAt(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const index_raw = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    if (index_raw < 0) return Value{ .none = {} };
    const index: usize = @intCast(index_raw);

    if (index >= str.len) return Value{ .none = {} };

    const inner = allocator.create(Value) catch return error.OutOfMemory;
    inner.* = Value{ .char = str[index] };
    return Value{ .some = inner };
}

/// Find index of substring: index_of(str, substr) -> Option[int]
fn stringIndexOf(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const haystack = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const needle = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (std.mem.indexOf(u8, haystack, needle)) |idx| {
        const inner = allocator.create(Value) catch return error.OutOfMemory;
        inner.* = Value{ .integer = @intCast(idx) };
        return Value{ .some = inner };
    }

    return Value{ .none = {} };
}

/// Check if two strings are equal: equals(str1, str2) -> bool
fn stringEquals(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const str1 = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const str2 = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .boolean = std.mem.eql(u8, str1, str2) };
}

// ============================================================================
// Tests
// ============================================================================

test "string length" {
    const allocator = std.testing.allocator;

    const result = try stringLength(allocator, &.{Value{ .string = "hello" }});
    try std.testing.expectEqual(@as(i128, 5), result.integer);

    const empty = try stringLength(allocator, &.{Value{ .string = "" }});
    try std.testing.expectEqual(@as(i128, 0), empty.integer);
}

test "string contains" {
    const allocator = std.testing.allocator;

    const yes = try stringContains(allocator, &.{ Value{ .string = "hello world" }, Value{ .string = "world" } });
    try std.testing.expect(yes.boolean);

    const no = try stringContains(allocator, &.{ Value{ .string = "hello" }, Value{ .string = "world" } });
    try std.testing.expect(!no.boolean);
}

test "string starts_with and ends_with" {
    const allocator = std.testing.allocator;

    const starts = try stringStartsWith(allocator, &.{ Value{ .string = "hello" }, Value{ .string = "hel" } });
    try std.testing.expect(starts.boolean);

    const ends = try stringEndsWith(allocator, &.{ Value{ .string = "hello" }, Value{ .string = "lo" } });
    try std.testing.expect(ends.boolean);
}

test "string trim" {
    const allocator = std.testing.allocator;

    const result = try stringTrim(allocator, &.{Value{ .string = "  hello  " }});
    try std.testing.expectEqualStrings("hello", result.string);
}

test "string concat" {
    const allocator = std.testing.allocator;

    const result = try stringConcat(allocator, &.{ Value{ .string = "hello" }, Value{ .string = " world" } });
    defer allocator.free(result.string);
    try std.testing.expectEqualStrings("hello world", result.string);
}

test "string to_upper and to_lower" {
    const allocator = std.testing.allocator;

    const upper = try stringToUpper(allocator, &.{Value{ .string = "Hello" }});
    defer allocator.free(upper.string);
    try std.testing.expectEqualStrings("HELLO", upper.string);

    const lower = try stringToLower(allocator, &.{Value{ .string = "Hello" }});
    defer allocator.free(lower.string);
    try std.testing.expectEqualStrings("hello", lower.string);
}

test "string substring" {
    const allocator = std.testing.allocator;

    const result = try stringSubstring(allocator, &.{
        Value{ .string = "hello world" },
        Value{ .integer = 0 },
        Value{ .integer = 5 },
    });
    try std.testing.expectEqualStrings("hello", result.string);
}

test "string equals" {
    const allocator = std.testing.allocator;

    const equal = try stringEquals(allocator, &.{ Value{ .string = "hello" }, Value{ .string = "hello" } });
    try std.testing.expect(equal.boolean);

    const not_equal = try stringEquals(allocator, &.{ Value{ .string = "hello" }, Value{ .string = "world" } });
    try std.testing.expect(!not_equal.boolean);

    const empty_equal = try stringEquals(allocator, &.{ Value{ .string = "" }, Value{ .string = "" } });
    try std.testing.expect(empty_equal.boolean);
}
