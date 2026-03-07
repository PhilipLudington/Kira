//! Documentation generator for Kira.
//!
//! Extracts doc comments (/// and //!) from parsed AST and generates
//! Markdown API reference documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast/root.zig");
const Declaration = ast.Declaration;
const Type = ast.Type;
const Program = ast.Program;
const pretty_printer = @import("ast/pretty_printer.zig");

/// Generate Markdown documentation from a parsed Kira program.
/// Caller owns the returned slice.
pub fn generateMarkdown(allocator: Allocator, program: *const Program) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    // Module header
    if (program.module_decl) |mod| {
        const path_str = joinPath(allocator, mod.path) catch null;
        defer if (path_str) |p| allocator.free(p);
        try appendFmt(allocator, &output, "# Module `{s}`\n\n", .{path_str orelse "unknown"});
    } else {
        try appendSlice(allocator, &output, "# API Reference\n\n");
    }

    // Module-level documentation
    if (program.module_doc) |doc| {
        try appendSlice(allocator, &output, doc);
        try appendSlice(allocator, &output, "\n\n");
    }

    try appendSlice(allocator, &output, "---\n\n");

    // Collect public declarations by category
    var functions = std.ArrayListUnmanaged(*const Declaration){};
    defer functions.deinit(allocator);
    var types = std.ArrayListUnmanaged(*const Declaration){};
    defer types.deinit(allocator);
    var traits = std.ArrayListUnmanaged(*const Declaration){};
    defer traits.deinit(allocator);
    var constants = std.ArrayListUnmanaged(*const Declaration){};
    defer constants.deinit(allocator);

    for (program.declarations) |*decl| {
        if (!decl.isPublic()) continue;
        switch (decl.kind) {
            .function_decl => try functions.append(allocator, decl),
            .type_decl => try types.append(allocator, decl),
            .trait_decl => try traits.append(allocator, decl),
            .const_decl => try constants.append(allocator, decl),
            .let_decl => try functions.append(allocator, decl),
            else => {},
        }
    }

    // Types section
    if (types.items.len > 0) {
        try appendSlice(allocator, &output, "## Types\n\n");
        for (types.items) |decl| {
            try renderTypeDecl(allocator, &output, decl);
        }
    }

    // Traits section
    if (traits.items.len > 0) {
        try appendSlice(allocator, &output, "## Traits\n\n");
        for (traits.items) |decl| {
            try renderTraitDecl(allocator, &output, decl);
        }
    }

    // Functions section
    if (functions.items.len > 0) {
        try appendSlice(allocator, &output, "## Functions\n\n");
        for (functions.items) |decl| {
            try renderFunctionDecl(allocator, &output, decl);
        }
    }

    // Constants section
    if (constants.items.len > 0) {
        try appendSlice(allocator, &output, "## Constants\n\n");
        for (constants.items) |decl| {
            try renderConstDecl(allocator, &output, decl);
        }
    }

    return output.toOwnedSlice(allocator);
}

fn renderFunctionDecl(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), decl: *const Declaration) !void {
    switch (decl.kind) {
        .function_decl => |f| {
            try appendFmt(allocator, output, "### `{s}`\n\n", .{f.name});
            try appendSlice(allocator, output, "```kira\n");
            if (f.is_effect) try appendSlice(allocator, output, "effect ");
            try appendFmt(allocator, output, "fn {s}", .{f.name});
            try renderGenericParams(allocator, output, f.generic_params);
            try appendSlice(allocator, output, "(");
            for (f.parameters, 0..) |param, i| {
                if (i > 0) try appendSlice(allocator, output, ", ");
                try appendFmt(allocator, output, "{s}: ", .{param.name});
                try appendTypeStr(allocator, output, param.param_type.*);
            }
            try appendSlice(allocator, output, ") -> ");
            try appendTypeStr(allocator, output, f.return_type.*);
            try appendSlice(allocator, output, "\n```\n\n");
            if (decl.doc_comment) |doc| {
                try appendSlice(allocator, output, doc);
                try appendSlice(allocator, output, "\n\n");
            }
        },
        .let_decl => |l| {
            try appendFmt(allocator, output, "### `{s}`\n\n", .{l.name});
            try appendSlice(allocator, output, "```kira\n");
            try appendFmt(allocator, output, "let {s}: ", .{l.name});
            try appendTypeStr(allocator, output, l.binding_type.*);
            try appendSlice(allocator, output, "\n```\n\n");
            if (decl.doc_comment) |doc| {
                try appendSlice(allocator, output, doc);
                try appendSlice(allocator, output, "\n\n");
            }
        },
        else => {},
    }
}

fn renderTypeDecl(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), decl: *const Declaration) !void {
    const td = switch (decl.kind) {
        .type_decl => |t| t,
        else => return,
    };

    try appendFmt(allocator, output, "### `{s}`\n\n", .{td.name});

    if (decl.doc_comment) |doc| {
        try appendSlice(allocator, output, doc);
        try appendSlice(allocator, output, "\n\n");
    }

    switch (td.definition) {
        .sum_type => |st| {
            try appendSlice(allocator, output, "```kira\ntype ");
            try appendFmt(allocator, output, "{s}", .{td.name});
            try renderGenericParams(allocator, output, td.generic_params);
            try appendSlice(allocator, output, " =\n");
            for (st.variants) |variant| {
                try appendFmt(allocator, output, "    | {s}", .{variant.name});
                if (variant.fields) |fields| {
                    switch (fields) {
                        .tuple_fields => |tf| {
                            try appendSlice(allocator, output, "(");
                            for (tf, 0..) |field_type, i| {
                                if (i > 0) try appendSlice(allocator, output, ", ");
                                try appendTypeStr(allocator, output, field_type.*);
                            }
                            try appendSlice(allocator, output, ")");
                        },
                        .record_fields => |rf| {
                            try appendSlice(allocator, output, " { ");
                            for (rf, 0..) |field, i| {
                                if (i > 0) try appendSlice(allocator, output, ", ");
                                try appendFmt(allocator, output, "{s}: ", .{field.name});
                                try appendTypeStr(allocator, output, field.field_type.*);
                            }
                            try appendSlice(allocator, output, " }");
                        },
                    }
                }
                try appendSlice(allocator, output, "\n");
            }
            try appendSlice(allocator, output, "```\n\n");
        },
        .product_type => |pt| {
            try appendSlice(allocator, output, "```kira\ntype ");
            try appendFmt(allocator, output, "{s}", .{td.name});
            try renderGenericParams(allocator, output, td.generic_params);
            try appendSlice(allocator, output, " = {\n");
            for (pt.fields) |field| {
                try appendFmt(allocator, output, "    {s}: ", .{field.name});
                try appendTypeStr(allocator, output, field.field_type.*);
                try appendSlice(allocator, output, "\n");
            }
            try appendSlice(allocator, output, "}\n```\n\n");
        },
        .type_alias => |alias| {
            try appendSlice(allocator, output, "```kira\ntype ");
            try appendFmt(allocator, output, "{s}", .{td.name});
            try renderGenericParams(allocator, output, td.generic_params);
            try appendSlice(allocator, output, " = ");
            try appendTypeStr(allocator, output, alias.*);
            try appendSlice(allocator, output, "\n```\n\n");
        },
    }
}

fn renderTraitDecl(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), decl: *const Declaration) !void {
    const td = switch (decl.kind) {
        .trait_decl => |t| t,
        else => return,
    };

    try appendFmt(allocator, output, "### `{s}`\n\n", .{td.name});

    if (decl.doc_comment) |doc| {
        try appendSlice(allocator, output, doc);
        try appendSlice(allocator, output, "\n\n");
    }

    try appendSlice(allocator, output, "```kira\ntrait ");
    try appendFmt(allocator, output, "{s}", .{td.name});
    if (td.super_traits) |supers| {
        try appendSlice(allocator, output, ": ");
        for (supers, 0..) |s, i| {
            if (i > 0) try appendSlice(allocator, output, " + ");
            try appendFmt(allocator, output, "{s}", .{s});
        }
    }
    try appendSlice(allocator, output, " {\n");

    for (td.methods) |method| {
        try appendFmt(allocator, output, "    fn {s}(", .{method.name});
        for (method.parameters, 0..) |param, i| {
            if (i > 0) try appendSlice(allocator, output, ", ");
            try appendFmt(allocator, output, "{s}: ", .{param.name});
            try appendTypeStr(allocator, output, param.param_type.*);
        }
        try appendSlice(allocator, output, ") -> ");
        try appendTypeStr(allocator, output, method.return_type.*);
        try appendSlice(allocator, output, "\n");
    }

    try appendSlice(allocator, output, "}\n```\n\n");

    // Document individual methods
    if (td.methods.len > 0) {
        try appendSlice(allocator, output, "**Methods:**\n\n");
        for (td.methods) |method| {
            try appendFmt(allocator, output, "- `{s}(", .{method.name});
            for (method.parameters, 0..) |param, i| {
                if (i > 0) try appendSlice(allocator, output, ", ");
                try appendFmt(allocator, output, "{s}: ", .{param.name});
                try appendTypeStr(allocator, output, param.param_type.*);
            }
            try appendSlice(allocator, output, ") -> ");
            try appendTypeStr(allocator, output, method.return_type.*);
            try appendSlice(allocator, output, "`\n");
        }
        try appendSlice(allocator, output, "\n");
    }
}

fn renderConstDecl(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), decl: *const Declaration) !void {
    const cd = switch (decl.kind) {
        .const_decl => |c| c,
        else => return,
    };

    try appendFmt(allocator, output, "### `{s}`\n\n", .{cd.name});
    try appendSlice(allocator, output, "```kira\nconst ");
    try appendFmt(allocator, output, "{s}: ", .{cd.name});
    try appendTypeStr(allocator, output, cd.const_type.*);
    try appendSlice(allocator, output, "\n```\n\n");
    if (decl.doc_comment) |doc| {
        try appendSlice(allocator, output, doc);
        try appendSlice(allocator, output, "\n\n");
    }
}

fn renderGenericParams(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), params: ?[]Declaration.GenericParam) !void {
    const gp = params orelse return;
    if (gp.len == 0) return;
    try appendSlice(allocator, output, "[");
    for (gp, 0..) |p, i| {
        if (i > 0) try appendSlice(allocator, output, ", ");
        try appendFmt(allocator, output, "{s}", .{p.name});
        if (p.constraints) |bounds| {
            try appendSlice(allocator, output, ": ");
            for (bounds, 0..) |b, j| {
                if (j > 0) try appendSlice(allocator, output, " + ");
                try appendFmt(allocator, output, "{s}", .{b});
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

    try std.testing.expect(std.mem.indexOf(u8, md, "# API Reference") != null);
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
