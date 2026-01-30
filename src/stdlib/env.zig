//! std.env - Environment access for the Kira standard library.
//!
//! Provides access to environment information:
//!   - args: Get command-line arguments passed to the program
//!
//! Note: Arguments are passed through BuiltinContext.env_args, which is set
//! by the Interpreter. This avoids global state and enables proper testing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Convert string slices to Value array (for use by main.zig)
pub fn convertArgsToValues(allocator: Allocator, args: []const []const u8) ![]Value {
    const values = try allocator.alloc(Value, args.len);
    errdefer allocator.free(values);

    for (args, 0..) |arg, i| {
        values[i] = Value{ .string = try allocator.dupe(u8, arg) };
    }

    return values;
}

/// Free a Values array created by convertArgsToValues
pub fn freeArgsValues(allocator: Allocator, values: []const Value) void {
    for (values) |val| {
        if (val == .string) {
            allocator.free(val.string);
        }
    }
    allocator.free(values);
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

    // Return args from context as a proper Cons/Nil list for pattern matching support
    if (ctx.env_args) |program_args| {
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

    const ctx = BuiltinContext{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
        .env_args = null,
    };

    const result = try envArgs(ctx, &.{});
    // Should return Nil for empty args
    try std.testing.expect(result == .nil);
}

test "args returns context values as Cons/Nil list" {
    const allocator = std.testing.allocator;

    // Create test args via context
    const test_args = [_][]const u8{ "arg1", "arg2", "arg3" };
    const values = try convertArgsToValues(allocator, &test_args);
    defer freeArgsValues(allocator, values);

    const ctx = BuiltinContext{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
        .env_args = values,
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
