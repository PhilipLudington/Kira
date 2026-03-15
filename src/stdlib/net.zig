//! std.net - TCP networking effects for the Kira standard library.
//!
//! Provides effectful TCP networking operations:
//!   - tcp_listen: Bind a TCP server on a port
//!   - accept: Accept a connection from a listener
//!   - read: Read data from a connection
//!   - write: Write data to a connection
//!   - close: Close a connection

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

// Handle tables: map integer handles to Zig networking objects.
// Value cannot hold arbitrary Zig pointers, so we store handles as integers
// and look up the real objects here.

var next_handle: i128 = 1;
var listeners: std.AutoHashMapUnmanaged(i128, std.net.Server) = .{};
var connections: std.AutoHashMapUnmanaged(i128, std.net.Stream) = .{};

/// Create the std.net module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "tcp_listen", root.makeEffectBuiltin("tcp_listen", &netTcpListen));
    try fields.put(allocator, "accept", root.makeEffectBuiltin("accept", &netAccept));
    try fields.put(allocator, "read", root.makeEffectBuiltin("read", &netRead));
    try fields.put(allocator, "write", root.makeEffectBuiltin("write", &netWrite));
    try fields.put(allocator, "close", root.makeEffectBuiltin("close", &netClose));

    return Value{
        .record = .{
            .type_name = "std.net",
            .fields = fields,
        },
    };
}

/// tcp_listen(port: int) -> Result[TcpListener, string]
/// Binds a TCP server on 0.0.0.0:port and returns a listener record.
fn netTcpListen(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const port_val = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    if (port_val < 0 or port_val > 65535) {
        return makeError(ctx.allocator, "invalid port number");
    }

    const port: u16 = @intCast(port_val);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = address.listen(.{
        .reuse_address = true,
    }) catch |err| {
        return makeError(ctx.allocator, @errorName(err));
    };

    const handle = next_handle;
    next_handle += 1;

    listeners.put(std.heap.page_allocator, handle, server) catch {
        server.deinit();
        return makeError(ctx.allocator, "out of memory for handle table");
    };

    // Return Ok({ port: int, _handle: int })
    var rec_fields = std.StringArrayHashMapUnmanaged(Value){};
    rec_fields.put(ctx.allocator, "port", Value{ .integer = port_val }) catch return error.OutOfMemory;
    rec_fields.put(ctx.allocator, "_handle", Value{ .integer = handle }) catch return error.OutOfMemory;

    const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .record = .{ .type_name = "TcpListener", .fields = rec_fields } };
    return Value{ .ok = result };
}

/// accept(listener) -> Result[TcpConnection, string]
/// Accepts a connection from the listener. Blocks until a client connects.
fn netAccept(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const listener_rec = switch (args[0]) {
        .record => |r| r,
        else => return error.TypeMismatch,
    };

    const handle_val = listener_rec.fields.get("_handle") orelse return error.TypeMismatch;
    const handle = switch (handle_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const server = listeners.getPtr(handle) orelse {
        return makeError(ctx.allocator, "invalid listener handle");
    };

    const conn = server.accept() catch |err| {
        return makeError(ctx.allocator, @errorName(err));
    };

    const conn_handle = next_handle;
    next_handle += 1;

    connections.put(std.heap.page_allocator, conn_handle, conn.stream) catch {
        conn.stream.close();
        return makeError(ctx.allocator, "out of memory for handle table");
    };

    // Return Ok({ id: int, _handle: int })
    var rec_fields = std.StringArrayHashMapUnmanaged(Value){};
    rec_fields.put(ctx.allocator, "id", Value{ .integer = conn_handle }) catch return error.OutOfMemory;
    rec_fields.put(ctx.allocator, "_handle", Value{ .integer = conn_handle }) catch return error.OutOfMemory;

    const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .record = .{ .type_name = "TcpConnection", .fields = rec_fields } };
    return Value{ .ok = result };
}

/// read(conn) -> Result[string, string]
/// Reads available data from a connection. Returns Ok(string) or Err(string).
fn netRead(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const conn_rec = switch (args[0]) {
        .record => |r| r,
        else => return error.TypeMismatch,
    };

    const handle_val = conn_rec.fields.get("_handle") orelse return error.TypeMismatch;
    const handle = switch (handle_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const stream = connections.getPtr(handle) orelse {
        return makeError(ctx.allocator, "invalid connection handle");
    };

    var buf: [8192]u8 = undefined;
    const n = stream.read(&buf) catch |err| {
        return makeError(ctx.allocator, @errorName(err));
    };

    if (n == 0) {
        return makeError(ctx.allocator, "connection_closed");
    }

    const data = ctx.allocator.dupe(u8, buf[0..n]) catch return error.OutOfMemory;

    const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = data };
    return Value{ .ok = result };
}

/// write(conn, data: string) -> Result[bool, string]
/// Writes string bytes to the connection stream.
fn netWrite(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const conn_rec = switch (args[0]) {
        .record => |r| r,
        else => return error.TypeMismatch,
    };

    const data = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const handle_val = conn_rec.fields.get("_handle") orelse return error.TypeMismatch;
    const handle = switch (handle_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const stream = connections.getPtr(handle) orelse {
        return makeError(ctx.allocator, "invalid connection handle");
    };

    stream.writeAll(data) catch |err| {
        return makeError(ctx.allocator, @errorName(err));
    };

    const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .boolean = true };
    return Value{ .ok = result };
}

/// close(conn) -> Result[bool, string]
/// Closes a connection stream and removes its handle.
fn netClose(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const conn_rec = switch (args[0]) {
        .record => |r| r,
        else => return error.TypeMismatch,
    };

    const handle_val = conn_rec.fields.get("_handle") orelse return error.TypeMismatch;
    const handle = switch (handle_val) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    // Try connections first, then listeners
    if (connections.fetchRemove(handle)) |entry| {
        var stream = entry.value;
        stream.close();
    } else if (listeners.fetchRemove(handle)) |entry| {
        var server = entry.value;
        server.deinit();
    } else {
        return makeError(ctx.allocator, "invalid handle");
    }

    const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .boolean = true };
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

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
        .env_args = null,
    };
}

test "net module creation" {
    const allocator = std.testing.allocator;

    const module = try createModule(allocator);
    defer {
        var fields = module.record.fields;
        fields.deinit(allocator);
    }

    try std.testing.expect(module.record.fields.contains("tcp_listen"));
    try std.testing.expect(module.record.fields.contains("accept"));
    try std.testing.expect(module.record.fields.contains("read"));
    try std.testing.expect(module.record.fields.contains("write"));
    try std.testing.expect(module.record.fields.contains("close"));
}

test "tcp_listen arity mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // No args
    const result = netTcpListen(ctx, &.{});
    try std.testing.expectError(error.ArityMismatch, result);

    // Too many args
    const result2 = netTcpListen(ctx, &.{ Value{ .integer = 8080 }, Value{ .integer = 1 } });
    try std.testing.expectError(error.ArityMismatch, result2);
}

test "tcp_listen type mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netTcpListen(ctx, &.{Value{ .string = "8080" }});
    try std.testing.expectError(error.TypeMismatch, result);
}

test "tcp_listen invalid port" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Negative port
    const r1 = try netTcpListen(ctx, &.{Value{ .integer = -1 }});
    try std.testing.expect(r1 == .err);
    allocator.destroy(r1.err);

    // Port too high
    const r2 = try netTcpListen(ctx, &.{Value{ .integer = 70000 }});
    try std.testing.expect(r2 == .err);
    allocator.destroy(r2.err);
}

test "accept arity mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netAccept(ctx, &.{});
    try std.testing.expectError(error.ArityMismatch, result);
}

test "accept type mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netAccept(ctx, &.{Value{ .integer = 1 }});
    try std.testing.expectError(error.TypeMismatch, result);
}

test "read arity mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netRead(ctx, &.{});
    try std.testing.expectError(error.ArityMismatch, result);
}

test "write arity mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netWrite(ctx, &.{});
    try std.testing.expectError(error.ArityMismatch, result);
}

test "close arity mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netClose(ctx, &.{});
    try std.testing.expectError(error.ArityMismatch, result);
}

test "close invalid handle" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Build a fake connection record with an invalid handle
    var rec_fields = std.StringArrayHashMapUnmanaged(Value){};
    defer rec_fields.deinit(allocator);
    try rec_fields.put(allocator, "_handle", Value{ .integer = 999999 });

    const r = try netClose(ctx, &.{Value{ .record = .{ .type_name = "TcpConnection", .fields = rec_fields } }});
    try std.testing.expect(r == .err);
    allocator.destroy(r.err);
}
