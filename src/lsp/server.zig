const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const Transport = @import("transport.zig").Transport;
const TransportError = @import("transport.zig").TransportError;
const types = @import("types.zig");
const features = @import("features.zig");

const log = std.log.scoped(.lsp_server);

/// LSP server state
const State = enum {
    uninitialized,
    initializing,
    running,
    shutdown,
};

/// Kira Language Server
pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    state: State = .uninitialized,
    /// Document store: URI -> source text
    documents: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator, read_ctx: *anyopaque, read_fn: @import("transport.zig").ReadFn, write_ctx: *anyopaque, write_fn: @import("transport.zig").WriteFn) Server {
        return .{
            .allocator = allocator,
            .transport = Transport.init(allocator, read_ctx, read_fn, write_ctx, write_fn),
            .documents = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Create a Server from std.fs.File handles (for stdin/stdout)
    pub fn fromFiles(allocator: Allocator, in_file: *std.fs.File, out_file: *std.fs.File) Server {
        return .{
            .allocator = allocator,
            .transport = Transport.fromFiles(allocator, in_file, out_file),
            .documents = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
    }

    /// Main server loop. Reads messages and dispatches until exit.
    pub fn run(self: *Server) !void {
        while (true) {
            const raw = self.transport.readMessage() catch |err| switch (err) {
                TransportError.ConnectionClosed => return,
                TransportError.OutOfMemory => {
                    log.err("Out of memory reading message", .{});
                    continue;
                },
                else => {
                    log.err("Unrecoverable transport error: {}", .{err});
                    return;
                },
            };
            defer self.allocator.free(raw);

            self.handleRawMessage(raw) catch |err| {
                log.err("Error handling message: {}", .{err});
            };

            if (self.state == .shutdown) return;
        }
    }

    fn handleRawMessage(self: *Server, raw: []const u8) !void {
        // Parse JSON once — all handlers receive the parsed tree
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
            try self.sendErrorResponse(null, -32700, "Parse error");
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            try self.sendErrorResponse(null, -32600, "Invalid request");
            return;
        }
        const obj = parsed.value.object;

        // Extract method
        const method_val = obj.get("method") orelse {
            try self.sendErrorResponse(null, -32600, "Missing method");
            return;
        };
        if (method_val != .string) {
            try self.sendErrorResponse(null, -32600, "Invalid method");
            return;
        }
        const method = method_val.string;

        // Extract id
        const id = extractId(obj);

        // Before initialization, only allow initialize
        if (self.state == .uninitialized and !std.mem.eql(u8, method, "initialize")) {
            if (id != null) {
                try self.sendErrorResponse(id, -32002, "Server not initialized");
            }
            return;
        }

        // Extract params (may be null)
        const params_val = obj.get("params");

        // Dispatch by method
        if (std.mem.eql(u8, method, "initialize")) {
            if (self.state != .uninitialized) {
                try self.sendErrorResponse(id, -32600, "Server already initialized");
                return;
            }
            try self.handleInitialize(id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            self.state = .running;
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try self.handleShutdown(id);
        } else if (std.mem.eql(u8, method, "exit")) {
            self.state = .shutdown;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params_val);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params_val);
        } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
            try self.handleDidSave(params_val);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params_val);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id, params_val);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(id, params_val);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.handleReferences(id, params_val);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id, params_val);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try self.handleDocumentSymbol(id, params_val);
        } else {
            if (id != null) {
                try self.sendErrorResponse(id, -32601, "Method not found");
            }
        }
    }

    fn extractId(obj: std.json.ObjectMap) ?types.Id {
        const id_val = obj.get("id") orelse return null;
        return switch (id_val) {
            .integer => |v| .{ .integer = v },
            .string => |v| .{ .string = v },
            else => null,
        };
    }

    // --- Request handlers ---

    fn handleInitialize(self: *Server, id: ?types.Id) !void {
        self.state = .initializing;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"documentSymbolProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\",\":\"]}},\"serverInfo\":{\"name\":\"kira-lsp\",\"version\":\"0.1.0\"}}}");
        try self.transport.writeMessage(buf.items());
    }

    fn handleShutdown(self: *Server, id: ?types.Id) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":null}");
        try self.transport.writeMessage(buf.items());
    }

    fn handleDidOpen(self: *Server, params_val: ?std.json.Value) !void {
        const params = if (params_val) |p| getObject(p, "textDocument") else null;
        const uri = getString(params, "uri") orelse return;
        const text = getString(params, "text") orelse return;

        try self.updateDocument(uri, text);
    }

    fn handleDidChange(self: *Server, params_val: ?std.json.Value) !void {
        const pv = params_val orelse return;
        const text_doc = getObject(pv, "textDocument") orelse return;
        const uri = getString(text_doc, "uri") orelse return;

        // Full sync (textDocumentSync: 1): contentChanges[0].text has the full document
        if (pv != .object) return;
        const changes_val = pv.object.get("contentChanges") orelse return;
        if (changes_val != .array) return;
        const changes = changes_val.array;
        if (changes.items.len == 0) return;
        const first = changes.items[0];
        if (first != .object) return;
        const text_val = first.object.get("text") orelse return;
        if (text_val != .string) return;

        try self.updateDocument(uri, text_val.string);
    }

    /// Shared logic for didOpen and didChange: update document store and publish diagnostics.
    fn updateDocument(self: *Server, uri: []const u8, text: []const u8) !void {
        const text_owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_owned);

        // getOrPut cannot fail if key already exists (reuses slot), so
        // existing documents are always updated safely without eviction risk.
        const gop = try self.documents.getOrPut(uri);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            // New slot — key_ptr is undefined, must initialize it.
            // getOrPut already succeeded so the slot is reserved.
            gop.key_ptr.* = self.allocator.dupe(u8, uri) catch {
                // Remove the half-initialized slot
                self.documents.removeByPtr(gop.key_ptr);
                return error.OutOfMemory;
            };
        }
        gop.value_ptr.* = text_owned;

        self.publishDiagnostics(gop.key_ptr.*, text_owned) catch |err| {
            log.warn("Failed to publish diagnostics: {}", .{err});
        };
    }

    fn handleDidSave(self: *Server, params_val: ?std.json.Value) !void {
        const params = if (params_val) |p| getObject(p, "textDocument") else null;
        const uri = getString(params, "uri") orelse return;

        if (self.documents.get(uri)) |text| {
            self.publishDiagnostics(uri, text) catch |err| {
                log.warn("Failed to publish diagnostics on save: {}", .{err});
            };
        }
    }

    fn handleDidClose(self: *Server, params_val: ?std.json.Value) !void {
        const params = if (params_val) |p| getObject(p, "textDocument") else null;
        const uri = getString(params, "uri") orelse return;

        if (self.documents.fetchRemove(uri)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    fn handleHover(self: *Server, id: ?types.Id, params_val: ?std.json.Value) !void {
        const rp = self.extractRequestParams(params_val) orelse return try self.sendNullResult(id);
        const pos = rp.position orelse return try self.sendNullResult(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var table = self.analyzeSource(rp.source) orelse return try self.sendNullResult(id);
        defer table.deinit();

        const symbol = features.findSymbolAtPosition(&table, pos.line + 1, pos.character + 1) orelse
            return try self.sendNullResult(id);

        const content = features.getHoverContent(alloc, symbol) catch
            return try self.sendNullResult(id);

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
        try buf.appendEscaped(content);
        try buf.append("\"}}}");
        try self.transport.writeMessage(buf.items());
    }

    fn handleDefinition(self: *Server, id: ?types.Id, params_val: ?std.json.Value) !void {
        const rp = self.extractRequestParams(params_val) orelse return try self.sendNullResult(id);
        const pos = rp.position orelse return try self.sendNullResult(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var table = self.analyzeSource(rp.source) orelse return try self.sendNullResult(id);
        defer table.deinit();

        const symbol = features.findSymbolAtPosition(&table, pos.line + 1, pos.character + 1) orelse
            return try self.sendNullResult(id);

        const def_line = if (symbol.span.start.line > 0) symbol.span.start.line - 1 else 0;
        const def_col = if (symbol.span.start.column > 0) symbol.span.start.column - 1 else 0;

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":{\"uri\":\"");
        try buf.appendEscaped(rp.uri);
        try buf.append("\",\"range\":{\"start\":{\"line\":");
        try buf.appendInt(def_line);
        try buf.append(",\"character\":");
        try buf.appendInt(def_col);
        try buf.append("},\"end\":{\"line\":");
        try buf.appendInt(def_line);
        try buf.append(",\"character\":");
        try buf.appendInt(def_col + @as(u32, @intCast(symbol.name.len)));
        try buf.append("}}}}");
        try self.transport.writeMessage(buf.items());
    }

    fn handleReferences(self: *Server, id: ?types.Id, params_val: ?std.json.Value) !void {
        const rp = self.extractRequestParams(params_val) orelse return try self.sendNullResult(id);
        const pos = rp.position orelse return try self.sendNullResult(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var table = self.analyzeSource(rp.source) orelse return try self.sendNullResult(id);
        defer table.deinit();

        const symbol = features.findSymbolAtPosition(&table, pos.line + 1, pos.character + 1) orelse
            return try self.sendNullResult(id);

        const refs = features.findReferences(alloc, &table, symbol.name) catch
            return try self.sendNullResult(id);

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":[");

        for (refs, 0..) |ref, i| {
            if (i > 0) try buf.append(",");
            const ref_line = if (ref.line > 0) ref.line - 1 else 0;
            const ref_col = if (ref.character > 0) ref.character - 1 else 0;
            try buf.append("{\"uri\":\"");
            try buf.appendEscaped(rp.uri);
            try buf.append("\",\"range\":{\"start\":{\"line\":");
            try buf.appendInt(ref_line);
            try buf.append(",\"character\":");
            try buf.appendInt(ref_col);
            try buf.append("},\"end\":{\"line\":");
            try buf.appendInt(ref_line);
            try buf.append(",\"character\":");
            try buf.appendInt(ref_col + @as(u32, @intCast(symbol.name.len)));
            try buf.append("}}}");
        }

        try buf.append("]}");
        try self.transport.writeMessage(buf.items());
    }

    fn handleCompletion(self: *Server, id: ?types.Id, params_val: ?std.json.Value) !void {
        const rp = self.extractRequestParams(params_val) orelse return try self.sendNullResult(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var table = self.analyzeSource(rp.source) orelse {
            try self.sendKeywordCompletions(id);
            return;
        };
        defer table.deinit();

        // Convert 0-indexed LSP line to 1-indexed Kira line for scope filtering
        const cursor_line: ?u32 = if (rp.position) |pos| pos.line + 1 else null;

        const comp_items = features.getCompletionsAt(alloc, &table, "", cursor_line) catch
            return try self.sendNullResult(id);

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":{\"isIncomplete\":false,\"items\":[");

        for (comp_items, 0..) |item, i| {
            if (i > 0) try buf.append(",");
            try buf.append("{\"label\":\"");
            try buf.appendEscaped(item.label);
            try buf.append("\",\"kind\":");
            try buf.appendInt(@intFromEnum(item.kind));
            if (item.detail) |detail| {
                try buf.append(",\"detail\":\"");
                try buf.appendEscaped(detail);
                try buf.append("\"");
            }
            try buf.append("}");
        }

        try buf.append("]}}");
        try self.transport.writeMessage(buf.items());
    }

    fn handleDocumentSymbol(self: *Server, id: ?types.Id, params_val: ?std.json.Value) !void {
        const pv = params_val orelse return try self.sendNullResult(id);
        const text_doc = getObject(pv, "textDocument") orelse return try self.sendNullResult(id);
        const json_uri = getString(text_doc, "uri") orelse return try self.sendNullResult(id);

        const source = self.documents.get(json_uri) orelse return try self.sendNullResult(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Parse to get AST declarations
        const parse_result = root.parseWithErrors(self.allocator, source);
        var result = parse_result;
        defer result.deinit();

        if (result.hasErrors()) return try self.sendNullResult(id);

        const prog = result.program orelse return try self.sendNullResult(id);

        const doc_symbols = features.getDocumentSymbols(alloc, &prog) catch
            return try self.sendNullResult(id);

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":[");

        for (doc_symbols, 0..) |sym, i| {
            if (i > 0) try buf.append(",");
            try appendDocumentSymbol(&buf, &sym);
        }

        try buf.append("]}");
        try self.transport.writeMessage(buf.items());
    }

    // --- Analysis helpers ---

    const PositionInfo = struct { line: u32, character: u32 };

    const RequestParams = struct {
        uri: []const u8,
        position: ?PositionInfo,
        source: []const u8,
    };

    fn extractRequestParams(self: *Server, params_val: ?std.json.Value) ?RequestParams {
        const pv = params_val orelse return null;
        const text_doc = getObject(pv, "textDocument") orelse return null;
        const json_uri = getString(text_doc, "uri") orelse return null;

        const gop = self.documents.getEntry(json_uri) orelse return null;
        const uri = gop.key_ptr.*;
        const source = gop.value_ptr.*;

        // Extract position if present
        var position: ?PositionInfo = null;
        const pos_obj = getObject(pv, "position");
        if (pos_obj) |p| {
            const line_val = p.get("line");
            const char_val = p.get("character");
            if (line_val != null and char_val != null) {
                const line: u32 = switch (line_val.?) {
                    .integer => |v| if (v >= 0 and v <= std.math.maxInt(u32)) @intCast(v) else return null,
                    else => 0,
                };
                const character: u32 = switch (char_val.?) {
                    .integer => |v| if (v >= 0 and v <= std.math.maxInt(u32)) @intCast(v) else return null,
                    else => 0,
                };
                position = .{ .line = line, .character = character };
            }
        }

        return .{ .uri = uri, .position = position, .source = source };
    }

    /// Run the full analysis pipeline and return a populated symbol table.
    fn analyzeSource(self: *Server, source: []const u8) ?root.SymbolTable {
        const parse_result = root.parseWithErrors(self.allocator, source);
        var result = parse_result;

        if (result.hasErrors()) {
            result.deinit();
            return null;
        }

        if (result.program) |*prog| {
            var table = root.SymbolTable.init(self.allocator);
            root.resolve(self.allocator, prog, &table) catch {
                result.deinit();
                table.deinit();
                return null;
            };

            root.typecheck(self.allocator, prog, &table) catch {
                // Verify type checker cleaned up scope state on error.
                // Scope 0 is global; if we're deeper, the checker leaked scopes.
                if (table.current_scope_id != 0) {
                    log.warn("Type checker left scope at depth {d} after error", .{table.current_scope_id});
                    // Reset to global scope to prevent issues during symbol iteration
                    table.current_scope_id = 0;
                }
            };

            result.deinit();
            return table;
        }

        result.deinit();
        return null;
    }

    fn sendKeywordCompletions(self: *Server, id: ?types.Id) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":{\"isIncomplete\":false,\"items\":[");
        const keywords = [_][]const u8{ "fn", "let", "type", "if", "else", "match", "for", "return", "import", "module", "trait", "impl" };
        for (&keywords, 0..) |kw, i| {
            if (i > 0) try buf.append(",");
            try buf.append("{\"label\":\"");
            try buf.append(kw);
            try buf.append("\",\"kind\":14}");
        }
        try buf.append("]}}");
        try self.transport.writeMessage(buf.items());
    }

    // --- Diagnostics ---

    fn publishDiagnostics(self: *Server, uri: []const u8, source: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
        try buf.appendEscaped(uri);
        try buf.append("\",\"diagnostics\":[");

        var diag_count: usize = 0;

        const parse_result = root.parseWithErrors(self.allocator, source);
        var result = parse_result;
        defer result.deinit();

        if (result.hasErrors()) {
            for (result.errors) |err| {
                if (diag_count > 0) try buf.append(",");
                try appendDiagnosticRange(&buf, 1, err.line, err.column, err.end_line, err.end_column, err.message);
                diag_count += 1;
            }
        } else if (result.program) |*prog| {
            var table = root.SymbolTable.init(self.allocator);
            defer table.deinit();

            // Resolver pass
            var resolver = root.Resolver.init(self.allocator, &table);
            defer resolver.deinit();
            const resolve_ok = if (resolver.resolve(prog)) |_| true else |_| false;

            for (resolver.getDiagnostics()) |diag| {
                const severity = diagKindToLspSeverity(diag.kind);
                if (diag_count > 0) try buf.append(",");
                try appendDiagnosticRange(&buf, severity, diag.span.start.line, diag.span.start.column, diag.span.end.line, diag.span.end.column, diag.message);
                diag_count += 1;
            }

            // TypeChecker pass — only if resolution succeeded
            if (resolve_ok) {
                var checker = root.TypeChecker.init(self.allocator, &table);
                defer checker.deinit();
                checker.check(prog) catch {};
                for (checker.getDiagnostics()) |diag| {
                    const severity = diagKindToLspSeverity(diag.kind);
                    if (diag_count > 0) try buf.append(",");
                    try appendDiagnosticRange(&buf, severity, diag.span.start.line, diag.span.start.column, diag.span.end.line, diag.span.end.column, diag.message);
                    diag_count += 1;
                }
            }
        }

        try buf.append("]}}");
        try self.transport.writeMessage(buf.items());
    }

    // --- Response helpers ---

    fn sendNullResult(self: *Server, id: ?types.Id) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"result\":null}");
        try self.transport.writeMessage(buf.items());
    }

    fn sendErrorResponse(self: *Server, id: ?types.Id, code: i32, message: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = JsonBuf.init(alloc);
        try buf.append("{\"jsonrpc\":\"2.0\",\"id\":");
        try buf.appendId(id);
        try buf.append(",\"error\":{\"code\":");
        try buf.appendSignedInt(code);
        try buf.append(",\"message\":\"");
        try buf.appendEscaped(message);
        try buf.append("\"}}");
        try self.transport.writeMessage(buf.items());
    }

    // --- JSON helpers ---

    fn getObject(val: anytype, key: []const u8) ?std.json.ObjectMap {
        const v = switch (@TypeOf(val)) {
            std.json.Value => val,
            ?std.json.ObjectMap => if (val) |m| (std.json.Value{ .object = m }) else return null,
            else => return null,
        };
        if (v != .object) return null;
        const child = v.object.get(key) orelse return null;
        if (child != .object) return null;
        return child.object;
    }

    fn getString(map: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const m = map orelse return null;
        const val = m.get(key) orelse return null;
        if (val != .string) return null;
        return val.string;
    }
};

/// Dynamically-sized JSON string builder
const JsonBuf = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    alloc: Allocator,

    fn init(alloc: Allocator) JsonBuf {
        return .{ .alloc = alloc };
    }

    fn append(self: *JsonBuf, str: []const u8) !void {
        try self.buf.appendSlice(self.alloc, str);
    }

    fn appendEscaped(self: *JsonBuf, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try self.buf.appendSlice(self.alloc, "\\\""),
                '\\' => try self.buf.appendSlice(self.alloc, "\\\\"),
                '\n' => try self.buf.appendSlice(self.alloc, "\\n"),
                '\r' => try self.buf.appendSlice(self.alloc, "\\r"),
                '\t' => try self.buf.appendSlice(self.alloc, "\\t"),
                else => |b| {
                    if (b < 0x20) {
                        // Control characters
                        var tmp: [6]u8 = undefined;
                        const escaped = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{b}) catch continue;
                        try self.buf.appendSlice(self.alloc, escaped);
                    } else {
                        try self.buf.append(self.alloc, b);
                    }
                },
            }
        }
    }

    fn appendInt(self: *JsonBuf, val: anytype) !void {
        var tmp: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return;
        try self.buf.appendSlice(self.alloc, str);
    }

    fn appendSignedInt(self: *JsonBuf, val: i32) !void {
        var tmp: [16]u8 = undefined;
        const str = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return;
        try self.buf.appendSlice(self.alloc, str);
    }

    fn appendId(self: *JsonBuf, id: ?types.Id) !void {
        if (id) |i| {
            switch (i) {
                .integer => |v| try self.appendSignedInt(@intCast(v)),
                .string => |v| {
                    try self.append("\"");
                    try self.appendEscaped(v);
                    try self.append("\"");
                },
            }
        } else {
            try self.append("null");
        }
    }

    fn items(self: *JsonBuf) []const u8 {
        return self.buf.items;
    }
};

/// Map DiagnosticKind to LSP severity: 1=Error, 2=Warning, 4=Hint
fn diagKindToLspSeverity(kind: anytype) u32 {
    return switch (kind) {
        .err => 1,
        .warning => 2,
        .hint => 4,
    };
}

fn appendDiagnosticRange(buf: *JsonBuf, severity: u32, start_line: u32, start_col: u32, end_line: u32, end_col: u32, message: []const u8) !void {
    const sl = if (start_line > 0) start_line - 1 else 0;
    const sc = if (start_col > 0) start_col - 1 else 0;
    // Use end position if available, otherwise fall back to start + 1 char
    const el = if (end_line > 0) end_line - 1 else sl;
    const ec = if (end_col > 0) end_col - 1 else sc + 1;
    try buf.append("{\"range\":{\"start\":{\"line\":");
    try buf.appendInt(sl);
    try buf.append(",\"character\":");
    try buf.appendInt(sc);
    try buf.append("},\"end\":{\"line\":");
    try buf.appendInt(el);
    try buf.append(",\"character\":");
    try buf.appendInt(ec);
    try buf.append("}},\"severity\":");
    try buf.appendInt(severity);
    try buf.append(",\"source\":\"kira\",\"message\":\"");
    try buf.appendEscaped(message);
    try buf.append("\"}");
}

fn appendDocumentSymbol(buf: *JsonBuf, sym: *const types.DocumentSymbol) !void {
    try buf.append("{\"name\":\"");
    try buf.appendEscaped(sym.name);
    try buf.append("\",\"kind\":");
    try buf.appendInt(@intFromEnum(sym.kind));
    try buf.append(",\"range\":{\"start\":{\"line\":");
    try buf.appendInt(sym.range.start.line);
    try buf.append(",\"character\":");
    try buf.appendInt(sym.range.start.character);
    try buf.append("},\"end\":{\"line\":");
    try buf.appendInt(sym.range.end.line);
    try buf.append(",\"character\":");
    try buf.appendInt(sym.range.end.character);
    try buf.append("}},\"selectionRange\":{\"start\":{\"line\":");
    try buf.appendInt(sym.selection_range.start.line);
    try buf.append(",\"character\":");
    try buf.appendInt(sym.selection_range.start.character);
    try buf.append("},\"end\":{\"line\":");
    try buf.appendInt(sym.selection_range.end.line);
    try buf.append(",\"character\":");
    try buf.appendInt(sym.selection_range.end.character);
    try buf.append("}}");

    if (sym.children.len > 0) {
        try buf.append(",\"children\":[");
        for (sym.children, 0..) |*child, i| {
            if (i > 0) try buf.append(",");
            try appendDocumentSymbol(buf, child);
        }
        try buf.append("]");
    }

    try buf.append("}");
}

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

fn frameLspMessages(comptime messages: []const []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (messages) |msg| {
            result = result ++ std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ msg.len, msg });
        }
        return result;
    }
}

// --- Tests ---

test "Server handles initialize and responds with capabilities" {
    const input = comptime frameLspMessages(&.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });

    var stream = TestStream{ .data = input };
    defer stream.deinit();

    var server = Server.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );
    defer server.deinit();

    try server.run();

    const output = stream.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "textDocumentSync") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hoverProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "kira-lsp") != null);
}

test "Server rejects requests before initialize" {
    const input = comptime frameLspMessages(&.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });

    var stream = TestStream{ .data = input };
    defer stream.deinit();

    var server = Server.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );
    defer server.deinit();

    try server.run();

    const output = stream.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "not initialized") != null);
}

test "Server handles shutdown and exit" {
    const input = comptime frameLspMessages(&.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });

    var stream = TestStream{ .data = input };
    defer stream.deinit();

    var server = Server.init(
        std.testing.allocator,
        @ptrCast(&stream),
        TestStream.readFn,
        @ptrCast(&stream),
        TestStream.writeFn,
    );
    defer server.deinit();

    try server.run();

    const output = stream.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"result\":null") != null);
}
