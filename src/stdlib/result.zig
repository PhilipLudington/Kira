//! std.result - Result type operations for the Kira standard library.
//!
//! Provides operations on Result[T, E] values (Ok(x) or Err(e)):
//!   - map: Transform the Ok value
//!   - map_err: Transform the Err value
//!   - and_then: Chain Result operations (flatMap)
//!   - unwrap_or: Get Ok value or default
//!   - is_ok, is_err: Check variant

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.result module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "map", root.makeBuiltin("map", &resultMap));
    try fields.put(allocator, "map_err", root.makeBuiltin("map_err", &resultMapErr));
    try fields.put(allocator, "and_then", root.makeBuiltin("and_then", &resultAndThen));
    try fields.put(allocator, "unwrap_or", root.makeBuiltin("unwrap_or", &resultUnwrapOr));
    try fields.put(allocator, "is_ok", root.makeBuiltin("is_ok", &resultIsOk));
    try fields.put(allocator, "is_err", root.makeBuiltin("is_err", &resultIsErr));

    return Value{
        .record = .{
            .type_name = "std.result",
            .fields = fields,
        },
    };
}

/// Transform the Ok value: map(result, fn) -> Result[U, E]
/// map(Ok(x), f) = Ok(f(x))
/// map(Err(e), f) = Err(e)
fn resultMap(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = result, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    return switch (args[0]) {
        .ok => |inner| {
            const result = try ctx.callFunction(func, &.{inner.*});
            const boxed = ctx.allocator.create(Value) catch return error.OutOfMemory;
            boxed.* = result;
            return Value{ .ok = boxed };
        },
        .err => args[0], // Pass through unchanged
        else => error.TypeMismatch,
    };
}

/// Transform the Err value: map_err(result, fn) -> Result[T, F]
/// map_err(Ok(x), f) = Ok(x)
/// map_err(Err(e), f) = Err(f(e))
fn resultMapErr(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = result, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    return switch (args[0]) {
        .ok => args[0], // Pass through unchanged
        .err => |inner| {
            const result = try ctx.callFunction(func, &.{inner.*});
            const boxed = ctx.allocator.create(Value) catch return error.OutOfMemory;
            boxed.* = result;
            return Value{ .err = boxed };
        },
        else => error.TypeMismatch,
    };
}

/// Chain Result operations: and_then(result, fn) -> Result[U, E]
/// and_then(Ok(x), f) = f(x)  (f must return Result[U, E])
/// and_then(Err(e), f) = Err(e)
fn resultAndThen(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = result, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    return switch (args[0]) {
        .ok => |inner| {
            const result = try ctx.callFunction(func, &.{inner.*});
            // Result should be a Result
            return switch (result) {
                .ok, .err => result,
                else => error.TypeMismatch,
            };
        },
        .err => args[0], // Pass through unchanged
        else => error.TypeMismatch,
    };
}

/// Get Ok value or default: unwrap_or(result, default) -> T
fn resultUnwrapOr(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    return switch (args[0]) {
        .ok => |inner| inner.*,
        .err => args[1],
        else => error.TypeMismatch,
    };
}

/// Check if Ok: is_ok(result) -> bool
fn resultIsOk(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .ok => Value{ .boolean = true },
        .err => Value{ .boolean = false },
        else => error.TypeMismatch,
    };
}

/// Check if Err: is_err(result) -> bool
fn resultIsErr(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .ok => Value{ .boolean = false },
        .err => Value{ .boolean = true },
        else => error.TypeMismatch,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "result is_ok and is_err" {
    const allocator = std.testing.allocator;

    // Create a test context
    const ctx = BuiltinContext{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
        .env_args = null,
    };

    // Create Ok(42)
    const ok_inner = try allocator.create(Value);
    defer allocator.destroy(ok_inner);
    ok_inner.* = Value{ .integer = 42 };
    const ok_val = Value{ .ok = ok_inner };

    // is_ok on Ok
    const is_ok_result = try resultIsOk(ctx, &.{ok_val});
    try std.testing.expect(is_ok_result.boolean);

    // is_err on Ok
    const is_err_result = try resultIsErr(ctx, &.{ok_val});
    try std.testing.expect(!is_err_result.boolean);

    // Create Err("error")
    const err_inner = try allocator.create(Value);
    defer allocator.destroy(err_inner);
    err_inner.* = Value{ .string = "error" };
    const err_val = Value{ .err = err_inner };

    // is_ok on Err
    const is_ok_err = try resultIsOk(ctx, &.{err_val});
    try std.testing.expect(!is_ok_err.boolean);

    // is_err on Err
    const is_err_err = try resultIsErr(ctx, &.{err_val});
    try std.testing.expect(is_err_err.boolean);
}

test "result unwrap_or" {
    const allocator = std.testing.allocator;

    // Create a test context
    const ctx = BuiltinContext{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
        .env_args = null,
    };

    // Ok(42) unwrap_or 0 = 42
    const ok_inner = try allocator.create(Value);
    defer allocator.destroy(ok_inner);
    ok_inner.* = Value{ .integer = 42 };
    const ok_val = Value{ .ok = ok_inner };

    const unwrap_ok = try resultUnwrapOr(ctx, &.{ ok_val, Value{ .integer = 0 } });
    try std.testing.expectEqual(@as(i128, 42), unwrap_ok.integer);

    // Err("error") unwrap_or 0 = 0
    const err_inner = try allocator.create(Value);
    defer allocator.destroy(err_inner);
    err_inner.* = Value{ .string = "error" };
    const err_val = Value{ .err = err_inner };

    const unwrap_err = try resultUnwrapOr(ctx, &.{ err_val, Value{ .integer = 0 } });
    try std.testing.expectEqual(@as(i128, 0), unwrap_err.integer);
}
