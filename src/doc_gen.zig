//! Documentation generator for Kira.
//!
//! Builds an intermediate documentation model from parsed AST and renders
//! Markdown and search index output from that model.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast/root.zig");
const Declaration = ast.Declaration;
const Type = ast.Type;
const Program = ast.Program;
const pretty_printer = @import("ast/pretty_printer.zig");

pub const SymbolKind = enum {
    function,
    type,
    trait,
    constant,
    value,

    pub fn label(self: SymbolKind) []const u8 {
        return switch (self) {
            .function => "function",
            .type => "type",
            .trait => "trait",
            .constant => "constant",
            .value => "value",
        };
    }

    pub fn heading(self: SymbolKind) []const u8 {
        return switch (self) {
            .function => "Functions",
            .type => "Types",
            .trait => "Traits",
            .constant => "Constants",
            .value => "Values",
        };
    }
};

pub const SymbolDoc = struct {
    name: []const u8,
    kind: SymbolKind,
    signature: []const u8,
    summary: ?[]const u8,
    docs: ?[]const u8,

    pub fn deinit(self: *SymbolDoc, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.signature);
        if (self.summary) |summary| allocator.free(summary);
        if (self.docs) |docs| allocator.free(docs);
    }
};

pub const ModuleDoc = struct {
    module_path: []const u8,
    source_path: ?[]const u8,
    summary: ?[]const u8,
    docs: ?[]const u8,
    symbols: []SymbolDoc,

    pub fn deinit(self: *ModuleDoc, allocator: Allocator) void {
        allocator.free(self.module_path);
        if (self.source_path) |path| allocator.free(path);
        if (self.summary) |summary| allocator.free(summary);
        if (self.docs) |docs| allocator.free(docs);
        for (self.symbols) |*symbol| {
            symbol.deinit(allocator);
        }
        allocator.free(self.symbols);
    }
};

pub const ProjectDocs = struct {
    package_name: ?[]const u8,
    modules: []ModuleDoc,

    pub fn deinit(self: *ProjectDocs, allocator: Allocator) void {
        if (self.package_name) |name| allocator.free(name);
        for (self.modules) |*module| {
            module.deinit(allocator);
        }
        allocator.free(self.modules);
    }
};

/// Generate Markdown documentation from a parsed Kira program.
/// Caller owns the returned slice.
pub fn generateMarkdown(allocator: Allocator, program: *const Program) ![]u8 {
    var module_doc = try collectModuleDocs(allocator, program);
    defer module_doc.deinit(allocator);
    return renderModuleMarkdown(allocator, module_doc);
}

pub fn collectModuleDocs(allocator: Allocator, program: *const Program) !ModuleDoc {
    const module_path = try duplicateModulePath(allocator, program);
    errdefer allocator.free(module_path);

    const source_path = if (program.source_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (source_path) |path| allocator.free(path);

    const docs = if (program.module_doc) |doc| try allocator.dupe(u8, doc) else null;
    errdefer if (docs) |doc| allocator.free(doc);

    const summary = if (program.module_doc) |doc| try extractSummary(allocator, doc) else null;
    errdefer if (summary) |text| allocator.free(text);

    var symbols = std.ArrayListUnmanaged(SymbolDoc){};
    errdefer {
        for (symbols.items) |*symbol| {
            symbol.deinit(allocator);
        }
        symbols.deinit(allocator);
    }

    for (program.declarations) |*decl| {
        if (!decl.isPublic()) continue;
        const symbol_doc = collectSymbolDoc(allocator, decl) catch |err| switch (err) {
            error.UnsupportedDeclaration => continue,
            else => return err,
        };
        try symbols.append(allocator, symbol_doc);
    }

    sortSymbols(symbols.items);

    return .{
        .module_path = module_path,
        .source_path = source_path,
        .summary = summary,
        .docs = docs,
        .symbols = try symbols.toOwnedSlice(allocator),
    };
}

pub fn renderModuleMarkdown(allocator: Allocator, module_doc: ModuleDoc) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    try appendFmt(allocator, &output, "# Module `{s}`\n\n", .{module_doc.module_path});
    if (module_doc.source_path) |source_path| {
        try appendFmt(allocator, &output, "_Source: `{s}`_\n\n", .{source_path});
    }

    if (module_doc.docs) |docs| {
        try appendSlice(allocator, &output, docs);
        try appendSlice(allocator, &output, "\n\n");
    }

    var wrote_any_section = false;
    const section_order = [_]SymbolKind{ .type, .trait, .function, .value, .constant };
    for (section_order) |kind| {
        if (!hasSymbolsOfKind(module_doc.symbols, kind)) continue;
        wrote_any_section = true;
        try appendFmt(allocator, &output, "## {s}\n\n", .{kind.heading()});
        for (module_doc.symbols) |symbol| {
            if (symbol.kind != kind) continue;
            try renderSymbolMarkdown(allocator, &output, symbol);
        }
    }

    if (!wrote_any_section) {
        try appendSlice(allocator, &output, "_No public declarations found._\n");
    }

    return output.toOwnedSlice(allocator);
}

pub fn renderProjectIndexMarkdown(allocator: Allocator, project_docs: ProjectDocs) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    if (project_docs.package_name) |package_name| {
        try appendFmt(allocator, &output, "# API Reference for `{s}`\n\n", .{package_name});
    } else {
        try appendSlice(allocator, &output, "# API Reference\n\n");
    }

    try appendSlice(allocator, &output, "Generated module pages:\n\n");
    for (project_docs.modules) |module_doc| {
        const file_name = try modulePageFileName(allocator, module_doc.module_path);
        defer allocator.free(file_name);

        try appendFmt(allocator, &output, "- [`{s}`]({s})", .{ module_doc.module_path, file_name });
        if (module_doc.summary) |summary| {
            try appendFmt(allocator, &output, " - {s}", .{summary});
        }
        try appendSlice(allocator, &output, "\n");
    }

    try appendSlice(allocator, &output, "\nArtifacts:\n\n");
    try appendSlice(allocator, &output, "- `search-index.json` for symbol search consumers\n");

    return output.toOwnedSlice(allocator);
}

pub fn generateSearchIndexJson(allocator: Allocator, project_docs: ProjectDocs) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    try appendSlice(allocator, &output, "[\n");
    var first = true;
    for (project_docs.modules) |module_doc| {
        const page_name = try modulePageFileName(allocator, module_doc.module_path);
        defer allocator.free(page_name);

        for (module_doc.symbols) |symbol| {
            if (!first) {
                try appendSlice(allocator, &output, ",\n");
            }
            first = false;

            try appendSlice(allocator, &output, "  {\n");
            try appendJsonField(allocator, &output, "module_path", module_doc.module_path, true);
            try appendJsonField(allocator, &output, "symbol_name", symbol.name, true);
            try appendJsonField(allocator, &output, "symbol_kind", symbol.kind.label(), true);
            if (symbol.summary) |summary| {
                try appendJsonField(allocator, &output, "summary", summary, true);
            } else {
                try appendSlice(allocator, &output, "    \"summary\": null,\n");
            }
            try appendJsonField(allocator, &output, "signature", symbol.signature, true);

            const anchor = try anchorForName(allocator, symbol.name);
            defer allocator.free(anchor);
            const page = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ page_name, anchor });
            defer allocator.free(page);
            try appendJsonField(allocator, &output, "page", page, false);
            try appendSlice(allocator, &output, "  }");
        }
    }
    try appendSlice(allocator, &output, "\n]\n");

    return output.toOwnedSlice(allocator);
}

pub fn modulePageFileName(allocator: Allocator, module_path: []const u8) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    for (module_path) |c| {
        const out_char: u8 = switch (c) {
            '.', '/', '\\', ' ' => '_',
            else => c,
        };
        try output.append(allocator, out_char);
    }
    try output.appendSlice(allocator, ".md");
    return output.toOwnedSlice(allocator);
}

fn collectSymbolDoc(allocator: Allocator, decl: *const Declaration) !SymbolDoc {
    const name = try allocator.dupe(u8, decl.name() orelse "unknown");
    errdefer allocator.free(name);

    const docs = if (decl.doc_comment) |doc| try allocator.dupe(u8, doc) else null;
    errdefer if (docs) |doc| allocator.free(doc);

    const summary = if (decl.doc_comment) |doc| try extractSummary(allocator, doc) else null;
    errdefer if (summary) |text| allocator.free(text);

    const signature, const kind = try collectSignatureAndKind(allocator, decl);
    errdefer allocator.free(signature);

    return .{
        .name = name,
        .kind = kind,
        .signature = signature,
        .summary = summary,
        .docs = docs,
    };
}

fn collectSignatureAndKind(allocator: Allocator, decl: *const Declaration) !struct { []u8, SymbolKind } {
    switch (decl.kind) {
        .function_decl => |f| {
            var output = std.ArrayListUnmanaged(u8){};
            errdefer output.deinit(allocator);
            if (f.is_effect) try appendSlice(allocator, &output, "effect ");
            try appendFmt(allocator, &output, "fn {s}", .{f.name});
            try appendGenericParams(allocator, &output, f.generic_params);
            try appendSlice(allocator, &output, "(");
            for (f.parameters, 0..) |param, i| {
                if (i > 0) try appendSlice(allocator, &output, ", ");
                try appendFmt(allocator, &output, "{s}: ", .{param.name});
                try appendTypeStr(allocator, &output, param.param_type.*);
            }
            try appendSlice(allocator, &output, ") -> ");
            try appendTypeStr(allocator, &output, f.return_type.*);
            return .{ try output.toOwnedSlice(allocator), .function };
        },
        .let_decl => |l| {
            var output = std.ArrayListUnmanaged(u8){};
            errdefer output.deinit(allocator);
            try appendFmt(allocator, &output, "let {s}", .{l.name});
            try appendGenericParams(allocator, &output, l.generic_params);
            try appendSlice(allocator, &output, ": ");
            try appendTypeStr(allocator, &output, l.binding_type.*);
            return .{ try output.toOwnedSlice(allocator), .value };
        },
        .type_decl => |t| {
            var output = std.ArrayListUnmanaged(u8){};
            errdefer output.deinit(allocator);
            try appendSlice(allocator, &output, "type ");
            try appendFmt(allocator, &output, "{s}", .{t.name});
            try appendGenericParams(allocator, &output, t.generic_params);
            try appendSlice(allocator, &output, " = ");
            switch (t.definition) {
                .sum_type => |sum_type| {
                    for (sum_type.variants, 0..) |variant, i| {
                        if (i > 0) try appendSlice(allocator, &output, " ");
                        try appendFmt(allocator, &output, "| {s}", .{variant.name});
                    }
                },
                .product_type => |product_type| {
                    try appendSlice(allocator, &output, "{ ");
                    for (product_type.fields, 0..) |field, i| {
                        if (i > 0) try appendSlice(allocator, &output, ", ");
                        try appendFmt(allocator, &output, "{s}: ", .{field.name});
                        try appendTypeStr(allocator, &output, field.field_type.*);
                    }
                    try appendSlice(allocator, &output, " }");
                },
                .type_alias => |alias| {
                    try appendTypeStr(allocator, &output, alias.*);
                },
            }
            return .{ try output.toOwnedSlice(allocator), .type };
        },
        .trait_decl => |trait_decl| {
            var output = std.ArrayListUnmanaged(u8){};
            errdefer output.deinit(allocator);
            try appendSlice(allocator, &output, "trait ");
            try appendFmt(allocator, &output, "{s}", .{trait_decl.name});
            try appendGenericParams(allocator, &output, trait_decl.generic_params);
            if (trait_decl.super_traits) |supers| {
                try appendSlice(allocator, &output, ": ");
                for (supers, 0..) |super_trait, i| {
                    if (i > 0) try appendSlice(allocator, &output, " + ");
                    try appendFmt(allocator, &output, "{s}", .{super_trait});
                }
            }
            return .{ try output.toOwnedSlice(allocator), .trait };
        },
        .const_decl => |const_decl| {
            var output = std.ArrayListUnmanaged(u8){};
            errdefer output.deinit(allocator);
            try appendFmt(allocator, &output, "const {s}: ", .{const_decl.name});
            try appendTypeStr(allocator, &output, const_decl.const_type.*);
            return .{ try output.toOwnedSlice(allocator), .constant };
        },
        else => return error.UnsupportedDeclaration,
    }
}

fn renderSymbolMarkdown(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), symbol: SymbolDoc) !void {
    try appendFmt(allocator, output, "### {s}\n\n", .{symbol.name});
    try appendSlice(allocator, output, "```kira\n");
    try appendSlice(allocator, output, symbol.signature);
    try appendSlice(allocator, output, "\n```\n\n");
    if (symbol.docs) |docs| {
        try appendSlice(allocator, output, docs);
        try appendSlice(allocator, output, "\n\n");
    }
}

fn appendGenericParams(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), params: ?[]Declaration.GenericParam) !void {
    const gp = params orelse return;
    if (gp.len == 0) return;

    try appendSlice(allocator, output, "[");
    for (gp, 0..) |p, i| {
        if (i > 0) try appendSlice(allocator, output, ", ");
        try appendFmt(allocator, output, "{s}", .{p.name});
        if (p.constraints) |bounds| {
            try appendSlice(allocator, output, ": ");
            for (bounds, 0..) |bound, j| {
                if (j > 0) try appendSlice(allocator, output, " + ");
                try appendFmt(allocator, output, "{s}", .{bound});
            }
        }
    }
    try appendSlice(allocator, output, "]");
}

fn appendTypeStr(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), typ: Type) !void {
    const type_str = pretty_printer.formatType(allocator, typ) catch {
        try appendSlice(allocator, output, "?");
        return;
    };
    defer allocator.free(type_str);
    try appendSlice(allocator, output, type_str);
}

fn duplicateModulePath(allocator: Allocator, program: *const Program) ![]u8 {
    if (program.module_decl) |mod| {
        return joinPath(allocator, mod.path);
    }
    if (program.source_path) |source_path| {
        return allocator.dupe(u8, std.fs.path.stem(source_path));
    }
    return allocator.dupe(u8, "unknown");
}

fn extractSummary(allocator: Allocator, docs: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, docs, " \t\r\n");
    const summary_line = std.mem.sliceTo(trimmed, '\n');
    return allocator.dupe(u8, std.mem.trim(u8, summary_line, " \t\r\n"));
}

fn anchorForName(allocator: Allocator, name: []const u8) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try output.append(allocator, std.ascii.toLower(c));
        } else if (c == '-' or c == '_' or c == ' ') {
            try output.append(allocator, '-');
        }
    }

    if (output.items.len == 0) {
        try output.appendSlice(allocator, "symbol");
    }

    return output.toOwnedSlice(allocator);
}

fn hasSymbolsOfKind(symbols: []const SymbolDoc, kind: SymbolKind) bool {
    for (symbols) |symbol| {
        if (symbol.kind == kind) return true;
    }
    return false;
}

fn sortSymbols(symbols: []SymbolDoc) void {
    std.mem.sort(SymbolDoc, symbols, {}, struct {
        fn lessThan(_: void, lhs: SymbolDoc, rhs: SymbolDoc) bool {
            const lhs_rank = symbolSortRank(lhs.kind);
            const rhs_rank = symbolSortRank(rhs.kind);
            if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
}

fn symbolSortRank(kind: SymbolKind) u8 {
    return switch (kind) {
        .type => 0,
        .trait => 1,
        .function => 2,
        .value => 3,
        .constant => 4,
    };
}

fn appendJsonField(
    allocator: Allocator,
    output: *std.ArrayListUnmanaged(u8),
    key: []const u8,
    value: []const u8,
    trailing_comma: bool,
) !void {
    try appendFmt(allocator, output, "    \"{s}\": ", .{key});
    try appendJsonString(allocator, output, value);
    if (trailing_comma) {
        try appendSlice(allocator, output, ",\n");
    } else {
        try appendSlice(allocator, output, "\n");
    }
}

fn appendJsonString(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try appendSlice(allocator, output, "\"");
    for (value) |c| {
        switch (c) {
            '\\' => try appendSlice(allocator, output, "\\\\"),
            '"' => try appendSlice(allocator, output, "\\\""),
            '\n' => try appendSlice(allocator, output, "\\n"),
            '\r' => try appendSlice(allocator, output, "\\r"),
            '\t' => try appendSlice(allocator, output, "\\t"),
            else => try output.append(allocator, c),
        }
    }
    try appendSlice(allocator, output, "\"");
}

fn appendSlice(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try output.appendSlice(allocator, s);
}

fn appendFmt(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return error.OutOfMemory;
    defer allocator.free(formatted);
    try output.appendSlice(allocator, formatted);
}

fn joinPath(allocator: Allocator, path: [][]const u8) ![]u8 {
    return std.mem.join(allocator, ".", path);
}

// --- Tests ---

test "generateMarkdown empty program" {
    const allocator = std.testing.allocator;

    var program = Program{
        .module_decl = null,
        .imports = &.{},
        .declarations = &.{},
        .module_doc = null,
        .source_path = null,
        .arena = null,
    };

    const md = try generateMarkdown(allocator, &program);
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "# Module `unknown`") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "_No public declarations found._") != null);
}

test "generateMarkdown with module doc" {
    const allocator = std.testing.allocator;

    var program = Program{
        .module_decl = null,
        .imports = &.{},
        .declarations = &.{},
        .module_doc = "This is the module documentation.",
        .source_path = null,
        .arena = null,
    };

    const md = try generateMarkdown(allocator, &program);
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "This is the module documentation.") != null);
}

test "project docs index and search include public symbols" {
    const allocator = std.testing.allocator;
    const span = ast.Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    const return_type = try allocator.create(Type);
    defer allocator.destroy(return_type);
    return_type.* = .{
        .kind = .{ .primitive = .i64 },
        .span = span,
    };

    const param_type = try allocator.create(Type);
    defer allocator.destroy(param_type);
    param_type.* = .{
        .kind = .{ .primitive = .i64 },
        .span = span,
    };

    const decls = try allocator.alloc(Declaration, 2);
    defer allocator.free(decls);
    var params = [_]Declaration.Parameter{
        .{ .name = "x", .param_type = param_type, .span = span },
    };

    decls[0] = Declaration.initWithDoc(.{
        .function_decl = .{
            .name = "compute",
            .generic_params = null,
            .parameters = &params,
            .return_type = return_type,
            .is_effect = false,
            .is_public = true,
            .body = null,
            .where_clause = null,
        },
    }, span, "Compute a result.");

    decls[1] = Declaration.init(.{
        .function_decl = .{
            .name = "privateHelper",
            .generic_params = null,
            .parameters = &.{},
            .return_type = return_type,
            .is_effect = false,
            .is_public = false,
            .body = null,
            .where_clause = null,
        },
    }, span);

    var path = [_][]const u8{ "demo", "core" };
    var program = Program{
        .module_decl = .{ .path = &path },
        .imports = &.{},
        .declarations = decls,
        .module_doc = "Demo module.\nMore details.",
        .source_path = "src/demo/core.ki",
        .arena = null,
    };

    var modules = try allocator.alloc(ModuleDoc, 1);
    modules[0] = try collectModuleDocs(allocator, &program);
    const package_name = try allocator.dupe(u8, "demo");
    var project_docs = ProjectDocs{
        .package_name = package_name,
        .modules = modules,
    };
    defer project_docs.deinit(allocator);

    const index_md = try renderProjectIndexMarkdown(allocator, project_docs);
    defer allocator.free(index_md);
    const search_json = try generateSearchIndexJson(allocator, project_docs);
    defer allocator.free(search_json);

    try std.testing.expect(std.mem.indexOf(u8, index_md, "[`demo.core`](demo_core.md)") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "\"symbol_name\": \"compute\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_json, "privateHelper") == null);
}
