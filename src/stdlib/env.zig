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

/// Get command-line arguments: args() -> List[string]
fn envArgs(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 0) return error.ArityMismatch;

    // Return stored args as a proper Cons/Nil list for pattern matching support
    if (stored_args) |program_args| {
        return buildList(ctx.allocator, program_args);
    }

    // No args stored - return empty list (Nil)
    return Value{ .nil = {} };
}

/// Build a proper linked list from an array of values.
/// Returns Nil for empty, or Cons(head, tail) chain for non-empty.
fn buildList(allocator: Allocator, items: []const Value) InterpreterError!Value {
    var result: Value = Value{ .nil = {} };

    // Build in reverse to get correct order
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const head = allocator.create(Value) catch return error.OutOfMemory;
        const tail = allocator.create(Value) catch return error.OutOfMemory;
        head.* = items[i];
        tail.* = result;
        result = Value{ .cons = .{ .head = head, .tail = tail } };
    }

    return result;
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
    // Should return Nil for empty args
    try std.testing.expect(result == .nil);
}

test "args returns stored values as Cons/Nil list" {
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
    defer freeList(allocator, result);

    // Should return Cons("arg1", Cons("arg2", Cons("arg3", Nil)))
    try std.testing.expect(result == .cons);

    // First element
    const first = result.cons;
    try std.testing.expectEqualStrings("arg1", first.head.string);

    // Second element
    try std.testing.expect(first.tail.* == .cons);
    const second = first.tail.cons;
    try std.testing.expectEqualStrings("arg2", second.head.string);

    // Third element
    try std.testing.expect(second.tail.* == .cons);
    const third = second.tail.cons;
    try std.testing.expectEqualStrings("arg3", third.head.string);

    // End of list
    try std.testing.expect(third.tail.* == .nil);
}

/// Helper to free a Cons/Nil list (for testing only)
fn freeList(allocator: Allocator, val: Value) void {
    switch (val) {
        .cons => |c| {
            freeList(allocator, c.tail.*);
            allocator.destroy(c.head);
            allocator.destroy(c.tail);
        },
        .nil => {},
        else => {},
    }
}
