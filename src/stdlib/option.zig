//! std.option - Option type operations for the Kira standard library.
//!
//! Provides operations on Option[T] values (Some(x) or None):
//!   - map: Transform the inner value if Some
//!   - and_then: Chain optional operations (flatMap)
//!   - unwrap_or: Get value or default
//!   - is_some, is_none: Check variant

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;

/// Create the std.option module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "map", root.makeBuiltin("map", &optionMap));
    try fields.put(allocator, "and_then", root.makeBuiltin("and_then", &optionAndThen));
    try fields.put(allocator, "unwrap_or", root.makeBuiltin("unwrap_or", &optionUnwrapOr));
    try fields.put(allocator, "is_some", root.makeBuiltin("is_some", &optionIsSome));
    try fields.put(allocator, "is_none", root.makeBuiltin("is_none", &optionIsNone));

    return Value{
        .record = .{
            .type_name = "std.option",
            .fields = fields,
        },
    };
}

/// Transform the inner value: map(fn, option) -> Option[U]
/// map(f, Some(x)) = Some(f(x))
/// map(f, None) = None
fn optionMap(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    return switch (args[1]) {
        .some => |inner| {
            const result = try applyFunction(allocator, func, &.{inner.*});
            const boxed = allocator.create(Value) catch return error.OutOfMemory;
            boxed.* = result;
            return Value{ .some = boxed };
        },
        .none => Value{ .none = {} },
        else => error.TypeMismatch,
    };
}

/// Chain optional operations: and_then(fn, option) -> Option[U]
/// and_then(f, Some(x)) = f(x)  (f must return Option[U])
/// and_then(f, None) = None
fn optionAndThen(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    return switch (args[1]) {
        .some => |inner| {
            const result = try applyFunction(allocator, func, &.{inner.*});
            // Result should be an Option
            return switch (result) {
                .some, .none => result,
                else => error.TypeMismatch,
            };
        },
        .none => Value{ .none = {} },
        else => error.TypeMismatch,
    };
}

/// Get value or default: unwrap_or(option, default) -> T
fn optionUnwrapOr(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    return switch (args[0]) {
        .some => |inner| inner.*,
        .none => args[1],
        else => error.TypeMismatch,
    };
}

/// Check if Some: is_some(option) -> bool
fn optionIsSome(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .some => Value{ .boolean = true },
        .none => Value{ .boolean = false },
        else => error.TypeMismatch,
    };
}

/// Check if None: is_none(option) -> bool
fn optionIsNone(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .some => Value{ .boolean = false },
        .none => Value{ .boolean = true },
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

test "option is_some and is_none" {
    const allocator = std.testing.allocator;

    // Create Some(42)
    const inner = try allocator.create(Value);
    defer allocator.destroy(inner);
    inner.* = Value{ .integer = 42 };
    const some_val = Value{ .some = inner };

    // is_some
    const is_some_result = try optionIsSome(allocator, &.{some_val});
    try std.testing.expect(is_some_result.boolean);

    // is_none on Some
    const is_none_result = try optionIsNone(allocator, &.{some_val});
    try std.testing.expect(!is_none_result.boolean);

    // None
    const none_val = Value{ .none = {} };
    const is_some_none = try optionIsSome(allocator, &.{none_val});
    try std.testing.expect(!is_some_none.boolean);

    const is_none_none = try optionIsNone(allocator, &.{none_val});
    try std.testing.expect(is_none_none.boolean);
}

test "option unwrap_or" {
    const allocator = std.testing.allocator;

    // Some(42) unwrap_or 0 = 42
    const inner = try allocator.create(Value);
    defer allocator.destroy(inner);
    inner.* = Value{ .integer = 42 };
    const some_val = Value{ .some = inner };

    const unwrap_some = try optionUnwrapOr(allocator, &.{ some_val, Value{ .integer = 0 } });
    try std.testing.expectEqual(@as(i128, 42), unwrap_some.integer);

    // None unwrap_or 0 = 0
    const none_val = Value{ .none = {} };
    const unwrap_none = try optionUnwrapOr(allocator, &.{ none_val, Value{ .integer = 0 } });
    try std.testing.expectEqual(@as(i128, 0), unwrap_none.integer);
}
