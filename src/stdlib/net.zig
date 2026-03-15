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
    try fields.put(allocator, "http_request", root.makeEffectBuiltin("http_request", &netHttpRequest));

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
/// Reads an HTTP request from a connection using buffered accumulation.
/// Reads until \r\n\r\n (end of headers), then reads Content-Length body bytes.
/// Returns Ok(string) with the complete request, or Err(string) on failure.
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

    // Set a read timeout (30 seconds) to avoid blocking forever
    const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Accumulate data into a dynamic buffer
    var accum = std.ArrayListUnmanaged(u8){};
    defer accum.deinit(ctx.allocator);

    var buf: [4096]u8 = undefined;

    // Phase 1: Read until we find \r\n\r\n (end of HTTP headers)
    var header_end: ?usize = null;
    while (header_end == null) {
        const n = stream.read(&buf) catch |err| {
            if (accum.items.len == 0) {
                return makeError(ctx.allocator, @errorName(err));
            }
            // Return what we have so far
            break;
        };

        if (n == 0) {
            if (accum.items.len == 0) {
                return makeError(ctx.allocator, "connection_closed");
            }
            break; // Client closed, return what we have
        }

        accum.appendSlice(ctx.allocator, buf[0..n]) catch return error.OutOfMemory;

        // Check for \r\n\r\n in the accumulated data
        if (accum.items.len >= 4) {
            const search_start = if (accum.items.len > n + 3) accum.items.len - n - 3 else 0;
            if (std.mem.indexOfPos(u8, accum.items, search_start, "\r\n\r\n")) |pos| {
                header_end = pos + 4;
            }
        }

        // Safety limit: 1MB max request
        if (accum.items.len > 1024 * 1024) {
            return makeError(ctx.allocator, "request_too_large");
        }
    }

    // Phase 2: If we found headers, check for Content-Length and read body
    if (header_end) |hend| {
        const headers = accum.items[0..hend];
        if (parseContentLength(headers)) |content_length| {
            const total_needed = hend + content_length;
            while (accum.items.len < total_needed) {
                const n = stream.read(&buf) catch break;
                if (n == 0) break;
                accum.appendSlice(ctx.allocator, buf[0..n]) catch return error.OutOfMemory;
            }
        }
    }

    const data = ctx.allocator.dupe(u8, accum.items) catch return error.OutOfMemory;

    const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = data };
    return Value{ .ok = result };
}

/// Parse Content-Length from HTTP headers.
fn parseContentLength(headers: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, pos, "\r\n") orelse break;
        const line = headers[pos..line_end];
        pos = line_end + 2;

        // Case-insensitive match for "Content-Length:"
        if (line.len > 16 and matchHeaderName(line[0..16], "content-length: ")) {
            const val_str = std.mem.trim(u8, line[16..], " ");
            return std.fmt.parseInt(usize, val_str, 10) catch null;
        }
        if (line.len > 15 and matchHeaderName(line[0..15], "content-length:")) {
            const val_str = std.mem.trim(u8, line[15..], " ");
            return std.fmt.parseInt(usize, val_str, 10) catch null;
        }
    }
    return null;
}

/// Case-insensitive header name match.
fn matchHeaderName(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, e| {
        if (std.ascii.toLower(a) != std.ascii.toLower(e)) return false;
    }
    return true;
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

// ============================================================================
// HTTP Client Implementation
// ============================================================================

const UrlParts = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    is_https: bool,
};

/// Parse a URL into host, port, path components.
/// Handles: http://host/path, http://host:port/path?query, https://...
fn parseUrlParts(url: []const u8) ?UrlParts {
    var is_https = false;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, "http://")) {
        rest = url["http://".len..];
    } else if (std.mem.startsWith(u8, url, "https://")) {
        rest = url["https://".len..];
        is_https = true;
    } else {
        return null;
    }

    // Split host[:port] from path[?query]
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..path_start];
    var path: []const u8 = if (path_start < rest.len) rest[path_start..] else "/";

    // Strip fragment
    if (std.mem.indexOfScalar(u8, path, '#')) |frag| {
        path = path[0..frag];
    }
    if (path.len == 0) path = "/";

    // Split host:port
    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        const host = host_port[0..colon];
        const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return null;
        return .{ .host = host, .port = port, .path = path, .is_https = is_https };
    } else {
        if (host_port.len == 0) return null;
        const default_port: u16 = if (is_https) 443 else 80;
        return .{ .host = host_port, .port = default_port, .path = path, .is_https = is_https };
    }
}

/// http_request(request_record) -> Result[Response, HttpError]
/// Makes an outbound HTTP/1.1 request and returns the response.
fn netHttpRequest(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const req_rec = switch (args[0]) {
        .record => |r| r,
        else => return error.TypeMismatch,
    };

    // Extract method name from variant
    const method_name = switch (req_rec.fields.get("method") orelse return error.TypeMismatch) {
        .variant => |v| v.name,
        else => return error.TypeMismatch,
    };

    // Extract URL
    const url = switch (req_rec.fields.get("url") orelse return error.TypeMismatch) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Extract body (Option[string])
    const body: ?[]const u8 = blk: {
        const body_val = req_rec.fields.get("body") orelse break :blk null;
        switch (body_val) {
            .some => |ptr| switch (ptr.*) {
                .string => |s| break :blk s,
                else => break :blk null,
            },
            .none => break :blk null,
            else => break :blk null,
        }
    };

    // Parse URL
    const parsed = parseUrlParts(url) orelse {
        return makeHttpError(ctx.allocator, "InvalidUrl", "Could not parse URL");
    };

    // HTTPS not yet supported
    if (parsed.is_https) {
        return makeHttpError(ctx.allocator, "TlsError", "HTTPS not yet supported");
    }

    // Connect to remote host
    const stream = std.net.tcpConnectToHost(ctx.allocator, parsed.host, parsed.port) catch |err| {
        return makeHttpError(ctx.allocator, "ConnectionFailed", @errorName(err));
    };
    defer stream.close();

    // Set read timeout (30 seconds)
    const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Build HTTP request
    var req_buf = std.ArrayListUnmanaged(u8){};
    defer req_buf.deinit(ctx.allocator);

    // Request line: METHOD /path HTTP/1.1\r\n
    req_buf.appendSlice(ctx.allocator, method_name) catch return error.OutOfMemory;
    req_buf.append(ctx.allocator, ' ') catch return error.OutOfMemory;
    req_buf.appendSlice(ctx.allocator, parsed.path) catch return error.OutOfMemory;
    req_buf.appendSlice(ctx.allocator, " HTTP/1.1\r\n") catch return error.OutOfMemory;

    // Host header
    req_buf.appendSlice(ctx.allocator, "Host: ") catch return error.OutOfMemory;
    req_buf.appendSlice(ctx.allocator, parsed.host) catch return error.OutOfMemory;
    if ((!parsed.is_https and parsed.port != 80) or (parsed.is_https and parsed.port != 443)) {
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, ":{d}", .{parsed.port}) catch unreachable;
        req_buf.appendSlice(ctx.allocator, port_str) catch return error.OutOfMemory;
    }
    req_buf.appendSlice(ctx.allocator, "\r\n") catch return error.OutOfMemory;

    // User headers from request record (cons/nil list)
    var has_user_agent = false;
    {
        var header_list = req_rec.fields.get("headers") orelse Value{ .nil = {} };
        while (true) {
            switch (header_list) {
                .cons => |c| {
                    const header_rec = switch (c.head.*) {
                        .record => |r| r,
                        else => break,
                    };
                    const hname = switch (header_rec.fields.get("name") orelse break) {
                        .string => |s| s,
                        else => break,
                    };
                    const hvalue = switch (header_rec.fields.get("value") orelse break) {
                        .string => |s| s,
                        else => break,
                    };
                    if (matchHeaderName(hname, "user-agent")) has_user_agent = true;
                    req_buf.appendSlice(ctx.allocator, hname) catch return error.OutOfMemory;
                    req_buf.appendSlice(ctx.allocator, ": ") catch return error.OutOfMemory;
                    req_buf.appendSlice(ctx.allocator, hvalue) catch return error.OutOfMemory;
                    req_buf.appendSlice(ctx.allocator, "\r\n") catch return error.OutOfMemory;
                    header_list = c.tail.*;
                },
                .nil => break,
                else => break,
            }
        }
    }

    // Default User-Agent
    if (!has_user_agent) {
        req_buf.appendSlice(ctx.allocator, "User-Agent: kira/1.0\r\n") catch return error.OutOfMemory;
    }

    // Content-Length if we have a body
    if (body) |b| {
        var len_buf: [48]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "Content-Length: {d}\r\n", .{b.len}) catch unreachable;
        req_buf.appendSlice(ctx.allocator, len_str) catch return error.OutOfMemory;
    }

    // Connection: close so server closes after responding
    req_buf.appendSlice(ctx.allocator, "Connection: close\r\n") catch return error.OutOfMemory;

    // End of headers
    req_buf.appendSlice(ctx.allocator, "\r\n") catch return error.OutOfMemory;

    // Body
    if (body) |b| {
        req_buf.appendSlice(ctx.allocator, b) catch return error.OutOfMemory;
    }

    // Send request
    stream.writeAll(req_buf.items) catch |err| {
        return makeHttpError(ctx.allocator, "ConnectionFailed", @errorName(err));
    };

    // Read response
    var resp_buf = std.ArrayListUnmanaged(u8){};
    defer resp_buf.deinit(ctx.allocator);

    var read_buf: [4096]u8 = undefined;

    // Read until we have complete headers
    var header_end: ?usize = null;
    while (header_end == null) {
        const n = stream.read(&read_buf) catch |err| {
            if (resp_buf.items.len == 0) {
                return makeHttpError(ctx.allocator, "ConnectionFailed", @errorName(err));
            }
            break;
        };
        if (n == 0) break;
        resp_buf.appendSlice(ctx.allocator, read_buf[0..n]) catch return error.OutOfMemory;

        if (resp_buf.items.len >= 4) {
            const search_start = if (resp_buf.items.len > n + 3) resp_buf.items.len - n - 3 else 0;
            if (std.mem.indexOfPos(u8, resp_buf.items, search_start, "\r\n\r\n")) |pos| {
                header_end = pos + 4;
            }
        }

        if (resp_buf.items.len > 10 * 1024 * 1024) {
            return makeHttpError(ctx.allocator, "InvalidResponse", "Response too large");
        }
    }

    const hend = header_end orelse {
        return makeHttpError(ctx.allocator, "InvalidResponse", "No complete HTTP response received");
    };

    // Parse status line
    const status_line_end = std.mem.indexOf(u8, resp_buf.items, "\r\n") orelse {
        return makeHttpError(ctx.allocator, "InvalidResponse", "No status line");
    };
    const status_code = parseStatusCode(resp_buf.items[0..status_line_end]) orelse {
        return makeHttpError(ctx.allocator, "InvalidResponse", "Invalid status line");
    };

    // Read body based on Content-Length or until EOF
    const headers_data = resp_buf.items[0..hend];
    if (parseContentLength(headers_data)) |content_length| {
        const total_needed = hend + content_length;
        while (resp_buf.items.len < total_needed) {
            const n = stream.read(&read_buf) catch break;
            if (n == 0) break;
            resp_buf.appendSlice(ctx.allocator, read_buf[0..n]) catch return error.OutOfMemory;
        }
    } else {
        // No Content-Length: read until EOF (Connection: close)
        while (true) {
            const n = stream.read(&read_buf) catch break;
            if (n == 0) break;
            resp_buf.appendSlice(ctx.allocator, read_buf[0..n]) catch return error.OutOfMemory;
            if (resp_buf.items.len > 10 * 1024 * 1024) break;
        }
    }

    // Build response record
    const resp_body = ctx.allocator.dupe(u8, resp_buf.items[hend..]) catch return error.OutOfMemory;
    const resp_headers = try buildResponseHeaders(ctx.allocator, resp_buf.items[status_line_end + 2 .. hend - 2]);
    const status_val = statusCodeToVariant(ctx.allocator, status_code) catch return error.OutOfMemory;

    var resp_fields = std.StringArrayHashMapUnmanaged(Value){};
    resp_fields.put(ctx.allocator, "status", status_val) catch return error.OutOfMemory;
    resp_fields.put(ctx.allocator, "headers", resp_headers) catch return error.OutOfMemory;
    resp_fields.put(ctx.allocator, "body", Value{ .string = resp_body }) catch return error.OutOfMemory;

    const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .record = .{ .type_name = "Response", .fields = resp_fields } };
    return Value{ .ok = result };
}

/// Create an HttpError variant wrapped in Err.
fn makeHttpError(allocator: Allocator, variant_name: []const u8, message: []const u8) InterpreterError!Value {
    const variant_val = allocator.create(Value) catch return error.OutOfMemory;
    if (std.mem.eql(u8, variant_name, "Timeout")) {
        variant_val.* = Value{ .variant = .{ .name = variant_name, .fields = null } };
    } else {
        const tuple = allocator.alloc(Value, 1) catch return error.OutOfMemory;
        tuple[0] = Value{ .string = message };
        variant_val.* = Value{ .variant = .{ .name = variant_name, .fields = .{ .tuple = tuple } } };
    }
    return Value{ .err = variant_val };
}

/// Parse "HTTP/1.x NNN reason" → status code
fn parseStatusCode(line: []const u8) ?u16 {
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const after = line[first_space + 1 ..];
    const code_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    return std.fmt.parseInt(u16, after[0..code_end], 10) catch null;
}

/// Map HTTP status code to Kira Status variant value.
fn statusCodeToVariant(allocator: Allocator, code: u16) !Value {
    const name: ?[]const u8 = switch (code) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "NoContent",
        301 => "MovedPermanently",
        302 => "Found",
        304 => "NotModified",
        400 => "BadRequest",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "NotFound",
        405 => "MethodNotAllowed",
        409 => "Conflict",
        500 => "InternalError",
        501 => "NotImplemented",
        502 => "BadGateway",
        503 => "ServiceUnavailable",
        else => null,
    };

    if (name) |n| {
        return Value{ .variant = .{ .name = n, .fields = null } };
    }

    // Custom(code)
    const tuple = try allocator.alloc(Value, 1);
    tuple[0] = Value{ .integer = @intCast(code) };
    return Value{ .variant = .{ .name = "Custom", .fields = .{ .tuple = tuple } } };
}

/// Parse response headers into a Kira List[Header] (cons/nil chain).
fn buildResponseHeaders(allocator: Allocator, header_data: []const u8) InterpreterError!Value {
    var result = Value{ .nil = {} };

    var pos: usize = 0;
    while (pos < header_data.len) {
        const line_end = std.mem.indexOfPos(u8, header_data, pos, "\r\n") orelse break;
        const line = header_data[pos..line_end];
        pos = line_end + 2;

        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = allocator.dupe(u8, std.mem.trim(u8, line[0..colon], " ")) catch return error.OutOfMemory;
        const hvalue = allocator.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " ")) catch return error.OutOfMemory;

        var hfields = std.StringArrayHashMapUnmanaged(Value){};
        hfields.put(allocator, "name", Value{ .string = hname }) catch return error.OutOfMemory;
        hfields.put(allocator, "value", Value{ .string = hvalue }) catch return error.OutOfMemory;

        const head_val = allocator.create(Value) catch return error.OutOfMemory;
        head_val.* = Value{ .record = .{ .type_name = "Header", .fields = hfields } };

        const tail_val = allocator.create(Value) catch return error.OutOfMemory;
        tail_val.* = result;

        result = Value{ .cons = .{ .head = head_val, .tail = tail_val } };
    }

    return result;
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
    try std.testing.expect(module.record.fields.contains("http_request"));
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

// ============================================================================
// HTTP Client Tests
// ============================================================================

test "parseUrlParts basic http" {
    const result = parseUrlParts("http://example.com/path") orelse unreachable;
    try std.testing.expectEqualStrings("example.com", result.host);
    try std.testing.expectEqual(@as(u16, 80), result.port);
    try std.testing.expectEqualStrings("/path", result.path);
    try std.testing.expect(!result.is_https);
}

test "parseUrlParts with port" {
    const result = parseUrlParts("http://localhost:8080/api/data") orelse unreachable;
    try std.testing.expectEqualStrings("localhost", result.host);
    try std.testing.expectEqual(@as(u16, 8080), result.port);
    try std.testing.expectEqualStrings("/api/data", result.path);
}

test "parseUrlParts https" {
    const result = parseUrlParts("https://example.com/secure") orelse unreachable;
    try std.testing.expectEqualStrings("example.com", result.host);
    try std.testing.expectEqual(@as(u16, 443), result.port);
    try std.testing.expect(result.is_https);
}

test "parseUrlParts no path" {
    const result = parseUrlParts("http://example.com") orelse unreachable;
    try std.testing.expectEqualStrings("example.com", result.host);
    try std.testing.expectEqualStrings("/", result.path);
}

test "parseUrlParts with query" {
    const result = parseUrlParts("http://example.com/search?q=hello&page=1") orelse unreachable;
    try std.testing.expectEqualStrings("/search?q=hello&page=1", result.path);
}

test "parseUrlParts with fragment stripped" {
    const result = parseUrlParts("http://example.com/page#section") orelse unreachable;
    try std.testing.expectEqualStrings("/page", result.path);
}

test "parseUrlParts invalid scheme" {
    try std.testing.expect(parseUrlParts("ftp://example.com") == null);
    try std.testing.expect(parseUrlParts("example.com") == null);
}

test "parseUrlParts empty host" {
    try std.testing.expect(parseUrlParts("http:///path") == null);
}

test "parseStatusCode valid" {
    try std.testing.expectEqual(@as(?u16, 200), parseStatusCode("HTTP/1.1 200 OK"));
    try std.testing.expectEqual(@as(?u16, 404), parseStatusCode("HTTP/1.1 404 Not Found"));
    try std.testing.expectEqual(@as(?u16, 301), parseStatusCode("HTTP/1.0 301 Moved Permanently"));
}

test "parseStatusCode invalid" {
    try std.testing.expect(parseStatusCode("not a status line") == null);
    try std.testing.expect(parseStatusCode("") == null);
}

test "statusCodeToVariant known codes" {
    const allocator = std.testing.allocator;

    const ok_val = try statusCodeToVariant(allocator, 200);
    try std.testing.expectEqualStrings("OK", ok_val.variant.name);
    try std.testing.expect(ok_val.variant.fields == null);

    const not_found = try statusCodeToVariant(allocator, 404);
    try std.testing.expectEqualStrings("NotFound", not_found.variant.name);
}

test "statusCodeToVariant custom code" {
    const allocator = std.testing.allocator;

    const val = try statusCodeToVariant(allocator, 418);
    defer allocator.free(val.variant.fields.?.tuple);
    try std.testing.expectEqualStrings("Custom", val.variant.name);
    try std.testing.expectEqual(@as(i128, 418), val.variant.fields.?.tuple[0].integer);
}

test "buildResponseHeaders parses headers" {
    const allocator = std.testing.allocator;
    const data = "Content-Type: text/html\r\nX-Custom: hello\r\n";

    const result = try buildResponseHeaders(allocator, data);
    // Result is a cons list (built in reverse order)
    try std.testing.expect(result == .cons);

    // First cons cell (last header due to reverse order)
    const h1 = result.cons.head.record;
    try std.testing.expectEqualStrings("X-Custom", h1.fields.get("name").?.string);
    try std.testing.expectEqualStrings("hello", h1.fields.get("value").?.string);

    // Second cons cell
    const tail1 = result.cons.tail.*;
    try std.testing.expect(tail1 == .cons);
    const h2 = tail1.cons.head.record;
    try std.testing.expectEqualStrings("Content-Type", h2.fields.get("name").?.string);
    try std.testing.expectEqualStrings("text/html", h2.fields.get("value").?.string);

    // Tail is nil
    try std.testing.expect(tail1.cons.tail.* == .nil);

    // Cleanup
    allocator.free(h1.fields.get("name").?.string);
    allocator.free(h1.fields.get("value").?.string);
    var h1_fields = result.cons.head.record.fields;
    h1_fields.deinit(allocator);
    allocator.destroy(result.cons.head);
    allocator.free(h2.fields.get("name").?.string);
    allocator.free(h2.fields.get("value").?.string);
    var h2_fields = tail1.cons.head.record.fields;
    h2_fields.deinit(allocator);
    allocator.destroy(tail1.cons.head);
    allocator.destroy(result.cons.tail);
    allocator.destroy(tail1.cons.tail);
}

test "http_request arity mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netHttpRequest(ctx, &.{});
    try std.testing.expectError(error.ArityMismatch, result);
}

test "http_request type mismatch" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const result = netHttpRequest(ctx, &.{Value{ .integer = 42 }});
    try std.testing.expectError(error.TypeMismatch, result);
}
