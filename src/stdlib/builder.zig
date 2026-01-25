//! std.builder - String builder operations for the Kira standard library.
//!
//! Provides efficient string building operations:
//!   - new: Create a new empty builder
//!   - append: Append a string to the builder
//!   - append_char: Append a single character
//!   - append_int: Append an integer as string
//!   - append_float: Append a float as string
//!   - build: Get the final built string
//!   - clear: Clear the builder contents
//!   - length: Get current length

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.builder module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "new", root.makeBuiltin("new", &builderNew));
    try fields.put(allocator, "append", root.makeBuiltin("append", &builderAppend));
    try fields.put(allocator, "append_char", root.makeBuiltin("append_char", &builderAppendChar));
    try fields.put(allocator, "append_int", root.makeBuiltin("append_int", &builderAppendInt));
    try fields.put(allocator, "append_float", root.makeBuiltin("append_float", &builderAppendFloat));
    try fields.put(allocator, "build", root.makeBuiltin("build", &builderBuild));
    try fields.put(allocator, "clear", root.makeBuiltin("clear", &builderClear));
    try fields.put(allocator, "length", root.makeBuiltin("length", &builderLength));

    return Value{
        .record = .{
            .type_name = "std.builder",
            .fields = fields,
        },
    };
}

/// Builder is represented as a record with:
///   - _buffer: String containing accumulated data
///   - _type: "StringBuilder" marker
const builder_type_name = "StringBuilder";

/// Create a new empty builder: new() -> StringBuilder
fn builderNew(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 0) return error.ArityMismatch;

    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_buffer", Value{ .string = "" }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = builder_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = builder_type_name,
            .fields = fields,
        },
    };
}

/// Check if a value is a StringBuilder
fn isBuilder(val: Value) bool {
    return switch (val) {
        .record => |r| if (r.type_name) |name| std.mem.eql(u8, name, builder_type_name) else false,
        else => false,
    };
}

/// Get the buffer from a StringBuilder
fn getBuffer(builder: Value) ?[]const u8 {
    const record = switch (builder) {
        .record => |r| r,
        else => return null,
    };
    const buffer_val = record.fields.get("_buffer") orelse return null;
    return switch (buffer_val) {
        .string => |s| s,
        else => null,
    };
}

/// Append a string to the builder: append(builder, str) -> StringBuilder
fn builderAppend(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isBuilder(args[0])) return error.TypeMismatch;
    const current_buffer = getBuffer(args[0]) orelse return error.TypeMismatch;

    const str_to_append = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Create new buffer with appended content
    const new_len = current_buffer.len + str_to_append.len;
    const new_buffer = ctx.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
    @memcpy(new_buffer[0..current_buffer.len], current_buffer);
    @memcpy(new_buffer[current_buffer.len..], str_to_append);

    // Create new builder record with updated buffer
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_buffer", Value{ .string = new_buffer }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = builder_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = builder_type_name,
            .fields = fields,
        },
    };
}

/// Append a character to the builder: append_char(builder, char) -> StringBuilder
fn builderAppendChar(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isBuilder(args[0])) return error.TypeMismatch;
    const current_buffer = getBuffer(args[0]) orelse return error.TypeMismatch;

    const char = switch (args[1]) {
        .char => |c| c,
        else => return error.TypeMismatch,
    };

    // Encode the character as UTF-8
    var char_buf: [4]u8 = undefined;
    const char_len = std.unicode.utf8Encode(char, &char_buf) catch return error.InvalidOperation;

    // Create new buffer with appended character
    const new_len = current_buffer.len + char_len;
    const new_buffer = ctx.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
    @memcpy(new_buffer[0..current_buffer.len], current_buffer);
    @memcpy(new_buffer[current_buffer.len..], char_buf[0..char_len]);

    // Create new builder record with updated buffer
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_buffer", Value{ .string = new_buffer }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = builder_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = builder_type_name,
            .fields = fields,
        },
    };
}

/// Append an integer to the builder: append_int(builder, int) -> StringBuilder
fn builderAppendInt(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isBuilder(args[0])) return error.TypeMismatch;
    const current_buffer = getBuffer(args[0]) orelse return error.TypeMismatch;

    const num = switch (args[1]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // Format the integer
    var int_buf: [40]u8 = undefined;
    const int_slice = std.fmt.bufPrint(&int_buf, "{d}", .{num}) catch return error.OutOfMemory;

    // Create new buffer with appended integer
    const new_len = current_buffer.len + int_slice.len;
    const new_buffer = ctx.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
    @memcpy(new_buffer[0..current_buffer.len], current_buffer);
    @memcpy(new_buffer[current_buffer.len..], int_slice);

    // Create new builder record with updated buffer
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_buffer", Value{ .string = new_buffer }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = builder_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = builder_type_name,
            .fields = fields,
        },
    };
}

/// Append a float to the builder: append_float(builder, float) -> StringBuilder
fn builderAppendFloat(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isBuilder(args[0])) return error.TypeMismatch;
    const current_buffer = getBuffer(args[0]) orelse return error.TypeMismatch;

    const num = switch (args[1]) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => return error.TypeMismatch,
    };

    // Format the float
    var float_buf: [64]u8 = undefined;
    const float_slice = std.fmt.bufPrint(&float_buf, "{d}", .{num}) catch return error.OutOfMemory;

    // Create new buffer with appended float
    const new_len = current_buffer.len + float_slice.len;
    const new_buffer = ctx.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
    @memcpy(new_buffer[0..current_buffer.len], current_buffer);
    @memcpy(new_buffer[current_buffer.len..], float_slice);

    // Create new builder record with updated buffer
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_buffer", Value{ .string = new_buffer }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = builder_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = builder_type_name,
            .fields = fields,
        },
    };
}

/// Get the built string: build(builder) -> String
fn builderBuild(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    if (!isBuilder(args[0])) return error.TypeMismatch;
    const buffer = getBuffer(args[0]) orelse return error.TypeMismatch;

    return Value{ .string = buffer };
}

/// Clear the builder: clear(builder) -> StringBuilder
fn builderClear(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    if (!isBuilder(args[0])) return error.TypeMismatch;

    // Create new empty builder
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_buffer", Value{ .string = "" }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = builder_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = builder_type_name,
            .fields = fields,
        },
    };
}

/// Get the current length: length(builder) -> Int
fn builderLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    if (!isBuilder(args[0])) return error.TypeMismatch;
    const buffer = getBuffer(args[0]) orelse return error.TypeMismatch;

    return Value{ .integer = @intCast(buffer.len) };
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

test "builder new and build" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const builder = try builderNew(ctx, &.{});
    try std.testing.expect(isBuilder(builder));

    const result = try builderBuild(ctx, &.{builder});
    try std.testing.expectEqualStrings("", result.string);
}

test "builder append strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var builder = try builderNew(ctx, &.{});
    builder = try builderAppend(ctx, &.{ builder, Value{ .string = "Hello" } });
    builder = try builderAppend(ctx, &.{ builder, Value{ .string = ", " } });
    builder = try builderAppend(ctx, &.{ builder, Value{ .string = "World!" } });

    const result = try builderBuild(ctx, &.{builder});
    try std.testing.expectEqualStrings("Hello, World!", result.string);
}

test "builder append char" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var builder = try builderNew(ctx, &.{});
    builder = try builderAppendChar(ctx, &.{ builder, Value{ .char = 'H' } });
    builder = try builderAppendChar(ctx, &.{ builder, Value{ .char = 'i' } });

    const result = try builderBuild(ctx, &.{builder});
    try std.testing.expectEqualStrings("Hi", result.string);
}

test "builder append int and float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var builder = try builderNew(ctx, &.{});
    builder = try builderAppend(ctx, &.{ builder, Value{ .string = "num=" } });
    builder = try builderAppendInt(ctx, &.{ builder, Value{ .integer = 42 } });

    const result = try builderBuild(ctx, &.{builder});
    try std.testing.expectEqualStrings("num=42", result.string);
}

test "builder length and clear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var builder = try builderNew(ctx, &.{});
    builder = try builderAppend(ctx, &.{ builder, Value{ .string = "hello" } });

    const len = try builderLength(ctx, &.{builder});
    try std.testing.expectEqual(@as(i128, 5), len.integer);

    const cleared = try builderClear(ctx, &.{builder});
    const cleared_len = try builderLength(ctx, &.{cleared});
    try std.testing.expectEqual(@as(i128, 0), cleared_len.integer);
}
