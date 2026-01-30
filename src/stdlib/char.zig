//! std.char - Character operations for the Kira standard library.
//!
//! Provides operations on characters:
//!   - from_i32: Convert integer code point to character (returns Option)
//!   - to_i32: Convert character to integer code point

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.char module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "from_i32", root.makeBuiltin("from_i32", &charFromI32));
    try fields.put(allocator, "to_i32", root.makeBuiltin("to_i32", &charToI32));

    return Value{
        .record = .{
            .type_name = "std.char",
            .fields = fields,
        },
    };
}

/// Convert integer code point to character: from_i32(int) -> Option[char]
/// Returns None for invalid Unicode code points (negative, > 0x10FFFF, or surrogate range).
fn charFromI32(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const code = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // Validate Unicode range (0 to 0x10FFFF, excluding surrogates 0xD800-0xDFFF)
    if (code < 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) {
        return Value{ .none = {} };
    }

    const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
    inner.* = Value{ .char = @intCast(code) };
    return Value{ .some = inner };
}

/// Convert character to integer code point: to_i32(char) -> int
fn charToI32(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const ch = switch (args[0]) {
        .char => |c| c,
        else => return error.TypeMismatch,
    };

    return Value{ .integer = @as(i128, ch) };
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

test "char from_i32 valid ASCII" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try charFromI32(ctx, &.{Value{ .integer = 65 }});
    try std.testing.expect(result == .some);
    try std.testing.expectEqual(@as(u21, 'A'), result.some.*.char);
    allocator.destroy(result.some);
}

test "char from_i32 valid Unicode" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Unicode snowman U+2603
    const result = try charFromI32(ctx, &.{Value{ .integer = 0x2603 }});
    try std.testing.expect(result == .some);
    try std.testing.expectEqual(@as(u21, 0x2603), result.some.*.char);
    allocator.destroy(result.some);
}

test "char from_i32 invalid negative" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try charFromI32(ctx, &.{Value{ .integer = -1 }});
    try std.testing.expect(result == .none);
}

test "char from_i32 invalid too large" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try charFromI32(ctx, &.{Value{ .integer = 0x110000 }});
    try std.testing.expect(result == .none);
}

test "char from_i32 invalid surrogate" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Surrogate range 0xD800-0xDFFF
    const result = try charFromI32(ctx, &.{Value{ .integer = 0xD800 }});
    try std.testing.expect(result == .none);

    const result2 = try charFromI32(ctx, &.{Value{ .integer = 0xDFFF }});
    try std.testing.expect(result2 == .none);
}

test "char to_i32" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try charToI32(ctx, &.{Value{ .char = 'A' }});
    try std.testing.expectEqual(@as(i128, 65), result.integer);

    const result2 = try charToI32(ctx, &.{Value{ .char = 0x2603 }});
    try std.testing.expectEqual(@as(i128, 0x2603), result2.integer);
}
