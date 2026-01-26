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
const BuiltinContext = root.BuiltinContext;

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
    try fields.put(allocator, "chars", root.makeBuiltin("chars", &stringChars));

    // Numeric-to-string conversion functions
    try fields.put(allocator, "from_i32", root.makeBuiltin("from_i32", &stringFromInt));
    try fields.put(allocator, "from_i64", root.makeBuiltin("from_i64", &stringFromInt));
    try fields.put(allocator, "from_int", root.makeBuiltin("from_int", &stringFromInt));
    try fields.put(allocator, "from_f32", root.makeBuiltin("from_f32", &stringFromFloat));
    try fields.put(allocator, "from_f64", root.makeBuiltin("from_f64", &stringFromFloat));
    try fields.put(allocator, "from_float", root.makeBuiltin("from_float", &stringFromFloat));
    try fields.put(allocator, "from_bool", root.makeBuiltin("from_bool", &stringFromBool));
    try fields.put(allocator, "to_string", root.makeBuiltin("to_string", &stringToString));

    // String-to-numeric parsing functions
    try fields.put(allocator, "parse_int", root.makeBuiltin("parse_int", &stringParseInt));

    return Value{
        .record = .{
            .type_name = "std.string",
            .fields = fields,
        },
    };
}

/// Get string length: length(str) -> int
/// Returns the number of Unicode codepoints (not bytes).
fn stringLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Count codepoints, not bytes
    var utf8_view = std.unicode.Utf8View.initUnchecked(str);
    var iter = utf8_view.iterator();
    var count: i64 = 0;
    while (iter.nextCodepoint()) |_| {
        count += 1;
    }

    return Value{ .integer = count };
}

/// Split string by delimiter: split(str, delim) -> array of strings
fn stringSplit(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
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
    errdefer parts.deinit(ctx.allocator);

    var iter = std.mem.splitSequence(u8, str, delim);
    while (iter.next()) |part| {
        parts.append(ctx.allocator, Value{ .string = part }) catch return error.OutOfMemory;
    }

    return Value{ .array = parts.toOwnedSlice(ctx.allocator) catch return error.OutOfMemory };
}

/// Trim whitespace: trim(str) -> str
fn stringTrim(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .string = std.mem.trim(u8, str, " \t\n\r") };
}

/// Concatenate strings: concat(str1, str2) -> str
fn stringConcat(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const str1 = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const str2 = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = ctx.allocator.alloc(u8, str1.len + str2.len) catch return error.OutOfMemory;
    @memcpy(result[0..str1.len], str1);
    @memcpy(result[str1.len..], str2);

    return Value{ .string = result };
}

/// Check for substring: contains(str, substr) -> bool
fn stringContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
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
fn stringStartsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
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
fn stringEndsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
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
fn stringToUpper(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = ctx.allocator.alloc(u8, str.len) catch return error.OutOfMemory;
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }

    return Value{ .string = result };
}

/// Convert to lowercase: to_lower(str) -> str
fn stringToLower(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const result = ctx.allocator.alloc(u8, str.len) catch return error.OutOfMemory;
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }

    return Value{ .string = result };
}

/// Replace all occurrences: replace(str, old, new) -> str
fn stringReplace(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
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
    const result = ctx.allocator.alloc(u8, new_len) catch return error.OutOfMemory;

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
/// Indices are by Unicode codepoint, not by byte.
fn stringSubstring(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
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
    const start_codepoint: usize = @intCast(start_raw);
    const end_codepoint: usize = @intCast(end_raw);

    if (start_codepoint > end_codepoint) return error.IndexOutOfBounds;

    // Convert codepoint indices to byte offsets using UTF-8 iterator
    var utf8_view = std.unicode.Utf8View.initUnchecked(str);
    var iter = utf8_view.iterator();
    var current_codepoint: usize = 0;
    var start_byte: usize = 0;
    var end_byte: usize = str.len;
    var found_start = false;
    var found_end = false;

    while (iter.nextCodepointSlice()) |slice| {
        if (current_codepoint == start_codepoint) {
            start_byte = @intFromPtr(slice.ptr) - @intFromPtr(str.ptr);
            found_start = true;
        }
        if (current_codepoint == end_codepoint) {
            end_byte = @intFromPtr(slice.ptr) - @intFromPtr(str.ptr);
            found_end = true;
            break;
        }
        current_codepoint += 1;
    }

    // Handle edge case: end index equals total codepoint count (end of string)
    if (!found_end and current_codepoint == end_codepoint) {
        end_byte = str.len;
        found_end = true;
    }

    // If start index wasn't found, check if it equals total count (empty substring at end)
    if (!found_start and current_codepoint == start_codepoint) {
        start_byte = str.len;
        found_start = true;
    }

    if (!found_start or (!found_end and end_codepoint != current_codepoint + 1)) {
        return error.IndexOutOfBounds;
    }

    return Value{ .string = str[start_byte..end_byte] };
}

/// Get character at index: char_at(str, index) -> Option[char]
/// Index is by Unicode codepoint, not by byte.
fn stringCharAt(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
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

    // Use UTF-8 iterator to get the index-th codepoint (not byte)
    var utf8_view = std.unicode.Utf8View.initUnchecked(str);
    var iter = utf8_view.iterator();
    var current_idx: usize = 0;
    while (iter.nextCodepoint()) |codepoint| {
        if (current_idx == index) {
            const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
            inner.* = Value{ .char = codepoint };
            return Value{ .some = inner };
        }
        current_idx += 1;
    }

    return Value{ .none = {} };
}

/// Find index of substring: index_of(str, substr) -> Option[int]
/// Returns the codepoint index (not byte index) of the first occurrence.
fn stringIndexOf(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const haystack = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const needle = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Find byte index first
    if (std.mem.indexOf(u8, haystack, needle)) |byte_idx| {
        // Convert byte index to codepoint index
        var utf8_view = std.unicode.Utf8View.initUnchecked(haystack);
        var iter = utf8_view.iterator();
        var codepoint_idx: i64 = 0;
        var current_byte: usize = 0;

        while (iter.nextCodepointSlice()) |slice| {
            if (current_byte == byte_idx) {
                const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
                inner.* = Value{ .integer = codepoint_idx };
                return Value{ .some = inner };
            }
            current_byte += slice.len;
            codepoint_idx += 1;
        }

        // Edge case: byte_idx points exactly at the end
        if (current_byte == byte_idx) {
            const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
            inner.* = Value{ .integer = codepoint_idx };
            return Value{ .some = inner };
        }
    }

    return Value{ .none = {} };
}

/// Check if two strings are equal: equals(str1, str2) -> bool
fn stringEquals(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
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

/// Convert string to list of characters: chars(str) -> List[Char]
/// Returns a linked list (cons cells) of Unicode codepoints from the string.
/// For ASCII strings, each byte becomes one character.
/// For UTF-8 strings, each Unicode codepoint becomes one character.
fn stringChars(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Collect all characters into an array first
    var chars_list = std.ArrayListUnmanaged(Value){};
    defer chars_list.deinit(ctx.allocator);

    // Use UTF-8 view to properly decode Unicode codepoints
    var utf8_view = std.unicode.Utf8View.initUnchecked(str);
    var iter = utf8_view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        chars_list.append(ctx.allocator, Value{ .char = codepoint }) catch return error.OutOfMemory;
    }

    // Build the list (cons cells) from the array
    // Build in reverse to get correct order
    var result: Value = Value{ .nil = {} };
    var i = chars_list.items.len;
    while (i > 0) {
        i -= 1;
        const head = ctx.allocator.create(Value) catch return error.OutOfMemory;
        const tail = ctx.allocator.create(Value) catch return error.OutOfMemory;
        head.* = chars_list.items[i];
        tail.* = result;
        result = Value{ .cons = .{ .head = head, .tail = tail } };
    }

    return result;
}

/// Convert integer to string: from_i32(n) -> str, from_i64(n) -> str, from_int(n) -> str
fn stringFromInt(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const num = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // Format the integer as a string
    var buf: [40]u8 = undefined; // Enough for i128
    const slice = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return error.OutOfMemory;
    const result = ctx.allocator.alloc(u8, slice.len) catch return error.OutOfMemory;
    @memcpy(result, slice);

    return Value{ .string = result };
}

/// Convert float to string: from_f32(n) -> str, from_f64(n) -> str, from_float(n) -> str
fn stringFromFloat(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const num = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    // Format the float as a string
    var buf: [64]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return error.OutOfMemory;
    const result = ctx.allocator.alloc(u8, slice.len) catch return error.OutOfMemory;
    @memcpy(result, slice);

    return Value{ .string = result };
}

/// Convert boolean to string: from_bool(b) -> str
fn stringFromBool(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const b = switch (args[0]) {
        .boolean => |v| v,
        else => return error.TypeMismatch,
    };

    return Value{ .string = if (b) "true" else "false" };
}

/// Convert any value to string: to_string(val) -> str
fn stringToString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const result = args[0].toString(ctx.allocator) catch return error.OutOfMemory;
    return Value{ .string = result };
}

/// Parse string to integer: parse_int(str) -> Option[int]
/// Returns Some(value) if parsing succeeds, None if it fails
fn stringParseInt(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Trim whitespace before parsing
    const trimmed = std.mem.trim(u8, str, " \t\n\r");

    // Try to parse the integer
    const parsed = std.fmt.parseInt(i128, trimmed, 10) catch {
        // Parsing failed, return None
        return Value{ .none = {} };
    };

    // Parsing succeeded, return Some(value)
    const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
    inner.* = Value{ .integer = parsed };
    return Value{ .some = inner };
}

// ============================================================================
// Tests
// ============================================================================

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
    };
}

test "string length" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try stringLength(ctx, &.{Value{ .string = "hello" }});
    try std.testing.expectEqual(@as(i128, 5), result.integer);

    const empty = try stringLength(ctx, &.{Value{ .string = "" }});
    try std.testing.expectEqual(@as(i128, 0), empty.integer);
}

test "string contains" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const yes = try stringContains(ctx, &.{ Value{ .string = "hello world" }, Value{ .string = "world" } });
    try std.testing.expect(yes.boolean);

    const no = try stringContains(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "world" } });
    try std.testing.expect(!no.boolean);
}

test "string starts_with and ends_with" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const starts = try stringStartsWith(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "hel" } });
    try std.testing.expect(starts.boolean);

    const ends = try stringEndsWith(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "lo" } });
    try std.testing.expect(ends.boolean);
}

test "string trim" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try stringTrim(ctx, &.{Value{ .string = "  hello  " }});
    try std.testing.expectEqualStrings("hello", result.string);
}

test "string concat" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try stringConcat(ctx, &.{ Value{ .string = "hello" }, Value{ .string = " world" } });
    defer allocator.free(result.string);
    try std.testing.expectEqualStrings("hello world", result.string);
}

test "string to_upper and to_lower" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const upper = try stringToUpper(ctx, &.{Value{ .string = "Hello" }});
    defer allocator.free(upper.string);
    try std.testing.expectEqualStrings("HELLO", upper.string);

    const lower = try stringToLower(ctx, &.{Value{ .string = "Hello" }});
    defer allocator.free(lower.string);
    try std.testing.expectEqualStrings("hello", lower.string);
}

test "string substring" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try stringSubstring(ctx, &.{
        Value{ .string = "hello world" },
        Value{ .integer = 0 },
        Value{ .integer = 5 },
    });
    try std.testing.expectEqualStrings("hello", result.string);
}

test "string equals" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const equal = try stringEquals(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "hello" } });
    try std.testing.expect(equal.boolean);

    const not_equal = try stringEquals(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "world" } });
    try std.testing.expect(!not_equal.boolean);

    const empty_equal = try stringEquals(ctx, &.{ Value{ .string = "" }, Value{ .string = "" } });
    try std.testing.expect(empty_equal.boolean);
}

test "string parse_int" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Valid positive integer
    const pos_result = try stringParseInt(ctx, &.{Value{ .string = "8080" }});
    try std.testing.expect(pos_result == .some);
    defer allocator.destroy(pos_result.some);
    try std.testing.expectEqual(@as(i128, 8080), pos_result.some.*.integer);

    // Valid negative integer
    const neg_result = try stringParseInt(ctx, &.{Value{ .string = "-42" }});
    try std.testing.expect(neg_result == .some);
    defer allocator.destroy(neg_result.some);
    try std.testing.expectEqual(@as(i128, -42), neg_result.some.*.integer);

    // With whitespace (should be trimmed)
    const ws_result = try stringParseInt(ctx, &.{Value{ .string = "  123  " }});
    try std.testing.expect(ws_result == .some);
    defer allocator.destroy(ws_result.some);
    try std.testing.expectEqual(@as(i128, 123), ws_result.some.*.integer);

    // Invalid string - returns None
    const invalid = try stringParseInt(ctx, &.{Value{ .string = "not a number" }});
    try std.testing.expect(invalid == .none);

    // Empty string - returns None
    const empty = try stringParseInt(ctx, &.{Value{ .string = "" }});
    try std.testing.expect(empty == .none);

    // Zero
    const zero = try stringParseInt(ctx, &.{Value{ .string = "0" }});
    try std.testing.expect(zero == .some);
    defer allocator.destroy(zero.some);
    try std.testing.expectEqual(@as(i128, 0), zero.some.*.integer);
}

test "string chars" {
    // Use arena for tests with list allocations
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // ASCII string "abc" -> List['a', 'b', 'c']
    const result = try stringChars(ctx, &.{Value{ .string = "abc" }});
    try std.testing.expect(result == .cons);
    try std.testing.expectEqual(@as(u21, 'a'), result.cons.head.char);
    try std.testing.expectEqual(@as(u21, 'b'), result.cons.tail.cons.head.char);
    try std.testing.expectEqual(@as(u21, 'c'), result.cons.tail.cons.tail.cons.head.char);
    try std.testing.expect(result.cons.tail.cons.tail.cons.tail.* == .nil);

    // Empty string -> empty list (nil)
    const empty = try stringChars(ctx, &.{Value{ .string = "" }});
    try std.testing.expect(empty == .nil);

    // UTF-8 string with multi-byte characters
    const utf8_result = try stringChars(ctx, &.{Value{ .string = "\xc3\xa9" }}); // "é" in UTF-8
    try std.testing.expect(utf8_result == .cons);
    try std.testing.expectEqual(@as(u21, 0xe9), utf8_result.cons.head.char); // U+00E9 = é
    try std.testing.expect(utf8_result.cons.tail.* == .nil);
}
