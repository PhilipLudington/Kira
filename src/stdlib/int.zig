//! std.int - Integer operations for the Kira standard library.
//!
//! Provides operations on integers:
//!   - to_string: Convert integer to string
//!   - parse: Parse string to integer
//!   - abs: Absolute value
//!   - min: Minimum of two integers
//!   - max: Maximum of two integers
//!   - sign: Get sign (-1, 0, or 1)

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.int module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "to_string", root.makeBuiltin("to_string", &intToString));
    try fields.put(allocator, "parse", root.makeBuiltin("parse", &intParse));
    try fields.put(allocator, "abs", root.makeBuiltin("abs", &intAbs));
    try fields.put(allocator, "min", root.makeBuiltin("min", &intMin));
    try fields.put(allocator, "max", root.makeBuiltin("max", &intMax));
    try fields.put(allocator, "sign", root.makeBuiltin("sign", &intSign));

    return Value{
        .record = .{
            .type_name = "std.int",
            .fields = fields,
        },
    };
}

/// Convert integer to string: to_string(int) -> string
fn intToString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const int_val = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // Format integer to string
    var buf: [40]u8 = undefined; // Enough for i128
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch return error.OutOfMemory;

    // Allocate and copy
    const result = ctx.allocator.alloc(u8, formatted.len) catch return error.OutOfMemory;
    @memcpy(result, formatted);

    return Value{ .string = result };
}

/// Parse string to integer: parse(string) -> Option[int]
fn intParse(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const parsed = std.fmt.parseInt(i128, str, 10) catch {
        return Value{ .none = {} };
    };

    const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
    inner.* = Value{ .integer = parsed };
    return Value{ .some = inner };
}

/// Absolute value: abs(int) -> int
fn intAbs(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const int_val = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    return Value{ .integer = if (int_val < 0) -int_val else int_val };
}

/// Minimum of two integers: min(a, b) -> int
fn intMin(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const a = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const b = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    return Value{ .integer = if (a < b) a else b };
}

/// Maximum of two integers: max(a, b) -> int
fn intMax(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const a = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const b = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    return Value{ .integer = if (a > b) a else b };
}

/// Get sign: sign(int) -> int (-1, 0, or 1)
fn intSign(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const int_val = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const sign: i128 = if (int_val < 0) -1 else if (int_val > 0) @as(i128, 1) else 0;
    return Value{ .integer = sign };
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

test "int to_string" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try intToString(ctx, &.{Value{ .integer = 42 }});
    defer allocator.free(result.string);
    try std.testing.expectEqualStrings("42", result.string);

    const negative = try intToString(ctx, &.{Value{ .integer = -123 }});
    defer allocator.free(negative.string);
    try std.testing.expectEqualStrings("-123", negative.string);

    const zero = try intToString(ctx, &.{Value{ .integer = 0 }});
    defer allocator.free(zero.string);
    try std.testing.expectEqualStrings("0", zero.string);
}

test "int parse" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const valid = try intParse(ctx, &.{Value{ .string = "42" }});
    try std.testing.expect(valid == .some);
    try std.testing.expectEqual(@as(i128, 42), valid.some.*.integer);
    allocator.destroy(valid.some);

    const negative = try intParse(ctx, &.{Value{ .string = "-123" }});
    try std.testing.expect(negative == .some);
    try std.testing.expectEqual(@as(i128, -123), negative.some.*.integer);
    allocator.destroy(negative.some);

    const invalid = try intParse(ctx, &.{Value{ .string = "abc" }});
    try std.testing.expect(invalid == .none);
}

test "int abs" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const positive = try intAbs(ctx, &.{Value{ .integer = 42 }});
    try std.testing.expectEqual(@as(i128, 42), positive.integer);

    const negative = try intAbs(ctx, &.{Value{ .integer = -42 }});
    try std.testing.expectEqual(@as(i128, 42), negative.integer);

    const zero = try intAbs(ctx, &.{Value{ .integer = 0 }});
    try std.testing.expectEqual(@as(i128, 0), zero.integer);
}

test "int min max" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const min_result = try intMin(ctx, &.{ Value{ .integer = 5 }, Value{ .integer = 3 } });
    try std.testing.expectEqual(@as(i128, 3), min_result.integer);

    const max_result = try intMax(ctx, &.{ Value{ .integer = 5 }, Value{ .integer = 3 } });
    try std.testing.expectEqual(@as(i128, 5), max_result.integer);
}

test "int sign" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const positive = try intSign(ctx, &.{Value{ .integer = 42 }});
    try std.testing.expectEqual(@as(i128, 1), positive.integer);

    const negative = try intSign(ctx, &.{Value{ .integer = -42 }});
    try std.testing.expectEqual(@as(i128, -1), negative.integer);

    const zero = try intSign(ctx, &.{Value{ .integer = 0 }});
    try std.testing.expectEqual(@as(i128, 0), zero.integer);
}
