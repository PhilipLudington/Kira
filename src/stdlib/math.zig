//! std.math - Mathematical operations for the Kira standard library.
//!
//! Provides mathematical operations:
//!   - trunc_to_i64: Truncate float to integer (towards zero)

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.math module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "trunc_to_i64", root.makeBuiltin("trunc_to_i64", &mathTruncToI64));

    return Value{
        .record = .{
            .type_name = "std.math",
            .fields = fields,
        },
    };
}

/// Truncate float to integer (towards zero): trunc_to_i64(float) -> int
/// Returns error for NaN or Infinity values.
fn mathTruncToI64(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => |i| return Value{ .integer = i }, // passthrough for integers
        else => return error.TypeMismatch,
    };

    // Check for NaN or Infinity
    if (std.math.isNan(float_val) or std.math.isInf(float_val)) {
        return error.InvalidOperation;
    }

    return Value{ .integer = @intFromFloat(@trunc(float_val)) };
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

test "math trunc_to_i64 positive" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try mathTruncToI64(ctx, &.{Value{ .float = 3.7 }});
    try std.testing.expectEqual(@as(i128, 3), result.integer);

    const result2 = try mathTruncToI64(ctx, &.{Value{ .float = 3.2 }});
    try std.testing.expectEqual(@as(i128, 3), result2.integer);
}

test "math trunc_to_i64 negative" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try mathTruncToI64(ctx, &.{Value{ .float = -2.9 }});
    try std.testing.expectEqual(@as(i128, -2), result.integer);

    const result2 = try mathTruncToI64(ctx, &.{Value{ .float = -2.1 }});
    try std.testing.expectEqual(@as(i128, -2), result2.integer);
}

test "math trunc_to_i64 integer passthrough" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try mathTruncToI64(ctx, &.{Value{ .integer = 42 }});
    try std.testing.expectEqual(@as(i128, 42), result.integer);
}

test "math trunc_to_i64 nan returns error" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = mathTruncToI64(ctx, &.{Value{ .float = std.math.nan(f64) }});
    try std.testing.expectError(error.InvalidOperation, result);
}

test "math trunc_to_i64 infinity returns error" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = mathTruncToI64(ctx, &.{Value{ .float = std.math.inf(f64) }});
    try std.testing.expectError(error.InvalidOperation, result);
}
