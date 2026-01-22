//! Built-in functions for the Kira interpreter.
//!
//! These are functions that are available without import and implemented
//! directly in Zig for performance and access to system resources.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");

const Value = value_mod.Value;
const Environment = value_mod.Environment;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = Value.BuiltinContext;

/// Register all built-in functions in the given environment.
pub fn registerBuiltins(allocator: Allocator, env: *Environment) !void {
    // Print functions
    try env.define("print", makeBuiltin("print", &builtinPrint), false);
    try env.define("println", makeBuiltin("println", &builtinPrintln), false);

    // Type checking
    try env.define("type_of", makeBuiltin("type_of", &builtinTypeOf), false);

    // Conversion functions
    try env.define("to_string", makeBuiltin("to_string", &builtinToString), false);
    try env.define("to_int", makeBuiltin("to_int", &builtinToInt), false);
    try env.define("to_float", makeBuiltin("to_float", &builtinToFloat), false);

    // Math functions
    try env.define("abs", makeBuiltin("abs", &builtinAbs), false);
    try env.define("min", makeBuiltin("min", &builtinMin), false);
    try env.define("max", makeBuiltin("max", &builtinMax), false);

    // Collection functions
    try env.define("len", makeBuiltin("len", &builtinLen), false);
    try env.define("push", makeBuiltin("push", &builtinPush), false);
    try env.define("pop", makeBuiltin("pop", &builtinPop), false);
    try env.define("head", makeBuiltin("head", &builtinHead), false);
    try env.define("tail", makeBuiltin("tail", &builtinTail), false);
    try env.define("empty", makeBuiltin("empty", &builtinEmpty), false);
    try env.define("reverse", makeBuiltin("reverse", &builtinReverse), false);

    // String functions
    try env.define("split", makeBuiltin("split", &builtinSplit), false);
    try env.define("join", makeBuiltin("join", &builtinJoin), false);
    try env.define("trim", makeBuiltin("trim", &builtinTrim), false);
    try env.define("contains", makeBuiltin("contains", &builtinContains), false);
    try env.define("starts_with", makeBuiltin("starts_with", &builtinStartsWith), false);
    try env.define("ends_with", makeBuiltin("ends_with", &builtinEndsWith), false);

    // Option/Result constructors (also handled in variant_constructor)
    try env.define("Some", makeBuiltin("Some", &builtinSome), false);
    try env.define("None", Value{ .none = {} }, false);
    try env.define("Ok", makeBuiltin("Ok", &builtinOk), false);
    try env.define("Err", makeBuiltin("Err", &builtinErr), false);

    // List constructors
    try env.define("Nil", Value{ .nil = {} }, false);
    try env.define("Cons", makeBuiltin("Cons", &builtinCons), false);

    // Assertions
    try env.define("assert", makeBuiltin("assert", &builtinAssert), false);
    try env.define("assert_eq", makeBuiltin("assert_eq", &builtinAssertEq), false);

    _ = allocator;
}

/// Helper to create a builtin function value
fn makeBuiltin(
    name: []const u8,
    func: *const fn (ctx: BuiltinContext, args: []const Value) InterpreterError!Value,
) Value {
    return Value{
        .function = .{
            .name = name,
            .parameters = &.{},
            .body = .{ .builtin = func },
            .captured_env = null,
            .is_effect = true, // Most builtins are effectful
        },
    };
}

// ============================================================================
// Print Functions
// ============================================================================

fn builtinPrint(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    const stdout = std.fs.File.stdout();
    for (args) |arg| {
        const str = arg.toString(ctx.allocator) catch return error.OutOfMemory;
        // Remove quotes from strings for printing
        const output = if (arg == .string) arg.string else str;
        stdout.writeAll(output) catch return error.InvalidOperation;
    }
    return Value{ .void = {} };
}

fn builtinPrintln(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = try builtinPrint(ctx, args);
    const stdout = std.fs.File.stdout();
    stdout.writeAll("\n") catch return error.InvalidOperation;
    return Value{ .void = {} };
}

// ============================================================================
// Type Functions
// ============================================================================

fn builtinTypeOf(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const type_name: []const u8 = switch (args[0]) {
        .integer => "i128",
        .float => "f64",
        .string => "string",
        .char => "char",
        .boolean => "bool",
        .void => "void",
        .tuple => "tuple",
        .array => "array",
        .record => |r| r.type_name orelse "record",
        .function => "function",
        .variant => |v| v.name,
        .some => "Option",
        .none => "Option",
        .ok, .err => "Result",
        .cons, .nil => "List",
        .io => "IO",
        .reference => "reference",
    };

    return Value{ .string = type_name };
}

// ============================================================================
// Conversion Functions
// ============================================================================

fn builtinToString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => args[0].toString(ctx.allocator) catch return error.OutOfMemory,
    };

    return Value{ .string = str };
}

fn builtinToInt(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .integer => args[0],
        .float => |f| Value{ .integer = @intFromFloat(f) },
        .char => |c| Value{ .integer = c },
        .string => |s| {
            const val = std.fmt.parseInt(i128, s, 10) catch return error.InvalidOperation;
            return Value{ .integer = val };
        },
        .boolean => |b| Value{ .integer = if (b) 1 else 0 },
        else => error.TypeMismatch,
    };
}

fn builtinToFloat(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .float => args[0],
        .integer => |i| Value{ .float = @floatFromInt(i) },
        .string => |s| {
            const val = std.fmt.parseFloat(f64, s) catch return error.InvalidOperation;
            return Value{ .float = val };
        },
        else => error.TypeMismatch,
    };
}

// ============================================================================
// Math Functions
// ============================================================================

fn builtinAbs(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .integer => |i| Value{ .integer = if (i < 0) -i else i },
        .float => |f| Value{ .float = @abs(f) },
        else => error.TypeMismatch,
    };
}

fn builtinMin(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    return switch (args[0]) {
        .integer => |a| switch (args[1]) {
            .integer => |b| Value{ .integer = @min(a, b) },
            else => error.TypeMismatch,
        },
        .float => |a| switch (args[1]) {
            .float => |b| Value{ .float = @min(a, b) },
            else => error.TypeMismatch,
        },
        else => error.TypeMismatch,
    };
}

fn builtinMax(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    return switch (args[0]) {
        .integer => |a| switch (args[1]) {
            .integer => |b| Value{ .integer = @max(a, b) },
            else => error.TypeMismatch,
        },
        .float => |a| switch (args[1]) {
            .float => |b| Value{ .float = @max(a, b) },
            else => error.TypeMismatch,
        },
        else => error.TypeMismatch,
    };
}

// ============================================================================
// Collection Functions
// ============================================================================

fn builtinLen(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .string => |s| Value{ .integer = @intCast(s.len) },
        .array => |a| Value{ .integer = @intCast(a.len) },
        .tuple => |t| Value{ .integer = @intCast(t.len) },
        .cons => {
            var count: i128 = 0;
            var current = args[0];
            while (current == .cons) {
                count += 1;
                current = current.cons.tail.*;
            }
            return Value{ .integer = count };
        },
        .nil => Value{ .integer = 0 },
        else => error.TypeMismatch,
    };
}

fn builtinPush(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    return switch (args[0]) {
        .array => |arr| {
            const new_arr = ctx.allocator.alloc(Value, arr.len + 1) catch return error.OutOfMemory;
            @memcpy(new_arr[0..arr.len], arr);
            new_arr[arr.len] = args[1];
            return Value{ .array = new_arr };
        },
        else => error.TypeMismatch,
    };
}

fn builtinPop(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .array => |arr| {
            if (arr.len == 0) return Value{ .none = {} };
            return Value{ .array = arr[0 .. arr.len - 1] };
        },
        else => error.TypeMismatch,
    };
}

fn builtinHead(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .array => |arr| {
            if (arr.len == 0) return Value{ .none = {} };
            return arr[0];
        },
        .cons => |c| c.head.*,
        .nil => Value{ .none = {} },
        else => error.TypeMismatch,
    };
}

fn builtinTail(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .array => |arr| {
            if (arr.len == 0) return Value{ .array = &.{} };
            return Value{ .array = arr[1..] };
        },
        .cons => |c| c.tail.*,
        .nil => Value{ .nil = {} },
        else => error.TypeMismatch,
    };
}

fn builtinEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .array => |arr| Value{ .boolean = arr.len == 0 },
        .string => |s| Value{ .boolean = s.len == 0 },
        .cons => Value{ .boolean = false },
        .nil => Value{ .boolean = true },
        else => error.TypeMismatch,
    };
}

fn builtinReverse(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .array => |arr| {
            const new_arr = ctx.allocator.alloc(Value, arr.len) catch return error.OutOfMemory;
            for (arr, 0..) |elem, i| {
                new_arr[arr.len - 1 - i] = elem;
            }
            return Value{ .array = new_arr };
        },
        .string => |s| {
            const new_str = ctx.allocator.alloc(u8, s.len) catch return error.OutOfMemory;
            for (s, 0..) |c, i| {
                new_str[s.len - 1 - i] = c;
            }
            return Value{ .string = new_str };
        },
        else => error.TypeMismatch,
    };
}

// ============================================================================
// String Functions
// ============================================================================

fn builtinSplit(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
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
    var iter = std.mem.splitSequence(u8, str, delim);
    while (iter.next()) |part| {
        parts.append(ctx.allocator, Value{ .string = part }) catch return error.OutOfMemory;
    }

    return Value{ .array = parts.toOwnedSlice(ctx.allocator) catch return error.OutOfMemory };
}

fn builtinJoin(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const arr = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const sep = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    var result = std.ArrayListUnmanaged(u8){};
    for (arr, 0..) |elem, i| {
        if (i > 0) {
            result.appendSlice(ctx.allocator, sep) catch return error.OutOfMemory;
        }
        const str = switch (elem) {
            .string => |s| s,
            else => elem.toString(ctx.allocator) catch return error.OutOfMemory,
        };
        result.appendSlice(ctx.allocator, str) catch return error.OutOfMemory;
    }

    return Value{ .string = result.toOwnedSlice(ctx.allocator) catch return error.OutOfMemory };
}

fn builtinTrim(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .string = std.mem.trim(u8, str, " \t\n\r") };
}

fn builtinContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
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

fn builtinStartsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
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

fn builtinEndsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
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

// ============================================================================
// Option/Result Constructors
// ============================================================================

fn builtinSome(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
    inner.* = args[0];
    return Value{ .some = inner };
}

fn builtinOk(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
    inner.* = args[0];
    return Value{ .ok = inner };
}

fn builtinErr(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
    inner.* = args[0];
    return Value{ .err = inner };
}

fn builtinCons(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const head = ctx.allocator.create(Value) catch return error.OutOfMemory;
    const tail = ctx.allocator.create(Value) catch return error.OutOfMemory;
    head.* = args[0];
    tail.* = args[1];
    return Value{ .cons = .{ .head = head, .tail = tail } };
}

// ============================================================================
// Assertion Functions
// ============================================================================

fn builtinAssert(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;

    if (!args[0].isTruthy()) {
        if (args.len == 2) {
            const msg = switch (args[1]) {
                .string => |s| s,
                else => "assertion failed",
            };
            std.debug.print("Assertion failed: {s}\n", .{msg});
        } else {
            std.debug.print("Assertion failed\n", .{});
        }
        return error.AssertionFailed;
    }

    return Value{ .void = {} };
}

fn builtinAssertEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    if (!args[0].eql(args[1])) {
        std.debug.print("Assertion failed: values not equal\n", .{});
        return error.AssertionFailed;
    }

    return Value{ .void = {} };
}

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
    };
}

test "builtin len" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // String length
    const str_result = try builtinLen(ctx, &.{Value{ .string = "hello" }});
    try std.testing.expectEqual(@as(i128, 5), str_result.integer);

    // Array length
    const arr = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const arr_result = try builtinLen(ctx, &.{Value{ .array = &arr }});
    try std.testing.expectEqual(@as(i128, 3), arr_result.integer);

    // Empty array
    const empty_result = try builtinLen(ctx, &.{Value{ .array = &.{} }});
    try std.testing.expectEqual(@as(i128, 0), empty_result.integer);
}

test "builtin math" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // abs
    const abs_result = try builtinAbs(ctx, &.{Value{ .integer = -5 }});
    try std.testing.expectEqual(@as(i128, 5), abs_result.integer);

    // min
    const min_result = try builtinMin(ctx, &.{ Value{ .integer = 3 }, Value{ .integer = 7 } });
    try std.testing.expectEqual(@as(i128, 3), min_result.integer);

    // max
    const max_result = try builtinMax(ctx, &.{ Value{ .integer = 3 }, Value{ .integer = 7 } });
    try std.testing.expectEqual(@as(i128, 7), max_result.integer);
}

test "builtin string functions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // contains
    const contains_result = try builtinContains(ctx, &.{ Value{ .string = "hello world" }, Value{ .string = "world" } });
    try std.testing.expect(contains_result.boolean);

    // starts_with
    const starts_result = try builtinStartsWith(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "hel" } });
    try std.testing.expect(starts_result.boolean);

    // ends_with
    const ends_result = try builtinEndsWith(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "lo" } });
    try std.testing.expect(ends_result.boolean);

    // trim
    const trim_result = try builtinTrim(ctx, &.{Value{ .string = "  hello  " }});
    try std.testing.expectEqualStrings("hello", trim_result.string);
}
