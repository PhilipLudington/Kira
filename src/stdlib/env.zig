//! std.env - Environment access for the Kira standard library.
//!
//! Provides access to environment information:
//!   - args: Get command-line arguments passed to the program

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Stored command-line arguments (set before program execution)
var stored_args: ?[]const Value = null;
var stored_allocator: ?Allocator = null;

/// Set the program arguments (called from main.zig before interpretation)
pub fn setArgs(allocator: Allocator, args: []const []const u8) !void {
    // Free previous args if any
    clearArgs();

    // Convert string slices to Value array
    const values = try allocator.alloc(Value, args.len);
    errdefer allocator.free(values);

    for (args, 0..) |arg, i| {
        values[i] = Value{ .string = try allocator.dupe(u8, arg) };
    }

    stored_args = values;
    stored_allocator = allocator;
}

/// Clear stored arguments (for cleanup)
pub fn clearArgs() void {
    if (stored_args) |args| {
        if (stored_allocator) |alloc| {
            for (args) |arg| {
                if (arg == .string) {
                    alloc.free(arg.string);
                }
            }
            alloc.free(args);
        }
    }
    stored_args = null;
    stored_allocator = null;
}

/// Create the std.env module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    // args() returns [string] - array of command-line arguments
    try fields.put(allocator, "args", root.makeBuiltin("args", &envArgs));

    return Value{
        .record = .{
            .type_name = "std.env",
            .fields = fields,
        },
    };
}

/// Get command-line arguments: args() -> [string]
fn envArgs(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 0) return error.ArityMismatch;

    // Return stored args or empty array
    if (stored_args) |program_args| {
        // Create a copy for the caller
        const result = ctx.allocator.alloc(Value, program_args.len) catch return error.OutOfMemory;
        for (program_args, 0..) |arg, i| {
            result[i] = arg;
        }
        return Value{ .array = result };
    }

    // No args stored - return empty array
    return Value{ .array = &.{} };
}

test "env module creation" {
    const allocator = std.testing.allocator;

    const module = try createModule(allocator);
    defer {
        var fields = module.record.fields;
        fields.deinit(allocator);
    }

    // Verify module structure
    try std.testing.expect(module.record.fields.contains("args"));
}

test "args returns empty when not set" {
    const allocator = std.testing.allocator;

    // Ensure no args are stored
    clearArgs();

    const ctx = BuiltinContext{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
    };

    const result = try envArgs(ctx, &.{});
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 0), result.array.len);
}

test "args returns stored values" {
    const allocator = std.testing.allocator;

    // Set some test args
    const test_args = [_][]const u8{ "arg1", "arg2", "arg3" };
    try setArgs(allocator, &test_args);
    defer clearArgs();

    const ctx = BuiltinContext{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
    };

    const result = try envArgs(ctx, &.{});
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 3), result.array.len);
    try std.testing.expectEqualStrings("arg1", result.array[0].string);
    try std.testing.expectEqualStrings("arg2", result.array[1].string);
    try std.testing.expectEqualStrings("arg3", result.array[2].string);

    allocator.free(result.array);
}
