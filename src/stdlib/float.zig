//! std.float - Floating-point operations for the Kira standard library.
//!
//! Provides operations on floating-point numbers:
//!   - to_string: Convert float to string
//!   - parse: Parse string to float
//!   - abs: Absolute value
//!   - floor: Round down to nearest integer
//!   - ceil: Round up to nearest integer
//!   - round: Round to nearest integer
//!   - sqrt: Square root
//!   - min: Minimum of two floats
//!   - max: Maximum of two floats
//!   - is_nan: Check if value is NaN
//!   - is_infinite: Check if value is infinite

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.float module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "to_string", root.makeBuiltin("to_string", &floatToString));
    try fields.put(allocator, "parse", root.makeBuiltin("parse", &floatParse));
    try fields.put(allocator, "abs", root.makeBuiltin("abs", &floatAbs));
    try fields.put(allocator, "floor", root.makeBuiltin("floor", &floatFloor));
    try fields.put(allocator, "ceil", root.makeBuiltin("ceil", &floatCeil));
    try fields.put(allocator, "round", root.makeBuiltin("round", &floatRound));
    try fields.put(allocator, "sqrt", root.makeBuiltin("sqrt", &floatSqrt));
    try fields.put(allocator, "min", root.makeBuiltin("min", &floatMin));
    try fields.put(allocator, "max", root.makeBuiltin("max", &floatMax));
    try fields.put(allocator, "is_nan", root.makeBuiltin("is_nan", &floatIsNan));
    try fields.put(allocator, "is_infinite", root.makeBuiltin("is_infinite", &floatIsInfinite));
    try fields.put(allocator, "from_int", root.makeBuiltin("from_int", &floatFromInt));

    return Value{
        .record = .{
            .type_name = "std.float",
            .fields = fields,
        },
    };
}

/// Convert float to string: to_string(float) -> string
fn floatToString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    // Format float to string
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{float_val}) catch return error.OutOfMemory;

    // Allocate and copy
    const result = ctx.allocator.alloc(u8, formatted.len) catch return error.OutOfMemory;
    @memcpy(result, formatted);

    return Value{ .string = result };
}

/// Parse string to float: parse(string) -> Option[float]
fn floatParse(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const parsed = std.fmt.parseFloat(f64, str) catch {
        return Value{ .none = {} };
    };

    const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
    inner.* = Value{ .float = parsed };
    return Value{ .some = inner };
}

/// Absolute value: abs(float) -> float
fn floatAbs(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return Value{ .float = @abs(float_val) };
}

/// Floor: floor(float) -> float
fn floatFloor(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return Value{ .float = @floor(float_val) };
}

/// Ceiling: ceil(float) -> float
fn floatCeil(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return Value{ .float = @ceil(float_val) };
}

/// Round to nearest: round(float) -> float
fn floatRound(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return Value{ .float = @round(float_val) };
}

/// Square root: sqrt(float) -> float
fn floatSqrt(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return Value{ .float = @sqrt(float_val) };
}

/// Minimum of two floats: min(a, b) -> float
fn floatMin(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const a = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const b = switch (args[1]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return Value{ .float = @min(a, b) };
}

/// Maximum of two floats: max(a, b) -> float
fn floatMax(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const a = switch (args[0]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    const b = switch (args[1]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    return Value{ .float = @max(a, b) };
}

/// Check if value is NaN: is_nan(float) -> bool
fn floatIsNan(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => return Value{ .boolean = false },
        else => return error.TypeMismatch,
    };

    return Value{ .boolean = std.math.isNan(float_val) };
}

/// Check if value is infinite: is_infinite(float) -> bool
fn floatIsInfinite(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const float_val = switch (args[0]) {
        .float => |f| f,
        .integer => return Value{ .boolean = false },
        else => return error.TypeMismatch,
    };

    return Value{ .boolean = std.math.isInf(float_val) };
}

/// Convert integer to float: from_int(int) -> float
fn floatFromInt(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const int_val = switch (args[0]) {
        .integer => |i| i,
        .float => |f| return Value{ .float = f },
        else => return error.TypeMismatch,
    };

    return Value{ .float = @floatFromInt(int_val) };
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

test "float to_string" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = try floatToString(ctx, &.{Value{ .float = 42.5 }});
    defer allocator.free(result.string);
    try std.testing.expectEqualStrings("42.5", result.string);

    const negative = try floatToString(ctx, &.{Value{ .float = -123.456 }});
    defer allocator.free(negative.string);
    // Float formatting may vary, just check it starts with -123
    try std.testing.expect(std.mem.startsWith(u8, negative.string, "-123"));

    const zero = try floatToString(ctx, &.{Value{ .float = 0.0 }});
    defer allocator.free(zero.string);
    try std.testing.expectEqualStrings("0", zero.string);
}

test "float parse" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const valid = try floatParse(ctx, &.{Value{ .string = "42.5" }});
    try std.testing.expect(valid == .some);
    try std.testing.expectEqual(@as(f64, 42.5), valid.some.*.float);
    allocator.destroy(valid.some);

    const negative = try floatParse(ctx, &.{Value{ .string = "-123.456" }});
    try std.testing.expect(negative == .some);
    try std.testing.expectEqual(@as(f64, -123.456), negative.some.*.float);
    allocator.destroy(negative.some);

    const invalid = try floatParse(ctx, &.{Value{ .string = "abc" }});
    try std.testing.expect(invalid == .none);
}

test "float abs" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const positive = try floatAbs(ctx, &.{Value{ .float = 42.5 }});
    try std.testing.expectEqual(@as(f64, 42.5), positive.float);

    const negative = try floatAbs(ctx, &.{Value{ .float = -42.5 }});
    try std.testing.expectEqual(@as(f64, 42.5), negative.float);

    const zero = try floatAbs(ctx, &.{Value{ .float = 0.0 }});
    try std.testing.expectEqual(@as(f64, 0.0), zero.float);
}

test "float floor ceil round" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const floor_result = try floatFloor(ctx, &.{Value{ .float = 42.7 }});
    try std.testing.expectEqual(@as(f64, 42.0), floor_result.float);

    const ceil_result = try floatCeil(ctx, &.{Value{ .float = 42.3 }});
    try std.testing.expectEqual(@as(f64, 43.0), ceil_result.float);

    const round_result = try floatRound(ctx, &.{Value{ .float = 42.5 }});
    try std.testing.expectEqual(@as(f64, 43.0), round_result.float);
}

test "float min max" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const min_result = try floatMin(ctx, &.{ Value{ .float = 5.5 }, Value{ .float = 3.3 } });
    try std.testing.expectEqual(@as(f64, 3.3), min_result.float);

    const max_result = try floatMax(ctx, &.{ Value{ .float = 5.5 }, Value{ .float = 3.3 } });
    try std.testing.expectEqual(@as(f64, 5.5), max_result.float);
}

test "float is_nan is_infinite" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const nan_check = try floatIsNan(ctx, &.{Value{ .float = std.math.nan(f64) }});
    try std.testing.expect(nan_check.boolean);

    const not_nan = try floatIsNan(ctx, &.{Value{ .float = 42.0 }});
    try std.testing.expect(!not_nan.boolean);

    const inf_check = try floatIsInfinite(ctx, &.{Value{ .float = std.math.inf(f64) }});
    try std.testing.expect(inf_check.boolean);

    const not_inf = try floatIsInfinite(ctx, &.{Value{ .float = 42.0 }});
    try std.testing.expect(!not_inf.boolean);
}
