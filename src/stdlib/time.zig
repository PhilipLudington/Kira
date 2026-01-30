//! std.time - Time operations for the Kira standard library.
//!
//! Provides time-related operations:
//!   - now: Get current timestamp in milliseconds (effect)
//!   - sleep: Sleep for specified milliseconds (effect)
//!   - elapsed: Calculate elapsed time between two timestamps (pure)

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.time module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    // Effect functions (read system state / cause side effects)
    try fields.put(allocator, "now", root.makeEffectBuiltin("now", &timeNow));
    try fields.put(allocator, "sleep", root.makeEffectBuiltin("sleep", &timeSleep));

    // Pure function
    try fields.put(allocator, "elapsed", root.makeBuiltin("elapsed", &timeElapsed));

    return Value{
        .record = .{
            .type_name = "std.time",
            .fields = fields,
        },
    };
}

/// Get current timestamp in milliseconds since Unix epoch: now() -> i64
/// This is an effect function (non-deterministic).
fn timeNow(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 0) return error.ArityMismatch;

    const timestamp = std.time.milliTimestamp();
    return Value{ .integer = timestamp };
}

/// Sleep for specified milliseconds: sleep(ms: i64) -> void
/// This is an effect function (side effect).
fn timeSleep(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const ms = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    if (ms < 0) return error.InvalidOperation;

    // Convert milliseconds to nanoseconds for std.Thread.sleep
    // Use checked multiplication to prevent overflow before cast
    const product = std.math.mul(i128, ms, std.time.ns_per_ms) catch return error.InvalidOperation;
    if (product < 0 or product > std.math.maxInt(u64)) return error.InvalidOperation;
    const ns: u64 = @intCast(product);
    std.Thread.sleep(ns);

    return Value{ .void = {} };
}

/// Calculate elapsed time between two timestamps: elapsed(start: i64, end: i64) -> i64
/// This is a pure function (deterministic).
fn timeElapsed(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const start = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const end = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    return Value{ .integer = end - start };
}

test "time module creation" {
    const allocator = std.testing.allocator;

    const module = try createModule(allocator);
    defer {
        var fields = module.record.fields;
        fields.deinit(allocator);
    }

    // Verify module structure
    try std.testing.expect(module.record.fields.contains("now"));
    try std.testing.expect(module.record.fields.contains("sleep"));
    try std.testing.expect(module.record.fields.contains("elapsed"));
}

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
        .env_args = null,
    };
}

test "elapsed calculation" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try timeElapsed(ctx, &.{
        Value{ .integer = 1000 },
        Value{ .integer = 1500 },
    });
    try std.testing.expectEqual(@as(i128, 500), result.integer);
}

test "elapsed with negative result" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try timeElapsed(ctx, &.{
        Value{ .integer = 2000 },
        Value{ .integer = 1000 },
    });
    try std.testing.expectEqual(@as(i128, -1000), result.integer);
}

test "now returns a timestamp" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try timeNow(ctx, &.{});
    try std.testing.expect(result == .integer);
    // Timestamp should be positive (we're past 1970)
    try std.testing.expect(result.integer > 0);
}

test "sleep with zero" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try timeSleep(ctx, &.{Value{ .integer = 0 }});
    try std.testing.expect(result == .void);
}

test "sleep rejects negative" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = timeSleep(ctx, &.{Value{ .integer = -100 }});
    try std.testing.expectError(error.InvalidOperation, result);
}
