//! std.fs - Filesystem effects for the Kira standard library.
//!
//! Provides effectful filesystem operations:
//!   - read_file: Read entire file contents
//!   - write_file: Write contents to file
//!   - exists: Check if path exists
//!   - remove: Delete a file

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;

/// Create the std.fs module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    // All filesystem functions are effects
    try fields.put(allocator, "read_file", root.makeEffectBuiltin("read_file", &fsReadFile));
    try fields.put(allocator, "write_file", root.makeEffectBuiltin("write_file", &fsWriteFile));
    try fields.put(allocator, "exists", root.makeEffectBuiltin("exists", &fsExists));
    try fields.put(allocator, "remove", root.makeEffectBuiltin("remove", &fsRemove));

    // Additional filesystem functions
    try fields.put(allocator, "append_file", root.makeEffectBuiltin("append_file", &fsAppendFile));
    try fields.put(allocator, "read_dir", root.makeEffectBuiltin("read_dir", &fsReadDir));
    try fields.put(allocator, "is_file", root.makeEffectBuiltin("is_file", &fsIsFile));
    try fields.put(allocator, "is_dir", root.makeEffectBuiltin("is_dir", &fsIsDir));
    try fields.put(allocator, "create_dir", root.makeEffectBuiltin("create_dir", &fsCreateDir));

    return Value{
        .record = .{
            .type_name = "std.fs",
            .fields = fields,
        },
    };
}

/// Maximum file size to read (16 MB)
const max_file_size = 16 * 1024 * 1024;

/// Read entire file: read_file(path) -> Result[string, string]
fn fsReadFile(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return makeError(allocator, @errorName(err));
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, max_file_size) catch |err| {
        return makeError(allocator, @errorName(err));
    };

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = contents };
    return Value{ .ok = result };
}

/// Write contents to file: write_file(path, contents) -> Result[void, string]
fn fsWriteFile(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const contents = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return makeError(allocator, @errorName(err));
    };
    defer file.close();

    file.writeAll(contents) catch |err| {
        return makeError(allocator, @errorName(err));
    };

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .void = {} };
    return Value{ .ok = result };
}

/// Check if path exists: exists(path) -> bool
fn fsExists(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const exists = std.fs.cwd().access(path, .{}) != error.FileNotFound;
    return Value{ .boolean = exists };
}

/// Delete a file: remove(path) -> Result[void, string]
fn fsRemove(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    std.fs.cwd().deleteFile(path) catch |err| {
        return makeError(allocator, @errorName(err));
    };

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .void = {} };
    return Value{ .ok = result };
}

/// Append to file: append_file(path, contents) -> Result[void, string]
fn fsAppendFile(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const contents = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| {
        if (err == error.FileNotFound) {
            // Create new file if doesn't exist
            const new_file = std.fs.cwd().createFile(path, .{}) catch |create_err| {
                return makeError(allocator, @errorName(create_err));
            };
            defer new_file.close();
            new_file.writeAll(contents) catch |write_err| {
                return makeError(allocator, @errorName(write_err));
            };
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .void = {} };
            return Value{ .ok = result };
        }
        return makeError(allocator, @errorName(err));
    };
    defer file.close();

    // Seek to end and write
    file.seekFromEnd(0) catch |err| {
        return makeError(allocator, @errorName(err));
    };

    file.writeAll(contents) catch |err| {
        return makeError(allocator, @errorName(err));
    };

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .void = {} };
    return Value{ .ok = result };
}

/// Read directory entries: read_dir(path) -> Result[array of string, string]
fn fsReadDir(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return makeError(allocator, @errorName(err));
    };
    defer dir.close();

    var entries = std.ArrayListUnmanaged(Value){};
    errdefer entries.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next() catch |err| {
        return makeError(allocator, @errorName(err));
    }) |entry| {
        const name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
        entries.append(allocator, Value{ .string = name }) catch return error.OutOfMemory;
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .array = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .ok = result };
}

/// Check if path is a file: is_file(path) -> bool
fn fsIsFile(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const stat = std.fs.cwd().statFile(path) catch {
        return Value{ .boolean = false };
    };

    return Value{ .boolean = stat.kind == .file };
}

/// Check if path is a directory: is_dir(path) -> bool
fn fsIsDir(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    var dir = std.fs.cwd().openDir(path, .{}) catch {
        return Value{ .boolean = false };
    };
    dir.close();

    return Value{ .boolean = true };
}

/// Create directory: create_dir(path) -> Result[void, string]
fn fsCreateDir(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const path = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    std.fs.cwd().makeDir(path) catch |err| {
        return makeError(allocator, @errorName(err));
    };

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .void = {} };
    return Value{ .ok = result };
}

/// Helper to create an Err value with a string message
fn makeError(allocator: Allocator, message: []const u8) InterpreterError!Value {
    const err_val = allocator.create(Value) catch return error.OutOfMemory;
    err_val.* = Value{ .string = message };
    return Value{ .err = err_val };
}

// ============================================================================
// Tests
// ============================================================================

test "fs module creation" {
    const allocator = std.testing.allocator;

    const module = try createModule(allocator);
    defer {
        var fields = module.record.fields;
        fields.deinit(allocator);
    }

    // Verify module structure
    try std.testing.expect(module.record.fields.contains("read_file"));
    try std.testing.expect(module.record.fields.contains("write_file"));
    try std.testing.expect(module.record.fields.contains("exists"));
    try std.testing.expect(module.record.fields.contains("remove"));
}

test "fs exists" {
    const allocator = std.testing.allocator;

    // Test with a file that should exist (the test file itself)
    const exists = try fsExists(allocator, &.{Value{ .string = "src/stdlib/fs.zig" }});
    try std.testing.expect(exists.boolean);

    // Test with a file that shouldn't exist
    const not_exists = try fsExists(allocator, &.{Value{ .string = "nonexistent_file_12345.txt" }});
    try std.testing.expect(!not_exists.boolean);
}

test "fs is_dir" {
    const allocator = std.testing.allocator;

    // Test with a directory that should exist
    const is_dir_result = try fsIsDir(allocator, &.{Value{ .string = "src" }});
    try std.testing.expect(is_dir_result.boolean);

    // Test with a file (not a directory)
    const is_file_dir = try fsIsDir(allocator, &.{Value{ .string = "src/stdlib/fs.zig" }});
    try std.testing.expect(!is_file_dir.boolean);
}
