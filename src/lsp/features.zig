const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const pretty_printer = @import("../ast/pretty_printer.zig");
const Symbol = root.Symbol;
const SymbolTable = root.SymbolTable;
const Span = root.Span;

/// Result of a hover request
pub const HoverResult = struct {
    contents: []const u8,
};

/// Result of a definition request
pub const DefinitionResult = struct {
    line: u32,
    character: u32,
};

/// Result of a reference lookup
pub const ReferenceResult = struct {
    line: u32,
    character: u32,
};

/// Result of a completion request
pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: ?[]const u8 = null,
};

pub const CompletionKind = enum(u8) {
    variable = 6,
    function = 3,
    type_def = 22, // Struct
    trait_def = 8, // Interface
    module = 9,
    keyword = 14,
};

/// Find a symbol at the given line/column (1-indexed).
/// Scans all symbols in the table for one whose span contains the position.
pub fn findSymbolAtPosition(table: *SymbolTable, line: u32, col: u32) ?*const Symbol {
    const symbols = table.symbols.items;
    var best: ?*const Symbol = null;
    var best_size: usize = std.math.maxInt(usize);

    for (symbols) |*sym| {
        const span = sym.span;
        if (positionInSpan(line, col, span)) {
            const size = spanSize(span);
            if (size < best_size) {
                best = sym;
                best_size = size;
            }
        }
    }

    return best;
}

/// Get hover information for a symbol
pub fn getHoverContent(allocator: Allocator, symbol: *const Symbol) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    switch (symbol.kind) {
        .variable => |v| {
            try buf.appendSlice(allocator, "```kira\nlet ");
            try buf.appendSlice(allocator, symbol.name);
            try buf.appendSlice(allocator, ": ");
            const type_str = try pretty_printer.formatType(allocator, v.binding_type.*);
            defer allocator.free(type_str);
            try buf.appendSlice(allocator, type_str);
            try buf.appendSlice(allocator, "\n```");
        },
        .function => |f| {
            try buf.appendSlice(allocator, "```kira\nfn ");
            try buf.appendSlice(allocator, symbol.name);
            try buf.appendSlice(allocator, "(");
            for (f.parameter_names, 0..) |name, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, name);
                try buf.appendSlice(allocator, ": ");
                if (i < f.parameter_types.len) {
                    const t = try pretty_printer.formatType(allocator, f.parameter_types[i].*);
                    defer allocator.free(t);
                    try buf.appendSlice(allocator, t);
                }
            }
            try buf.appendSlice(allocator, ") -> ");
            const ret = try pretty_printer.formatType(allocator, f.return_type.*);
            defer allocator.free(ret);
            try buf.appendSlice(allocator, ret);
            try buf.appendSlice(allocator, "\n```");
        },
        .type_def => {
            try buf.appendSlice(allocator, "```kira\ntype ");
            try buf.appendSlice(allocator, symbol.name);
            try buf.appendSlice(allocator, "\n```");
        },
        .trait_def => {
            try buf.appendSlice(allocator, "```kira\ntrait ");
            try buf.appendSlice(allocator, symbol.name);
            try buf.appendSlice(allocator, "\n```");
        },
        .module => {
            try buf.appendSlice(allocator, "```kira\nmodule ");
            try buf.appendSlice(allocator, symbol.name);
            try buf.appendSlice(allocator, "\n```");
        },
        .type_param, .import_alias => {
            try buf.appendSlice(allocator, symbol.name);
        },
    }

    // Append doc comment if available
    if (symbol.doc_comment) |doc| {
        try buf.appendSlice(allocator, "\n\n");
        try buf.appendSlice(allocator, doc);
    }

    return try buf.toOwnedSlice(allocator);
}

/// Find all symbols with the same name (for references)
pub fn findReferences(allocator: Allocator, table: *SymbolTable, name: []const u8) ![]ReferenceResult {
    var results = std.ArrayListUnmanaged(ReferenceResult){};
    errdefer results.deinit(allocator);

    const symbols = table.symbols.items;
    for (symbols) |sym| {
        if (std.mem.eql(u8, sym.name, name)) {
            try results.append(allocator, .{
                .line = sym.span.start.line,
                .character = sym.span.start.column,
            });
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Get completion items for symbols visible at the given scope
pub fn getCompletions(allocator: Allocator, table: *SymbolTable, prefix: []const u8) ![]CompletionItem {
    var results = std.ArrayListUnmanaged(CompletionItem){};
    errdefer results.deinit(allocator);

    const symbols = table.symbols.items;
    for (symbols) |sym| {
        // Skip anonymous/internal symbols
        if (sym.name.len == 0) continue;
        if (sym.name[0] == '_') continue;

        // Match prefix
        if (prefix.len > 0 and !std.mem.startsWith(u8, sym.name, prefix)) continue;

        const kind: CompletionKind = switch (sym.kind) {
            .variable => .variable,
            .function => .function,
            .type_def => .type_def,
            .trait_def => .trait_def,
            .module => .module,
            .type_param, .import_alias => .variable,
        };

        try results.append(allocator, .{
            .label = sym.name,
            .kind = kind,
            .detail = null,
        });
    }

    // Add keywords
    const keywords = [_][]const u8{
        "fn",     "let",  "type",   "module", "import", "pub",
        "effect", "trait", "impl",  "const",  "if",     "else",
        "match",  "for",  "return", "break",  "true",   "false",
        "self",   "Self", "and",    "or",     "not",    "is",
        "in",     "as",   "where",
    };

    for (&keywords) |kw| {
        if (prefix.len > 0 and !std.mem.startsWith(u8, kw, prefix)) continue;
        try results.append(allocator, .{
            .label = kw,
            .kind = .keyword,
            .detail = null,
        });
    }

    return try results.toOwnedSlice(allocator);
}

// --- Helpers ---

fn positionInSpan(line: u32, col: u32, span: Span) bool {
    // Position is after span start
    if (line < span.start.line) return false;
    if (line == span.start.line and col < span.start.column) return false;
    // Position is before span end
    if (line > span.end.line) return false;
    if (line == span.end.line and col > span.end.column) return false;
    return true;
}

fn spanSize(span: Span) usize {
    if (span.end.offset > span.start.offset) {
        return span.end.offset - span.start.offset;
    }
    // Zero-size spans (synthetic symbols) should not win over real spans
    return std.math.maxInt(usize);
}

// --- Tests ---

test "positionInSpan basic" {
    const span = Span{
        .start = .{ .line = 1, .column = 5, .offset = 4 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };
    try std.testing.expect(positionInSpan(1, 5, span));
    try std.testing.expect(positionInSpan(1, 7, span));
    try std.testing.expect(positionInSpan(1, 10, span));
    try std.testing.expect(!positionInSpan(1, 4, span));
    try std.testing.expect(!positionInSpan(1, 11, span));
    try std.testing.expect(!positionInSpan(2, 5, span));
}
