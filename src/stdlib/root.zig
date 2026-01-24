//! Kira Standard Library
//!
//! This module provides the standard library functions for the Kira language,
//! organized into namespaced modules:
//!   - std.list: List operations (map, filter, fold, etc.)
//!   - std.option: Option type operations (map, and_then, unwrap_or, etc.)
//!   - std.result: Result type operations (map, map_err, and_then, etc.)
//!   - std.string: String operations (length, split, trim, etc.)
//!   - std.io: I/O effects (print, println, read_line)
//!   - std.fs: Filesystem effects (read_file, write_file, exists, remove)

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");

const Value = value_mod.Value;
const Environment = value_mod.Environment;
const InterpreterError = value_mod.InterpreterError;
pub const BuiltinContext = Value.BuiltinContext;

// Import stdlib submodules
pub const list = @import("list.zig");
pub const option = @import("option.zig");
pub const result = @import("result.zig");
pub const string = @import("string.zig");
pub const int = @import("int.zig");
pub const float = @import("float.zig");
pub const io = @import("io.zig");
pub const fs = @import("fs.zig");
pub const time = @import("time.zig");
pub const assert = @import("assert.zig");

/// Register all standard library modules in the environment.
/// Each module is registered as a record with its functions as fields.
pub fn registerStdlib(allocator: Allocator, env: *Environment) !void {
    // Create std namespace record with all submodules
    var std_fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer std_fields.deinit(allocator);

    // Register each submodule as a record in the std namespace
    try std_fields.put(allocator, "list", try list.createModule(allocator));
    try std_fields.put(allocator, "option", try option.createModule(allocator));
    try std_fields.put(allocator, "result", try result.createModule(allocator));
    try std_fields.put(allocator, "string", try string.createModule(allocator));
    try std_fields.put(allocator, "int", try int.createModule(allocator));
    try std_fields.put(allocator, "float", try float.createModule(allocator));
    try std_fields.put(allocator, "io", try io.createModule(allocator));
    try std_fields.put(allocator, "fs", try fs.createModule(allocator));
    try std_fields.put(allocator, "time", try time.createModule(allocator));
    try std_fields.put(allocator, "assert", try assert.createModule(allocator));

    const std_module = Value{
        .record = .{
            .type_name = "std",
            .fields = std_fields,
        },
    };

    try env.define("std", std_module, false);
}

/// Helper to create a builtin function value
pub fn makeBuiltin(
    name: []const u8,
    func: *const fn (ctx: BuiltinContext, args: []const Value) InterpreterError!Value,
) Value {
    return Value{
        .function = .{
            .name = name,
            .parameters = &.{},
            .body = .{ .builtin = func },
            .captured_env = null,
            .is_effect = false,
        },
    };
}

/// Helper to create an effect function value (for IO operations)
pub fn makeEffectBuiltin(
    name: []const u8,
    func: *const fn (ctx: BuiltinContext, args: []const Value) InterpreterError!Value,
) Value {
    return Value{
        .function = .{
            .name = name,
            .parameters = &.{},
            .body = .{ .builtin = func },
            .captured_env = null,
            .is_effect = true,
        },
    };
}

test {
    _ = list;
    _ = option;
    _ = result;
    _ = string;
    _ = int;
    _ = float;
    _ = io;
    _ = fs;
    _ = time;
    _ = assert;
}
