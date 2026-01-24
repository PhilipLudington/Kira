//! Pretty printer for Kira AST nodes.
//!
//! Provides formatted output of AST structures for debugging purposes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Expression = @import("expression.zig").Expression;
const Statement = @import("statement.zig").Statement;
const Type = @import("types.zig").Type;
const Declaration = @import("declaration.zig").Declaration;
const Pattern = @import("pattern.zig").Pattern;
const Program = @import("program.zig").Program;
const Location = @import("../lexer/root.zig").Location;

/// AST pretty printer for debugging.
/// Outputs formatted AST structure to a buffer.
pub const PrettyPrinter = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    indent_level: usize,
    indent_str: []const u8,

    const Self = @This();

    /// Initialize a new pretty printer
    pub fn init(allocator: Allocator) Self {
        return .{
            .buffer = .{},
            .allocator = allocator,
            .indent_level = 0,
            .indent_str = "  ",
        };
    }

    /// Free resources
    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// Get the output as a string slice
    pub fn toSlice(self: *Self) []const u8 {
        return self.buffer.items;
    }

    /// Get the output as an owned string
    pub fn toOwnedSlice(self: *Self) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn write(self: *Self, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    fn writeIndent(self: *Self) !void {
        for (0..self.indent_level) |_| {
            try self.write(self.indent_str);
        }
    }

    fn writeFmt(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
            try self.write("<fmt overflow>");
            return;
        };
        try self.write(slice);
    }

    fn indent(self: *Self) void {
        self.indent_level += 1;
    }

    fn dedent(self: *Self) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }

    fn writeLocation(self: *Self, loc: Location) !void {
        try self.writeFmt("{d}:{d}", .{ loc.line, loc.column });
    }

    /// Print an expression
    pub fn printExpression(self: *Self, expr: Expression) !void {
        try self.writeIndent();
        try self.write("Expression(");
        try self.writeLocation(expr.span.start);
        try self.write("): ");

        switch (expr.kind) {
            .integer_literal => |lit| {
                try self.writeFmt("IntegerLiteral({d})", .{lit.value});
                if (lit.suffix) |s| {
                    try self.writeFmt(" suffix={s}", .{s});
                }
            },
            .float_literal => |lit| {
                try self.writeFmt("FloatLiteral({d})", .{lit.value});
                if (lit.suffix) |s| {
                    try self.writeFmt(" suffix={s}", .{s});
                }
            },
            .string_literal => |lit| {
                try self.writeFmt("StringLiteral(\"{s}\")", .{lit.value});
            },
            .char_literal => |lit| {
                try self.writeFmt("CharLiteral(U+{X:0>4})", .{lit.value});
            },
            .bool_literal => |b| {
                try self.write(if (b) "BoolLiteral(true)" else "BoolLiteral(false)");
            },
            .identifier => |id| {
                try self.writeFmt("Identifier({s})", .{id.name});
            },
            .self_expr => {
                try self.write("Self");
            },
            .self_type_expr => {
                try self.write("SelfType");
            },
            .binary => |bin| {
                try self.writeFmt("BinaryOp({s})\n", .{bin.operator.toString()});
                self.indent();
                try self.printExpression(bin.left.*);
                try self.write("\n");
                try self.printExpression(bin.right.*);
                self.dedent();
            },
            .unary => |un| {
                try self.writeFmt("UnaryOp({s})\n", .{un.operator.toString()});
                self.indent();
                try self.printExpression(un.operand.*);
                self.dedent();
            },
            .field_access => |fa| {
                try self.writeFmt("FieldAccess(.{s})\n", .{fa.field});
                self.indent();
                try self.printExpression(fa.object.*);
                self.dedent();
            },
            .index_access => |ia| {
                try self.write("IndexAccess\n");
                self.indent();
                try self.writeIndent();
                try self.write("object:\n");
                self.indent();
                try self.printExpression(ia.object.*);
                self.dedent();
                try self.write("\n");
                try self.writeIndent();
                try self.write("index:\n");
                self.indent();
                try self.printExpression(ia.index.*);
                self.dedent();
                self.dedent();
            },
            .tuple_access => |ta| {
                try self.writeFmt("TupleAccess(.{d})\n", .{ta.index});
                self.indent();
                try self.printExpression(ta.tuple.*);
                self.dedent();
            },
            .function_call => |fc| {
                try self.write("FunctionCall\n");
                self.indent();
                try self.writeIndent();
                try self.write("callee:\n");
                self.indent();
                try self.printExpression(fc.callee.*);
                self.dedent();
                if (fc.arguments.len > 0) {
                    try self.write("\n");
                    try self.writeIndent();
                    try self.write("arguments:\n");
                    self.indent();
                    for (fc.arguments, 0..) |arg, i| {
                        try self.printExpression(arg.*);
                        if (i < fc.arguments.len - 1) {
                            try self.write("\n");
                        }
                    }
                    self.dedent();
                }
                self.dedent();
            },
            .method_call => |mc| {
                try self.writeFmt("MethodCall(.{s})\n", .{mc.method});
                self.indent();
                try self.writeIndent();
                try self.write("object:\n");
                self.indent();
                try self.printExpression(mc.object.*);
                self.dedent();
                if (mc.arguments.len > 0) {
                    try self.write("\n");
                    try self.writeIndent();
                    try self.write("arguments:\n");
                    self.indent();
                    for (mc.arguments, 0..) |arg, i| {
                        try self.printExpression(arg.*);
                        if (i < mc.arguments.len - 1) {
                            try self.write("\n");
                        }
                    }
                    self.dedent();
                }
                self.dedent();
            },
            .closure => |cl| {
                try self.write("Closure");
                if (cl.is_effect) {
                    try self.write(" (effect)");
                }
                try self.write("\n");
                self.indent();
                try self.writeIndent();
                try self.write("parameters: [");
                for (cl.parameters, 0..) |param, i| {
                    try self.writeFmt("{s}", .{param.name});
                    if (i < cl.parameters.len - 1) {
                        try self.write(", ");
                    }
                }
                try self.write("]\n");
                try self.writeIndent();
                try self.write("return_type: ");
                try self.printType(cl.return_type.*);
                try self.write("\n");
                try self.writeIndent();
                try self.writeFmt("body: {d} statements", .{cl.body.len});
                self.dedent();
            },
            .tuple_literal => |tl| {
                try self.writeFmt("TupleLiteral({d} elements)", .{tl.elements.len});
            },
            .array_literal => |al| {
                try self.writeFmt("ArrayLiteral({d} elements)", .{al.elements.len});
            },
            .record_literal => |rl| {
                try self.writeFmt("RecordLiteral({d} fields)", .{rl.fields.len});
            },
            .variant_constructor => |vc| {
                try self.writeFmt("VariantConstructor({s})", .{vc.variant_name});
            },
            .type_cast => {
                try self.write("TypeCast");
            },
            .range => |r| {
                try self.write("Range(");
                if (r.start != null) try self.write("start");
                try self.write(if (r.inclusive) "..=" else "..");
                if (r.end != null) try self.write("end");
                try self.write(")");
            },
            .grouped => {
                try self.write("Grouped");
            },
            .try_expr => {
                try self.write("Try(?)");
            },
            .null_coalesce => {
                try self.write("NullCoalesce(??)");
            },
            .match_expr => |me| {
                try self.writeFmt("MatchExpr({d} arms)", .{me.arms.len});
            },
            .interpolated_string => |is| {
                try self.writeFmt("InterpolatedString({d} parts)", .{is.parts.len});
            },
        }
    }

    /// Print a statement
    pub fn printStatement(self: *Self, stmt: Statement) !void {
        try self.writeIndent();
        try self.write("Statement(");
        try self.writeLocation(stmt.span.start);
        try self.write("): ");

        switch (stmt.kind) {
            .let_binding => |lb| {
                try self.write("LetBinding");
                if (lb.is_public) {
                    try self.write(" (pub)");
                }
                try self.write("\n");
                self.indent();
                try self.writeIndent();
                try self.write("pattern: ");
                try self.printPattern(lb.pattern.*);
                try self.write("\n");
                try self.writeIndent();
                try self.write("type: ");
                try self.printType(lb.explicit_type.*);
                self.dedent();
            },
            .var_binding => |vb| {
                try self.writeFmt("VarBinding({s})\n", .{vb.name});
                self.indent();
                try self.writeIndent();
                try self.write("type: ");
                try self.printType(vb.explicit_type.*);
                if (vb.initializer) |_| {
                    try self.write("\n");
                    try self.writeIndent();
                    try self.write("initializer: <expression>");
                }
                self.dedent();
            },
            .assignment => |a| {
                try self.write("Assignment\n");
                self.indent();
                try self.writeIndent();
                try self.write("target: ");
                switch (a.target) {
                    .identifier => |id| try self.writeFmt("Identifier({s})", .{id}),
                    .field_access => |fa| try self.writeFmt("FieldAccess(.{s})", .{fa.field}),
                    .index_access => try self.write("IndexAccess"),
                }
                self.dedent();
            },
            .if_statement => |ifs| {
                try self.write("IfStatement\n");
                self.indent();
                try self.writeIndent();
                try self.writeFmt("then: {d} statements", .{ifs.then_branch.len});
                if (ifs.else_branch) |eb| {
                    try self.write("\n");
                    try self.writeIndent();
                    switch (eb) {
                        .block => |b| try self.writeFmt("else: {d} statements", .{b.len}),
                        .else_if => try self.write("else if: ..."),
                    }
                }
                self.dedent();
            },
            .for_loop => |fl| {
                try self.write("ForLoop\n");
                self.indent();
                try self.writeIndent();
                try self.write("pattern: ");
                try self.printPattern(fl.pattern.*);
                try self.write("\n");
                try self.writeIndent();
                try self.writeFmt("body: {d} statements", .{fl.body.len});
                self.dedent();
            },
            .match_statement => |ms| {
                try self.writeFmt("MatchStatement({d} arms)", .{ms.arms.len});
            },
            .return_statement => |rs| {
                try self.write("Return");
                if (rs.value != null) {
                    try self.write(" <expression>");
                }
            },
            .break_statement => |bs| {
                try self.write("Break");
                if (bs.label) |l| {
                    try self.writeFmt(" label={s}", .{l});
                }
            },
            .expression_statement => {
                try self.write("ExpressionStatement");
            },
            .block => |b| {
                try self.writeFmt("Block({d} statements)", .{b.len});
            },
        }
    }

    /// Print a type
    pub fn printType(self: *Self, typ: Type) !void {
        switch (typ.kind) {
            .primitive => |p| try self.write(p.toString()),
            .named => |n| try self.writeFmt("{s}", .{n.name}),
            .generic => |g| {
                try self.writeFmt("{s}[", .{g.base});
                for (g.type_arguments, 0..) |arg, i| {
                    try self.printType(arg.*);
                    if (i < g.type_arguments.len - 1) {
                        try self.write(", ");
                    }
                }
                try self.write("]");
            },
            .function => |f| {
                if (f.effect_type) |e| {
                    try self.writeFmt("{s} ", .{e.toString()});
                }
                try self.write("fn(");
                for (f.parameter_types, 0..) |param, i| {
                    try self.printType(param.*);
                    if (i < f.parameter_types.len - 1) {
                        try self.write(", ");
                    }
                }
                try self.write(") -> ");
                try self.printType(f.return_type.*);
            },
            .tuple => |t| {
                try self.write("(");
                for (t.element_types, 0..) |elem, i| {
                    try self.printType(elem.*);
                    if (i < t.element_types.len - 1) {
                        try self.write(", ");
                    }
                }
                try self.write(")");
            },
            .array => |a| {
                try self.write("[");
                try self.printType(a.element_type.*);
                if (a.size) |s| {
                    try self.writeFmt("; {d}", .{s});
                }
                try self.write("]");
            },
            .io_type => |io| {
                try self.write("IO[");
                try self.printType(io.*);
                try self.write("]");
            },
            .result_type => |r| {
                try self.write("Result[");
                try self.printType(r.ok_type.*);
                try self.write(", ");
                try self.printType(r.err_type.*);
                try self.write("]");
            },
            .option_type => |o| {
                try self.write("Option[");
                try self.printType(o.*);
                try self.write("]");
            },
            .self_type => try self.write("Self"),
            .type_variable => |tv| try self.writeFmt("{s}", .{tv.name}),
            .path => |p| {
                for (p.segments, 0..) |seg, i| {
                    try self.writeFmt("{s}", .{seg});
                    if (i < p.segments.len - 1) {
                        try self.write(".");
                    }
                }
            },
            .inferred => try self.write("_"),
        }
    }

    /// Print a pattern
    pub fn printPattern(self: *Self, pat: Pattern) !void {
        switch (pat.kind) {
            .wildcard => try self.write("_"),
            .identifier => |id| {
                if (id.is_mutable) {
                    try self.write("var ");
                }
                try self.writeFmt("{s}", .{id.name});
            },
            .integer_literal => |i| try self.writeFmt("{d}", .{i}),
            .float_literal => |f| try self.writeFmt("{d}", .{f}),
            .string_literal => |s| try self.writeFmt("\"{s}\"", .{s}),
            .char_literal => |c| try self.writeFmt("U+{X:0>4}", .{c}),
            .bool_literal => |b| try self.write(if (b) "true" else "false"),
            .constructor => |c| {
                try self.writeFmt("{s}", .{c.variant_name});
                if (c.arguments) |args| {
                    try self.writeFmt("({d} args)", .{args.len});
                }
            },
            .record => |r| {
                if (r.type_name) |name| {
                    try self.writeFmt("{s} ", .{name});
                }
                try self.writeFmt("{{ {d} fields }}", .{r.fields.len});
            },
            .tuple => |t| {
                try self.writeFmt("({d} elements)", .{t.elements.len});
            },
            .or_pattern => |o| {
                try self.writeFmt("({d} alternatives)", .{o.patterns.len});
            },
            .guarded => {
                try self.write("<guarded pattern>");
            },
            .range => |r| {
                if (r.start) |s| {
                    switch (s) {
                        .integer => |i| try self.writeFmt("{d}", .{i}),
                        .char => |c| try self.writeFmt("U+{X:0>4}", .{c}),
                    }
                }
                try self.write(if (r.inclusive) "..=" else "..");
                if (r.end) |e| {
                    switch (e) {
                        .integer => |i| try self.writeFmt("{d}", .{i}),
                        .char => |c| try self.writeFmt("U+{X:0>4}", .{c}),
                    }
                }
            },
            .rest => try self.write(".."),
            .typed => {
                try self.write("<typed pattern>");
            },
        }
    }

    /// Print a declaration
    pub fn printDeclaration(self: *Self, decl: Declaration) !void {
        try self.writeIndent();
        try self.write("Declaration(");
        try self.writeLocation(decl.span.start);
        try self.write("): ");

        switch (decl.kind) {
            .function_decl => |fd| {
                if (fd.is_public) try self.write("pub ");
                if (fd.is_effect) try self.write("effect ");
                try self.writeFmt("fn {s}", .{fd.name});
                if (fd.generic_params) |gp| {
                    try self.writeFmt("[{d} params]", .{gp.len});
                }
                try self.writeFmt("({d} params) -> ", .{fd.parameters.len});
                try self.printType(fd.return_type.*);
                if (fd.body) |body| {
                    try self.writeFmt(" {{ {d} statements }}", .{body.len});
                }
            },
            .type_decl => |td| {
                if (td.is_public) try self.write("pub ");
                try self.writeFmt("type {s}", .{td.name});
                if (td.generic_params) |gp| {
                    try self.writeFmt("[{d} params]", .{gp.len});
                }
                switch (td.definition) {
                    .sum_type => |st| {
                        try self.writeFmt(" = {d} variants", .{st.variants.len});
                    },
                    .product_type => |pt| {
                        try self.writeFmt(" = {{ {d} fields }}", .{pt.fields.len});
                    },
                    .type_alias => {
                        try self.write(" = <alias>");
                    },
                }
            },
            .trait_decl => |td| {
                if (td.is_public) try self.write("pub ");
                try self.writeFmt("trait {s}", .{td.name});
                try self.writeFmt(" {{ {d} methods }}", .{td.methods.len});
            },
            .impl_block => |ib| {
                try self.write("impl ");
                if (ib.trait_name) |tn| {
                    try self.writeFmt("{s} for ", .{tn});
                }
                try self.printType(ib.target_type.*);
                try self.writeFmt(" {{ {d} methods }}", .{ib.methods.len});
            },
            .module_decl => |md| {
                try self.write("module ");
                for (md.path, 0..) |seg, i| {
                    try self.writeFmt("{s}", .{seg});
                    if (i < md.path.len - 1) {
                        try self.write(".");
                    }
                }
            },
            .import_decl => |id| {
                try self.write("import ");
                for (id.path, 0..) |seg, i| {
                    try self.writeFmt("{s}", .{seg});
                    if (i < id.path.len - 1) {
                        try self.write(".");
                    }
                }
                if (id.items) |items| {
                    try self.writeFmt(".{{ {d} items }}", .{items.len});
                }
            },
            .const_decl => |cd| {
                if (cd.is_public) try self.write("pub ");
                try self.writeFmt("const {s}: ", .{cd.name});
                try self.printType(cd.const_type.*);
            },
            .let_decl => |ld| {
                if (ld.is_public) try self.write("pub ");
                try self.writeFmt("let {s}", .{ld.name});
                if (ld.generic_params) |gp| {
                    try self.writeFmt("[{d} params]", .{gp.len});
                }
                try self.write(": ");
                try self.printType(ld.binding_type.*);
            },
            .test_decl => |td| {
                try self.writeFmt("test \"{s}\" {{ {d} statements }}", .{ td.name, td.body.len });
            },
        }
    }

    /// Print a program
    pub fn printProgram(self: *Self, prog: Program) !void {
        try self.write("Program\n");
        self.indent();

        if (prog.module_doc) |doc| {
            try self.writeIndent();
            try self.writeFmt("Module Doc: \"{s}\"\n", .{doc});
        }

        if (prog.module_decl) |md| {
            try self.writeIndent();
            try self.write("Module: ");
            for (md.path, 0..) |seg, i| {
                try self.writeFmt("{s}", .{seg});
                if (i < md.path.len - 1) {
                    try self.write(".");
                }
            }
            try self.write("\n");
        }

        if (prog.imports.len > 0) {
            try self.writeIndent();
            try self.writeFmt("Imports: {d}\n", .{prog.imports.len});
        }

        try self.writeIndent();
        try self.writeFmt("Declarations: {d}\n", .{prog.declarations.len});

        for (prog.declarations) |decl| {
            try self.printDeclaration(decl);
            try self.write("\n");
        }

        self.dedent();
    }
};

/// Format an expression to string (convenience function)
pub fn formatExpression(allocator: Allocator, expr: Expression) ![]u8 {
    var printer = PrettyPrinter.init(allocator);
    defer printer.deinit();
    try printer.printExpression(expr);
    return printer.toOwnedSlice();
}

/// Format a type to string (convenience function)
pub fn formatType(allocator: Allocator, typ: Type) ![]u8 {
    var printer = PrettyPrinter.init(allocator);
    defer printer.deinit();
    try printer.printType(typ);
    return printer.toOwnedSlice();
}

test "pretty printer basic" {
    const allocator = std.testing.allocator;
    var printer = PrettyPrinter.init(allocator);
    defer printer.deinit();

    try printer.write("Hello, ");
    try printer.write("world!");

    try std.testing.expectEqualStrings("Hello, world!", printer.toSlice());
}

test "pretty printer with formatting" {
    const allocator = std.testing.allocator;
    var printer = PrettyPrinter.init(allocator);
    defer printer.deinit();

    try printer.writeFmt("Value: {d}", .{42});
    try std.testing.expectEqualStrings("Value: 42", printer.toSlice());
}
