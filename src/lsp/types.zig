const std = @import("std");

/// JSON-RPC request/notification from the client
pub const Message = struct {
    id: ?Id = null,
    method: []const u8,
    params: ?std.json.Value = null,

    /// Returns true if this is a notification (no id)
    pub fn isNotification(self: Message) bool {
        return self.id == null;
    }
};

/// JSON-RPC message ID (can be integer or string)
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn jsonStringify(self: Id, jws: anytype) !void {
        switch (self) {
            .integer => |v| try jws.write(v),
            .string => |v| try jws.write(v),
        }
    }
};

/// LSP Position (0-indexed line and character)
pub const Position = struct {
    line: u32 = 0,
    character: u32 = 0,
};

/// LSP Range
pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

/// LSP Location
pub const Location = struct {
    uri: []const u8,
    range: Range = .{},
};

/// LSP Diagnostic severity
pub const DiagnosticSeverity = enum(u8) {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,
};

/// LSP Diagnostic
pub const Diagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity = .Error,
    source: []const u8 = "kira",
    message: []const u8,
};

/// LSP TextDocumentIdentifier
pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

/// LSP TextDocumentItem (for didOpen)
pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8 = "kira",
    version: i64 = 0,
    text: []const u8,
};

/// Server capabilities advertised during initialization
pub const ServerCapabilities = struct {
    textDocumentSync: u8 = 1, // Full sync
    hoverProvider: bool = true,
    definitionProvider: bool = true,
    referencesProvider: bool = true,
    completionProvider: ?CompletionOptions = null,
};

pub const CompletionOptions = struct {
    triggerCharacters: []const []const u8 = &.{ ".", ":" },
};

/// Parse a JSON-RPC message from raw JSON bytes
pub fn parseMessage(allocator: std.mem.Allocator, json_bytes: []const u8) !Message {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidRequest;

    const obj = root.object;

    // Extract method (required)
    const method_val = obj.get("method") orelse return error.InvalidRequest;
    if (method_val != .string) return error.InvalidRequest;

    // Extract id (optional — absent for notifications)
    var id: ?Id = null;
    if (obj.get("id")) |id_val| {
        switch (id_val) {
            .integer => |v| {
                id = .{ .integer = v };
            },
            .string => |v| {
                const duped = try allocator.dupe(u8, v);
                id = .{ .string = duped };
            },
            else => return error.InvalidRequest,
        }
    }
    errdefer if (id) |i| switch (i) {
        .string => |s| allocator.free(s),
        .integer => {},
    };

    const method = try allocator.dupe(u8, method_val.string);

    return .{
        .id = id,
        .method = method,
        .params = null, // Params are re-parsed per-method as needed
    };
}

/// Free memory associated with a parsed message
pub fn freeMessage(allocator: std.mem.Allocator, msg: *Message) void {
    allocator.free(msg.method);
    if (msg.id) |id| {
        switch (id) {
            .string => |s| allocator.free(s),
            .integer => {},
        }
    }
}
