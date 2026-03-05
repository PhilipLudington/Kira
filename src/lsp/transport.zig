const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.lsp_transport);

/// Errors that can occur during LSP transport operations
pub const TransportError = error{
    MalformedHeader,
    MissingContentLength,
    InvalidContentLength,
    ConnectionClosed,
    OutOfMemory,
    MessageTooLarge,
};

/// Maximum allowed message size (10 MB)
const max_message_size = 10 * 1024 * 1024;
/// Content-Length header prefix
const content_length_prefix = "Content-Length: ";

/// Generic read function type: reads into buffer, returns bytes read (0 = EOF)
pub const ReadFn = *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize;
/// Generic write function type: writes all bytes
pub const WriteFn = *const fn (ctx: *anyopaque, data: []const u8) anyerror!void;

/// LSP JSON-RPC transport layer.
/// Reads and writes LSP messages framed with Content-Length headers.
pub const Transport = struct {
    allocator: Allocator,
    read_ctx: *anyopaque,
    read_fn: ReadFn,
    write_ctx: *anyopaque,
    write_fn: WriteFn,

    pub fn init(allocator: Allocator, read_ctx: *anyopaque, read_fn: ReadFn, write_ctx: *anyopaque, write_fn: WriteFn) Transport {
        return .{
            .allocator = allocator,
            .read_ctx = read_ctx,
            .read_fn = read_fn,
            .write_ctx = write_ctx,
            .write_fn = write_fn,
        };
    }

    /// Create a Transport from std.fs.File handles (for stdin/stdout)
    pub fn fromFiles(allocator: Allocator, in_file: *std.fs.File, out_file: *std.fs.File) Transport {
        return .{
            .allocator = allocator,
            .read_ctx = @ptrCast(in_file),
            .read_fn = fileRead,
            .write_ctx = @ptrCast(out_file),
            .write_fn = fileWrite,
        };
    }

    fn fileRead(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const file: *std.fs.File = @alignCast(@ptrCast(ctx));
        return file.read(buf);
    }

    fn fileWrite(ctx: *anyopaque, data: []const u8) anyerror!void {
        const file: *std.fs.File = @alignCast(@ptrCast(ctx));
        return file.writeAll(data);
    }

    /// Read one LSP message. Caller owns the returned slice.
    pub fn readMessage(self: *Transport) TransportError![]u8 {
        const content_length = self.readHeaders() catch |err| {
            return switch (err) {
                TransportError.MissingContentLength => TransportError.MissingContentLength,
                TransportError.InvalidContentLength => TransportError.InvalidContentLength,
                TransportError.MalformedHeader => TransportError.MalformedHeader,
                else => TransportError.ConnectionClosed,
            };
        };

        if (content_length > max_message_size) {
            return TransportError.MessageTooLarge;
        }

        const body = self.allocator.alloc(u8, content_length) catch return TransportError.OutOfMemory;
        errdefer self.allocator.free(body);

        var total_read: usize = 0;
        while (total_read < content_length) {
            const n = self.read_fn(self.read_ctx, body[total_read..]) catch return TransportError.ConnectionClosed;
            if (n == 0) return TransportError.ConnectionClosed;
            total_read += n;
        }

        return body;
    }

    /// Write an LSP message with Content-Length framing.
    /// Builds the full frame in memory before writing to avoid partial frames on error.
    pub fn writeMessage(self: *Transport, body: []const u8) TransportError!void {
        var len_buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;

        // Build complete frame: "Content-Length: N\r\n\r\n<body>"
        const frame_header_len = content_length_prefix.len + len_str.len + 4; // 4 = "\r\n\r\n"
        const frame = self.allocator.alloc(u8, frame_header_len + body.len) catch return TransportError.OutOfMemory;
        defer self.allocator.free(frame);

        var pos: usize = 0;
        @memcpy(frame[pos..][0..content_length_prefix.len], content_length_prefix);
        pos += content_length_prefix.len;
        @memcpy(frame[pos..][0..len_str.len], len_str);
        pos += len_str.len;
        @memcpy(frame[pos..][0..4], "\r\n\r\n");
        pos += 4;
        @memcpy(frame[pos..][0..body.len], body);

        self.write_fn(self.write_ctx, frame) catch return TransportError.ConnectionClosed;
    }

    /// Parse headers and return the Content-Length value.
    fn readHeaders(self: *Transport) !usize {
        var content_length: ?usize = null;
        var line_buf: [4096]u8 = undefined;

        while (true) {
            const line = try self.readHeaderLine(&line_buf);

            // Empty line = end of headers
            if (line.len == 0) break;

            // Parse Content-Length header (case-insensitive prefix)
            if (std.ascii.startsWithIgnoreCase(line, content_length_prefix)) {
                const value_str = std.mem.trimRight(u8, line[content_length_prefix.len..], " \t");
                content_length = std.fmt.parseInt(usize, value_str, 10) catch {
                    return TransportError.InvalidContentLength;
                };
            }
            // Other headers (Content-Type, etc.) are ignored per LSP spec
        }

        return content_length orelse TransportError.MissingContentLength;
    }

    /// Read a single header line (terminated by \r\n). Returns the line without the terminator.
    fn readHeaderLine(self: *Transport, buf: []u8) ![]const u8 {
        var len: usize = 0;
        while (len < buf.len) {
            var byte: [1]u8 = undefined;
            const n = try self.read_fn(self.read_ctx, &byte);
            if (n == 0) return error.EndOfStream;

            if (byte[0] == '\n') {
                // Strip trailing \r
                if (len > 0 and buf[len - 1] == '\r') {
                    return buf[0 .. len - 1];
                }
                return buf[0..len];
            }
            buf[len] = byte[0];
            len += 1;
        }
        return TransportError.MalformedHeader;
    }
};

// --- Test helpers ---

const TestStream = struct {
    data: []const u8,
    pos: usize = 0,
    output: std.ArrayListUnmanaged(u8) = .{},

    fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *TestStream = @alignCast(@ptrCast(ctx));
        if (self.pos >= self.data.len) return 0;
        const n = @min(buf.len, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *TestStream = @alignCast(@ptrCast(ctx));
        try self.output.appendSlice(std.testing.allocator, data);
    }

    fn deinit(self: *TestStream) void {
        self.output.deinit(std.testing.allocator);
    }

    fn written(self: *TestStream) []const u8 {
        return self.output.items;
    }
};

test "Transport reads valid message" {
    var stream = TestStream{ .data = "Content-Length: 15\r\n\r\n{\"id\":1,\"ok\":1}" };
    defer stream.deinit();

    var transport = Transport.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );

    const msg = try transport.readMessage();
    defer std.testing.allocator.free(msg);

    try std.testing.expectEqualStrings("{\"id\":1,\"ok\":1}", msg);
}

test "Transport writes properly framed response" {
    var stream = TestStream{ .data = "" };
    defer stream.deinit();

    var transport = Transport.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    try transport.writeMessage(body);

    const expected = "Content-Length: 38\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}";
    try std.testing.expectEqualStrings(expected, stream.written());
}

test "Transport rejects missing Content-Length" {
    var stream = TestStream{ .data = "Content-Type: application/json\r\n\r\n{}" };
    defer stream.deinit();

    var transport = Transport.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );

    const result = transport.readMessage();
    try std.testing.expectError(TransportError.MissingContentLength, result);
}

test "Transport rejects invalid Content-Length" {
    var stream = TestStream{ .data = "Content-Length: abc\r\n\r\n{}" };
    defer stream.deinit();

    var transport = Transport.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );

    const result = transport.readMessage();
    try std.testing.expectError(TransportError.InvalidContentLength, result);
}

test "Transport handles connection closed during body" {
    var stream = TestStream{ .data = "Content-Length: 100\r\n\r\nhello" };
    defer stream.deinit();

    var transport = Transport.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );

    const result = transport.readMessage();
    try std.testing.expectError(TransportError.ConnectionClosed, result);
}

test "Transport handles multiple headers" {
    var stream = TestStream{ .data = "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}" };
    defer stream.deinit();

    var transport = Transport.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );

    const msg = try transport.readMessage();
    defer std.testing.allocator.free(msg);

    try std.testing.expectEqualStrings("{}", msg);
}
