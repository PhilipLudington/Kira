const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const pretty_printer = @import("../ast/pretty_printer.zig");
const types = @import("types.zig");
const Symbol = root.Symbol;
const SymbolTable = root.SymbolTable;
const Span = root.Span;
const Declaration = root.Declaration;
const Program = root.Program;
const DocumentSymbol = types.DocumentSymbol;
const SymbolKind = types.SymbolKind;

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

/// Get completion items for symbols visible at the given position.
/// Filters out symbols defined after the cursor, deduplicates by name
/// (keeping the closest definition), and adds type detail info.
pub fn getCompletions(allocator: Allocator, table: *SymbolTable, prefix: []const u8) ![]CompletionItem {
    return getCompletionsAt(allocator, table, prefix, null);
}

/// Position-aware completion: only show symbols defined before cursor_line (1-indexed).
pub fn getCompletionsAt(allocator: Allocator, table: *SymbolTable, prefix: []const u8, cursor_line: ?u32) ![]CompletionItem {
    var results = std.ArrayListUnmanaged(CompletionItem){};
    errdefer results.deinit(allocator);

    // Track seen names to deduplicate — later definitions (closer to cursor) win
    var seen = std.StringHashMapUnmanaged(usize){}; // name -> index in results
    defer seen.deinit(allocator);

    const symbols = table.symbols.items;
    for (symbols) |sym| {
        // Skip anonymous/internal symbols
        if (sym.name.len == 0) continue;
        if (sym.name[0] == '_') continue;

        // Skip symbols defined after cursor position
        if (cursor_line) |cl| {
            if (sym.span.start.line > cl and !isTopLevel(sym)) continue;
        }

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

        const detail = getCompletionDetail(allocator, &sym) catch null;

        const item = CompletionItem{
            .label = sym.name,
            .kind = kind,
            .detail = detail,
        };

        // Deduplicate: later definitions shadow earlier ones
        if (seen.get(sym.name)) |idx| {
            results.items[idx] = item;
        } else {
            try seen.put(allocator, sym.name, results.items.len);
            try results.append(allocator, item);
        }
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
        if (!seen.contains(kw)) {
            try results.append(allocator, .{
                .label = kw,
                .kind = .keyword,
                .detail = null,
            });
        }
    }

    return try results.toOwnedSlice(allocator);
}

/// Top-level declarations (functions, types, traits) are always visible regardless of position.
pub fn isTopLevel(sym: Symbol) bool {
    return switch (sym.kind) {
        .function, .type_def, .trait_def, .module, .import_alias => true,
        .variable, .type_param => false,
    };
}

/// Format a brief type description for completion detail.
fn getCompletionDetail(allocator: Allocator, sym: *const Symbol) !?[]const u8 {
    switch (sym.kind) {
        .variable => |v| {
            const type_str = try pretty_printer.formatType(allocator, v.binding_type.*);
            return type_str;
        },
        .function => |f| {
            var buf = std.ArrayListUnmanaged(u8){};
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, "(");
            for (f.parameter_names, 0..) |name, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, name);
                if (i < f.parameter_types.len) {
                    try buf.appendSlice(allocator, ": ");
                    const t = try pretty_printer.formatType(allocator, f.parameter_types[i].*);
                    defer allocator.free(t);
                    try buf.appendSlice(allocator, t);
                }
            }
            try buf.appendSlice(allocator, ") -> ");
            const ret = try pretty_printer.formatType(allocator, f.return_type.*);
            defer allocator.free(ret);
            try buf.appendSlice(allocator, ret);
            return try buf.toOwnedSlice(allocator);
        },
        .type_def => return "type",
        .trait_def => return "trait",
        .module => return "module",
        .type_param => return "type param",
        .import_alias => return "import",
    }
}

/// Build document symbols from a parsed program's declarations.
pub fn getDocumentSymbols(allocator: Allocator, program: *const Program) ![]const DocumentSymbol {
    var results = std.ArrayListUnmanaged(DocumentSymbol){};
    errdefer results.deinit(allocator);

    for (program.declarations) |decl| {
        if (try declToSymbol(allocator, &decl)) |sym| {
            try results.append(allocator, sym);
        }
    }

    return try results.toOwnedSlice(allocator);
}

fn declToSymbol(allocator: Allocator, decl: *const Declaration) !?DocumentSymbol {
    const range = spanToLspRange(decl.span);
    switch (decl.kind) {
        .function_decl => |f| {
            return .{
                .name = f.name,
                .kind = .function,
                .range = range,
                .selection_range = range,
                .children = &.{},
            };
        },
        .type_decl => |t| {
            var children = std.ArrayListUnmanaged(DocumentSymbol){};
            errdefer children.deinit(allocator);

            switch (t.definition) {
                .sum_type => |sum| {
                    for (sum.variants) |variant| {
                        const vrange = spanToLspRange(variant.span);
                        try children.append(allocator, .{
                            .name = variant.name,
                            .kind = .enum_member,
                            .range = vrange,
                            .selection_range = vrange,
                            .children = &.{},
                        });
                    }
                },
                .product_type => |prod| {
                    for (prod.fields) |field| {
                        const frange = spanToLspRange(field.span);
                        try children.append(allocator, .{
                            .name = field.name,
                            .kind = .variable,
                            .range = frange,
                            .selection_range = frange,
                            .children = &.{},
                        });
                    }
                },
                .type_alias => {},
            }

            return .{
                .name = t.name,
                .kind = .struct_kind,
                .range = range,
                .selection_range = range,
                .children = try children.toOwnedSlice(allocator),
            };
        },
        .trait_decl => |t| {
            var children = std.ArrayListUnmanaged(DocumentSymbol){};
            errdefer children.deinit(allocator);

            for (t.methods) |method| {
                const mrange = spanToLspRange(method.span);
                try children.append(allocator, .{
                    .name = method.name,
                    .kind = .method,
                    .range = mrange,
                    .selection_range = mrange,
                    .children = &.{},
                });
            }

            return .{
                .name = t.name,
                .kind = .interface,
                .range = range,
                .selection_range = range,
                .children = try children.toOwnedSlice(allocator),
            };
        },
        .impl_block => |impl| {
            var children = std.ArrayListUnmanaged(DocumentSymbol){};
            errdefer children.deinit(allocator);

            for (impl.methods) |method| {
                try children.append(allocator, .{
                    .name = method.name,
                    .kind = .method,
                    .range = range, // FunctionDecl has no span; use parent
                    .selection_range = range,
                    .children = &.{},
                });
            }

            // Build impl name: "impl TraitName for Type" or "impl Type"
            const impl_name = if (impl.trait_name) |tn| tn else "impl";

            return .{
                .name = impl_name,
                .kind = .struct_kind,
                .range = range,
                .selection_range = range,
                .children = try children.toOwnedSlice(allocator),
            };
        },
        .const_decl => |c| {
            return .{
                .name = c.name,
                .kind = .constant,
                .range = range,
                .selection_range = range,
                .children = &.{},
            };
        },
        .let_decl => |l| {
            return .{
                .name = l.name,
                .kind = .variable,
                .range = range,
                .selection_range = range,
                .children = &.{},
            };
        },
        .module_decl => |m| {
            const mod_name = if (m.path.len > 0) m.path[m.path.len - 1] else "module";
            return .{
                .name = mod_name,
                .kind = .module,
                .range = range,
                .selection_range = range,
                .children = &.{},
            };
        },
        .test_decl => |t| {
            return .{
                .name = t.name,
                .kind = .event,
                .range = range,
                .selection_range = range,
                .children = &.{},
            };
        },
        .bench_decl => |b| {
            return .{
                .name = b.name,
                .kind = .event,
                .range = range,
                .selection_range = range,
                .children = &.{},
            };
        },
        .import_decl => return null, // Imports are not shown in document outline
    }
}

fn spanToLspRange(span: Span) types.Range {
    return .{
        .start = .{
            .line = if (span.start.line > 0) span.start.line - 1 else 0,
            .character = if (span.start.column > 0) span.start.column - 1 else 0,
        },
        .end = .{
            .line = if (span.end.line > 0) span.end.line - 1 else 0,
            .character = if (span.end.column > 0) span.end.column - 1 else 0,
        },
    };
}

/// Result of signature help analysis
pub const SignatureContext = struct {
    function_name: []const u8,
    active_param: u32,
};

/// Analyze source text around cursor to find function call context.
/// Returns the function name and active parameter index if cursor is inside a call.
/// Positions are 0-indexed (LSP convention).
pub fn findSignatureContext(source: []const u8, line: u32, character: u32) ?SignatureContext {
    // Find cursor offset in source
    var offset: usize = 0;
    var current_line: u32 = 0;
    while (offset < source.len and current_line < line) {
        if (source[offset] == '\n') current_line += 1;
        offset += 1;
    }
    offset += character;
    if (offset > source.len) return null;

    // Walk backward from cursor to find unmatched '('
    var depth: i32 = 0;
    var comma_count: u32 = 0;
    var pos = offset;
    while (pos > 0) {
        pos -= 1;
        const c = source[pos];
        if (c == ')') {
            depth += 1;
        } else if (c == '(') {
            if (depth == 0) {
                // Found unmatched open paren — extract function name before it
                var name_end = pos;
                // Skip whitespace before '('
                while (name_end > 0 and (source[name_end - 1] == ' ' or source[name_end - 1] == '\t')) {
                    name_end -= 1;
                }
                var name_start = name_end;
                while (name_start > 0 and isIdentChar(source[name_start - 1])) {
                    name_start -= 1;
                }
                if (name_start == name_end) return null;
                return .{
                    .function_name = source[name_start..name_end],
                    .active_param = comma_count,
                };
            }
            depth -= 1;
        } else if (c == ',' and depth == 0) {
            comma_count += 1;
        } else if (c == '\n' and depth == 0) {
            // Don't cross line boundaries outside nested parens
            // (multi-line call args are fine within parens)
        }
    }

    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Find a function symbol by name in the symbol table.
pub fn findFunctionByName(table: *SymbolTable, name: []const u8) ?*const Symbol {
    for (table.symbols.items) |*sym| {
        if (std.mem.eql(u8, sym.name, name)) {
            switch (sym.kind) {
                .function => return sym,
                else => {},
            }
        }
    }
    return null;
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

test "findSignatureContext simple call" {
    const source = "let x = add(1, 2)";
    // Cursor at position after "add(" — character 12 (0-indexed)
    const ctx = findSignatureContext(source, 0, 12);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqualStrings("add", ctx.?.function_name);
    try std.testing.expectEqual(@as(u32, 0), ctx.?.active_param);
}

test "findSignatureContext second parameter" {
    const source = "let x = add(1, 2)";
    // Cursor after the comma — character 15 (0-indexed)
    const ctx = findSignatureContext(source, 0, 15);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqualStrings("add", ctx.?.function_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.?.active_param);
}

test "findSignatureContext nested call" {
    const source = "let x = foo(bar(1), 2)";
    // Cursor at character 20, inside outer call's second arg
    const ctx = findSignatureContext(source, 0, 20);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqualStrings("foo", ctx.?.function_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.?.active_param);
}

test "findSignatureContext no call" {
    const source = "let x = 42";
    const ctx = findSignatureContext(source, 0, 5);
    try std.testing.expect(ctx == null);
}

test "findSignatureContext multiline" {
    const source = "let x = add(\n  1,\n  2\n)";
    // Cursor on line 2, character 2 (inside the third param position)
    const ctx = findSignatureContext(source, 2, 2);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqualStrings("add", ctx.?.function_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.?.active_param);
}

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
