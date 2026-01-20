//! std.io - I/O effects for the Kira standard library.
//!
//! Provides effectful I/O operations:
//!   - print: Print to stdout (no newline)
//!   - println: Print to stdout with newline
//!   - read_line: Read a line from stdin

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;

/// Create the std.io module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    // All I/O functions are effects
    try fields.put(allocator, "print", root.makeEffectBuiltin("print", &ioPrint));
    try fields.put(allocator, "println", root.makeEffectBuiltin("println", &ioPrintln));
    try fields.put(allocator, "read_line", root.makeEffectBuiltin("read_line", &ioReadLine));

    // Additional I/O functions
    try fields.put(allocator, "eprint", root.makeEffectBuiltin("eprint", &ioEprint));
    try fields.put(allocator, "eprintln", root.makeEffectBuiltin("eprintln", &ioEprintln));

    return Value{
        .record = .{
            .type_name = "std.io",
            .fields = fields,
        },
    };
}

/// Print to stdout without newline: print(args...) -> void
fn ioPrint(allocator: Allocator, args: []const Value) InterpreterError!Value {
    const stdout = std.fs.File.stdout();

    for (args) |arg| {
        const str = switch (arg) {
            .string => |s| s,
            else => arg.toString(allocator) catch return error.OutOfMemory,
        };
        stdout.writeAll(str) catch return error.InvalidOperation;
    }

    return Value{ .void = {} };
}

/// Print to stdout with newline: println(args...) -> void
fn ioPrintln(allocator: Allocator, args: []const Value) InterpreterError!Value {
    _ = try ioPrint(allocator, args);
    const stdout = std.fs.File.stdout();
    stdout.writeAll("\n") catch return error.InvalidOperation;
    return Value{ .void = {} };
}

/// Read a line from stdin: read_line() -> Result[string, string]
fn ioReadLine(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 0) return error.ArityMismatch;

    const stdin = std.fs.File.stdin();

    // Use readToEndAlloc with a reasonable max size for a single line
    // Since we're reading from stdin, we need a different approach
    // Read byte by byte until we hit a newline
    var line_buffer = std.ArrayListUnmanaged(u8){};
    defer line_buffer.deinit(allocator);

    var read_buf: [1]u8 = undefined;
    while (true) {
        const bytes_read = stdin.read(&read_buf) catch {
            if (line_buffer.items.len > 0) {
                // Return what we have
                const result = allocator.create(Value) catch return error.OutOfMemory;
                const owned = line_buffer.toOwnedSlice(allocator) catch return error.OutOfMemory;
                result.* = Value{ .string = owned };
                return Value{ .ok = result };
            }
            const err_val = allocator.create(Value) catch return error.OutOfMemory;
            err_val.* = Value{ .string = "read error" };
            return Value{ .err = err_val };
        };

        if (bytes_read == 0) {
            // EOF
            if (line_buffer.items.len > 0) {
                const result = allocator.create(Value) catch return error.OutOfMemory;
                const owned = line_buffer.toOwnedSlice(allocator) catch return error.OutOfMemory;
                result.* = Value{ .string = owned };
                return Value{ .ok = result };
            }
            const err_val = allocator.create(Value) catch return error.OutOfMemory;
            err_val.* = Value{ .string = "end of input" };
            return Value{ .err = err_val };
        }

        if (read_buf[0] == '\n') {
            // Found newline, return the line
            break;
        }

        line_buffer.append(allocator, read_buf[0]) catch return error.OutOfMemory;
    }

    // Success - return the line
    const result = allocator.create(Value) catch return error.OutOfMemory;
    const owned = line_buffer.toOwnedSlice(allocator) catch return error.OutOfMemory;
    result.* = Value{ .string = owned };
    return Value{ .ok = result };
}

/// Print to stderr without newline: eprint(args...) -> void
fn ioEprint(allocator: Allocator, args: []const Value) InterpreterError!Value {
    const stderr = std.fs.File.stderr();

    for (args) |arg| {
        const str = switch (arg) {
            .string => |s| s,
            else => arg.toString(allocator) catch return error.OutOfMemory,
        };
        stderr.writeAll(str) catch return error.InvalidOperation;
    }

    return Value{ .void = {} };
}

/// Print to stderr with newline: eprintln(args...) -> void
fn ioEprintln(allocator: Allocator, args: []const Value) InterpreterError!Value {
    _ = try ioEprint(allocator, args);
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\n") catch return error.InvalidOperation;
    return Value{ .void = {} };
}

// Note: Tests for I/O functions are integration tests that require
// actual stdin/stdout interaction, which is difficult in unit tests.
// These will be tested through the interpreter integration tests.

test "io module creation" {
    const allocator = std.testing.allocator;

    const module = try createModule(allocator);
    defer {
        var fields = module.record.fields;
        fields.deinit(allocator);
    }

    // Verify module structure
    try std.testing.expect(module.record.fields.contains("print"));
    try std.testing.expect(module.record.fields.contains("println"));
    try std.testing.expect(module.record.fields.contains("read_line"));
}
