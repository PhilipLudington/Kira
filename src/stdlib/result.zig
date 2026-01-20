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

/// Transform the Ok value: map(fn, result) -> Result[U, E]
/// map(f, Ok(x)) = Ok(f(x))
/// map(f, Err(e)) = Err(e)
fn resultMap(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    return switch (args[1]) {
        .ok => |inner| {
            const result = try applyFunction(allocator, func, &.{inner.*});
            const boxed = allocator.create(Value) catch return error.OutOfMemory;
            boxed.* = result;
            return Value{ .ok = boxed };
        },
        .err => args[1], // Pass through unchanged
        else => error.TypeMismatch,
    };
}

/// Transform the Err value: map_err(fn, result) -> Result[T, F]
/// map_err(f, Ok(x)) = Ok(x)
/// map_err(f, Err(e)) = Err(f(e))
fn resultMapErr(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    return switch (args[1]) {
        .ok => args[1], // Pass through unchanged
        .err => |inner| {
            const result = try applyFunction(allocator, func, &.{inner.*});
            const boxed = allocator.create(Value) catch return error.OutOfMemory;
            boxed.* = result;
            return Value{ .err = boxed };
        },
        else => error.TypeMismatch,
    };
}

/// Chain Result operations: and_then(fn, result) -> Result[U, E]
/// and_then(f, Ok(x)) = f(x)  (f must return Result[U, E])
/// and_then(f, Err(e)) = Err(e)
fn resultAndThen(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    return switch (args[1]) {
        .ok => |inner| {
            const result = try applyFunction(allocator, func, &.{inner.*});
            // Result should be a Result
            return switch (result) {
                .ok, .err => result,
                else => error.TypeMismatch,
            };
        },
        .err => args[1], // Pass through unchanged
        else => error.TypeMismatch,
    };
}

/// Get Ok value or default: unwrap_or(result, default) -> T
fn resultUnwrapOr(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    return switch (args[0]) {
        .ok => |inner| inner.*,
        .err => args[1],
        else => error.TypeMismatch,
    };
}

/// Check if Ok: is_ok(result) -> bool
fn resultIsOk(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .ok => Value{ .boolean = true },
        .err => Value{ .boolean = false },
        else => error.TypeMismatch,
    };
}

/// Check if Err: is_err(result) -> bool
fn resultIsErr(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .ok => Value{ .boolean = false },
        .err => Value{ .boolean = true },
        else => error.TypeMismatch,
    };
}

/// Apply a function to arguments (builtin functions only)
fn applyFunction(allocator: Allocator, func: Value, args: []const Value) InterpreterError!Value {
    const f = func.function;
    switch (f.body) {
        .builtin => |builtin| return builtin(allocator, args),
        .ast_body => return error.InvalidOperation,
    }
}

// ============================================================================
// Tests
// ============================================================================

test "result is_ok and is_err" {
    const allocator = std.testing.allocator;

    // Create Ok(42)
    const ok_inner = try allocator.create(Value);
    defer allocator.destroy(ok_inner);
    ok_inner.* = Value{ .integer = 42 };
    const ok_val = Value{ .ok = ok_inner };

    // is_ok on Ok
    const is_ok_result = try resultIsOk(allocator, &.{ok_val});
    try std.testing.expect(is_ok_result.boolean);

    // is_err on Ok
    const is_err_result = try resultIsErr(allocator, &.{ok_val});
    try std.testing.expect(!is_err_result.boolean);

    // Create Err("error")
    const err_inner = try allocator.create(Value);
    defer allocator.destroy(err_inner);
    err_inner.* = Value{ .string = "error" };
    const err_val = Value{ .err = err_inner };

    // is_ok on Err
    const is_ok_err = try resultIsOk(allocator, &.{err_val});
    try std.testing.expect(!is_ok_err.boolean);

    // is_err on Err
    const is_err_err = try resultIsErr(allocator, &.{err_val});
    try std.testing.expect(is_err_err.boolean);
}

test "result unwrap_or" {
    const allocator = std.testing.allocator;

    // Ok(42) unwrap_or 0 = 42
    const ok_inner = try allocator.create(Value);
    defer allocator.destroy(ok_inner);
    ok_inner.* = Value{ .integer = 42 };
    const ok_val = Value{ .ok = ok_inner };

    const unwrap_ok = try resultUnwrapOr(allocator, &.{ ok_val, Value{ .integer = 0 } });
    try std.testing.expectEqual(@as(i128, 42), unwrap_ok.integer);

    // Err("error") unwrap_or 0 = 0
    const err_inner = try allocator.create(Value);
    defer allocator.destroy(err_inner);
    err_inner.* = Value{ .string = "error" };
    const err_val = Value{ .err = err_inner };

    const unwrap_err = try resultUnwrapOr(allocator, &.{ err_val, Value{ .integer = 0 } });
    try std.testing.expectEqual(@as(i128, 0), unwrap_err.integer);
}
