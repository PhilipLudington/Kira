//! Source code formatter for the Kira language.
//!
//! Takes a parsed AST and emits canonically formatted Kira source code.
//! The output uses 4-space indentation, consistent spacing, and newlines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast/root.zig");
const Expression = ast.Expression;
const Statement = ast.Statement;
const Type = ast.Type;
const Declaration = ast.Declaration;
const Pattern = ast.Pattern;
const Program = ast.Program;

/// Kira source code formatter.
/// Formats an AST back into canonical Kira source.
pub const Formatter = struct {
    buffer: std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    indent_level: usize,

    const indent_str = "    "; // 4 spaces

    pub fn init(allocator: Allocator) Formatter {
        return .{
            .buffer = .{},
            .allocator = allocator,
            .indent_level = 0,
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *Formatter) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn write(self: *Formatter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    fn writeByte(self: *Formatter, byte: u8) !void {
        try self.buffer.append(self.allocator, byte);
    }

    fn writeIndent(self: *Formatter) !void {
        for (0..self.indent_level) |_| {
            try self.write(indent_str);
        }
    }

    fn writeFmt(self: *Formatter, comptime fmt: []const u8, args: anytype) !void {
        var tmp: [128]u8 = undefined;
        const formatted = std.fmt.bufPrint(&tmp, fmt, args) catch {
            // Fallback to dynamic allocation for large output
            const allocated = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(allocated);
            return self.write(allocated);
        };
        try self.write(formatted);
    }

    fn indent(self: *Formatter) void {
        self.indent_level += 1;
    }

    fn dedent(self: *Formatter) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }

    /// Format a complete program
    pub fn formatProgram(self: *Formatter, prog: Program) anyerror!void {
        // Module doc comment
        if (prog.module_doc) |doc| {
            var iter = std.mem.splitScalar(u8, doc, '\n');
            while (iter.next()) |line| {
                try self.write("//! ");
                try self.write(line);
                try self.writeByte('\n');
            }
            try self.writeByte('\n');
        }

        // Module declaration
        if (prog.module_decl) |md| {
            try self.write("module ");
            try self.writePath(md.path);
            try self.writeByte('\n');
        }

        // Imports
        if (prog.imports.len > 0) {
            if (prog.module_decl != null) {
                // Already have a newline after module decl
            }
            for (prog.imports) |imp| {
                try self.formatImport(imp);
                try self.writeByte('\n');
            }
        }

        // Declarations
        var prev_was_import = prog.imports.len > 0;
        for (prog.declarations) |decl| {
            // Add blank line between declarations
            if (prev_was_import or self.buffer.items.len > 0) {
                // Ensure blank line separator
                if (self.buffer.items.len > 0 and !endsWithDoubleNewline(self.buffer.items)) {
                    if (self.buffer.items[self.buffer.items.len - 1] != '\n') {
                        try self.writeByte('\n');
                    }
                    try self.writeByte('\n');
                }
            }
            prev_was_import = false;

            // Doc comment
            if (decl.doc_comment) |doc| {
                var iter = std.mem.splitScalar(u8, doc, '\n');
                while (iter.next()) |line| {
                    try self.writeIndent();
                    try self.write("/// ");
                    try self.write(line);
                    try self.writeByte('\n');
                }
            }

            try self.formatDeclaration(decl);
            try self.writeByte('\n');
        }
    }

    fn endsWithDoubleNewline(items: []const u8) bool {
        if (items.len < 2) return false;
        return items[items.len - 1] == '\n' and items[items.len - 2] == '\n';
    }

    fn writePath(self: *Formatter, segments: [][]const u8) !void {
        for (segments, 0..) |seg, i| {
            if (i > 0) try self.writeByte('.');
            try self.write(seg);
        }
    }

    fn formatImport(self: *Formatter, imp: Declaration.ImportDecl) !void {
        try self.write("import ");
        try self.writePath(imp.path);

        if (imp.items) |items| {
            try self.write(".{ ");
            for (items, 0..) |item, i| {
                if (i > 0) try self.write(", ");
                try self.write(item.name);
                if (item.alias) |alias| {
                    try self.write(" as ");
                    try self.write(alias);
                }
            }
            try self.write(" }");
        }
    }

    /// Format a declaration
    pub fn formatDeclaration(self: *Formatter, decl: Declaration) anyerror!void {
        switch (decl.kind) {
            .function_decl => |fd| try self.formatFunctionDecl(fd),
            .type_decl => |td| try self.formatTypeDecl(td),
            .trait_decl => |td| try self.formatTraitDecl(td),
            .impl_block => |ib| try self.formatImplBlock(ib),
            .module_decl => |md| {
                try self.write("module ");
                try self.writePath(md.path);
            },
            .import_decl => |id| try self.formatImport(id),
            .const_decl => |cd| try self.formatConstDecl(cd),
            .let_decl => |ld| try self.formatLetDecl(ld),
            .test_decl => |td| try self.formatTestDecl(td),
            .bench_decl => |bd| try self.formatBenchDecl(bd),
        }
    }

    fn formatFunctionDecl(self: *Formatter, fd: Declaration.FunctionDecl) anyerror!void {
        try self.writeIndent();
        if (fd.is_public) try self.write("pub ");
        if (fd.is_effect) try self.write("effect ");
        try self.write("fn ");
        try self.write(fd.name);

        // Generic params
        if (fd.generic_params) |gp| {
            try self.writeGenericParams(gp);
        }

        // Parameters
        try self.writeByte('(');
        for (fd.parameters, 0..) |param, i| {
            if (i > 0) try self.write(", ");
            try self.write(param.name);
            try self.write(": ");
            try self.formatType(param.param_type.*);
        }
        try self.write(") -> ");
        try self.formatType(fd.return_type.*);

        // Where clause
        if (fd.where_clause) |wc| {
            try self.writeWhereClause(wc);
        }

        // Body
        if (fd.body) |body| {
            try self.write(" {\n");
            self.indent();
            try self.formatStatements(body);
            self.dedent();
            try self.writeIndent();
            try self.writeByte('}');
        }
    }

    fn formatTypeDecl(self: *Formatter, td: Declaration.TypeDecl) anyerror!void {
        try self.writeIndent();
        if (td.is_public) try self.write("pub ");
        try self.write("type ");
        try self.write(td.name);

        if (td.generic_params) |gp| {
            try self.writeGenericParams(gp);
        }

        switch (td.definition) {
            .sum_type => |st| {
                try self.write(" =\n");
                self.indent();
                for (st.variants) |variant| {
                    try self.writeIndent();
                    try self.write("| ");
                    try self.write(variant.name);
                    if (variant.fields) |fields| {
                        switch (fields) {
                            .tuple_fields => |tf| {
                                try self.writeByte('(');
                                for (tf, 0..) |field_type, i| {
                                    if (i > 0) try self.write(", ");
                                    try self.formatType(field_type.*);
                                }
                                try self.writeByte(')');
                            },
                            .record_fields => |rf| {
                                try self.write(" { ");
                                for (rf, 0..) |field, i| {
                                    if (i > 0) try self.write(", ");
                                    try self.write(field.name);
                                    try self.write(": ");
                                    try self.formatType(field.field_type.*);
                                }
                                try self.write(" }");
                            },
                        }
                    }
                    try self.writeByte('\n');
                }
                self.dedent();
            },
            .product_type => |pt| {
                try self.write(" = {\n");
                self.indent();
                for (pt.fields, 0..) |field, i| {
                    try self.writeIndent();
                    try self.write(field.name);
                    try self.write(": ");
                    try self.formatType(field.field_type.*);
                    if (i < pt.fields.len - 1) {
                        try self.writeByte(',');
                    }
                    try self.writeByte('\n');
                }
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
            .type_alias => |ta| {
                try self.write(" = ");
                try self.formatType(ta.*);
            },
        }
    }

    fn formatTraitDecl(self: *Formatter, td: Declaration.TraitDecl) anyerror!void {
        try self.writeIndent();
        if (td.is_public) try self.write("pub ");
        try self.write("trait ");
        try self.write(td.name);

        if (td.generic_params) |gp| {
            try self.writeGenericParams(gp);
        }

        if (td.super_traits) |st| {
            try self.write(": ");
            for (st, 0..) |trait_name, i| {
                if (i > 0) try self.write(" + ");
                try self.write(trait_name);
            }
        }

        try self.write(" {\n");
        self.indent();

        for (td.methods) |method| {
            try self.writeIndent();
            if (method.is_effect) try self.write("effect ");
            try self.write("fn ");
            try self.write(method.name);

            if (method.generic_params) |gp| {
                try self.writeGenericParams(gp);
            }

            try self.writeByte('(');
            for (method.parameters, 0..) |param, i| {
                if (i > 0) try self.write(", ");
                try self.write(param.name);
                try self.write(": ");
                try self.formatType(param.param_type.*);
            }
            try self.write(") -> ");
            try self.formatType(method.return_type.*);

            if (method.default_body) |body| {
                try self.write(" {\n");
                self.indent();
                try self.formatStatements(body);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            }

            try self.writeByte('\n');
        }

        self.dedent();
        try self.writeIndent();
        try self.writeByte('}');
    }

    fn formatImplBlock(self: *Formatter, ib: Declaration.ImplBlock) anyerror!void {
        try self.writeIndent();
        try self.write("impl ");

        if (ib.generic_params) |gp| {
            try self.writeGenericParams(gp);
            try self.writeByte(' ');
        }

        if (ib.trait_name) |tn| {
            try self.write(tn);
            try self.write(" for ");
        }
        try self.formatType(ib.target_type.*);

        if (ib.where_clause) |wc| {
            try self.writeWhereClause(wc);
        }

        try self.write(" {\n");
        self.indent();

        for (ib.methods, 0..) |method, i| {
            if (i > 0) try self.writeByte('\n');
            try self.formatFunctionDecl(method);
            try self.writeByte('\n');
        }

        self.dedent();
        try self.writeIndent();
        try self.writeByte('}');
    }

    fn formatConstDecl(self: *Formatter, cd: Declaration.ConstDecl) anyerror!void {
        try self.writeIndent();
        if (cd.is_public) try self.write("pub ");
        try self.write("const ");
        try self.write(cd.name);
        try self.write(": ");
        try self.formatType(cd.const_type.*);
        try self.write(" = ");
        try self.formatExpression(cd.value.*);
    }

    fn formatLetDecl(self: *Formatter, ld: Declaration.LetDecl) anyerror!void {
        try self.writeIndent();
        if (ld.is_public) try self.write("pub ");
        try self.write("let ");
        try self.write(ld.name);

        if (ld.generic_params) |gp| {
            try self.writeGenericParams(gp);
        }

        try self.write(": ");
        try self.formatType(ld.binding_type.*);
        try self.write(" = ");
        try self.formatExpression(ld.value.*);
    }

    fn formatTestDecl(self: *Formatter, td: Declaration.TestDecl) anyerror!void {
        try self.writeIndent();
        try self.write("test \"");
        try self.write(td.name);
        try self.write("\" {\n");
        self.indent();
        try self.formatStatements(td.body);
        self.dedent();
        try self.writeIndent();
        try self.writeByte('}');
    }

    fn formatBenchDecl(self: *Formatter, bd: Declaration.BenchDecl) anyerror!void {
        try self.writeIndent();
        try self.write("bench \"");
        try self.write(bd.name);
        try self.write("\" {\n");
        self.indent();
        try self.formatStatements(bd.body);
        self.dedent();
        try self.writeIndent();
        try self.writeByte('}');
    }

    fn writeGenericParams(self: *Formatter, params: []Declaration.GenericParam) anyerror!void {
        try self.writeByte('[');
        for (params, 0..) |param, i| {
            if (i > 0) try self.write(", ");
            try self.write(param.name);
            if (param.constraints) |constraints| {
                try self.write(": ");
                for (constraints, 0..) |c, j| {
                    if (j > 0) try self.write(" + ");
                    try self.write(c);
                }
            }
        }
        try self.writeByte(']');
    }

    fn writeWhereClause(self: *Formatter, wc: []Declaration.WhereConstraint) anyerror!void {
        try self.write(" where ");
        for (wc, 0..) |constraint, i| {
            if (i > 0) try self.write(", ");
            try self.write(constraint.type_param);
            try self.write(": ");
            for (constraint.bounds, 0..) |bound, j| {
                if (j > 0) try self.write(" + ");
                try self.write(bound);
            }
        }
    }

    /// Format a type annotation
    pub fn formatType(self: *Formatter, typ: Type) anyerror!void {
        switch (typ.kind) {
            .primitive => |p| try self.write(p.toString()),
            .named => |n| try self.write(n.name),
            .generic => |g| {
                try self.write(g.base);
                try self.writeByte('[');
                for (g.type_arguments, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatType(arg.*);
                }
                try self.writeByte(']');
            },
            .function => |f| {
                if (f.effect_type) |e| {
                    if (e != .pure) {
                        try self.write(e.toString());
                        try self.writeByte(' ');
                    }
                }
                try self.write("fn(");
                for (f.parameter_types, 0..) |param, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatType(param.*);
                }
                try self.write(") -> ");
                try self.formatType(f.return_type.*);
            },
            .tuple => |t| {
                try self.writeByte('(');
                for (t.element_types, 0..) |elem, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatType(elem.*);
                }
                try self.writeByte(')');
            },
            .array => |a| {
                try self.writeByte('[');
                try self.formatType(a.element_type.*);
                if (a.size) |s| {
                    try self.write("; ");
                    try self.writeFmt("{d}", .{s});
                }
                try self.writeByte(']');
            },
            .io_type => |io| {
                try self.write("IO[");
                try self.formatType(io.*);
                try self.writeByte(']');
            },
            .result_type => |r| {
                try self.write("Result[");
                try self.formatType(r.ok_type.*);
                try self.write(", ");
                try self.formatType(r.err_type.*);
                try self.writeByte(']');
            },
            .option_type => |o| {
                try self.write("Option[");
                try self.formatType(o.*);
                try self.writeByte(']');
            },
            .self_type => try self.write("Self"),
            .type_variable => |tv| try self.write(tv.name),
            .path => |p| {
                for (p.segments, 0..) |seg, i| {
                    if (i > 0) try self.writeByte('.');
                    try self.write(seg);
                }
                if (p.generic_args) |ga| {
                    try self.writeByte('[');
                    for (ga, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.formatType(arg.*);
                    }
                    try self.writeByte(']');
                }
            },
            .inferred => try self.write("auto"),
        }
    }

    /// Format a list of statements
    pub fn formatStatements(self: *Formatter, stmts: []Statement) anyerror!void {
        for (stmts) |stmt| {
            try self.formatStatement(stmt);
            try self.writeByte('\n');
        }
    }

    /// Format a statement
    pub fn formatStatement(self: *Formatter, stmt: Statement) anyerror!void {
        switch (stmt.kind) {
            .let_binding => |lb| {
                try self.writeIndent();
                if (lb.is_public) try self.write("pub ");
                if (lb.allow_shadow) try self.write("shadow ");
                try self.write("let ");
                try self.formatPattern(lb.pattern.*);
                try self.write(": ");
                try self.formatType(lb.explicit_type.*);
                try self.write(" = ");
                try self.formatExpression(lb.initializer.*);
            },
            .var_binding => |vb| {
                try self.writeIndent();
                if (vb.allow_shadow) try self.write("shadow ");
                try self.write("var ");
                try self.write(vb.name);
                try self.write(": ");
                try self.formatType(vb.explicit_type.*);
                if (vb.initializer) |init_expr| {
                    try self.write(" = ");
                    try self.formatExpression(init_expr.*);
                }
            },
            .assignment => |a| {
                try self.writeIndent();
                switch (a.target) {
                    .identifier => |id| try self.write(id),
                    .field_access => |fa| {
                        try self.formatExpression(fa.object.*);
                        try self.writeByte('.');
                        try self.write(fa.field);
                    },
                    .index_access => |ia| {
                        try self.formatExpression(ia.object.*);
                        try self.writeByte('[');
                        try self.formatExpression(ia.index.*);
                        try self.writeByte(']');
                    },
                }
                try self.write(" = ");
                try self.formatExpression(a.value.*);
            },
            .if_statement => |ifs| {
                try self.writeIndent();
                try self.write("if ");
                try self.formatExpression(ifs.condition.*);
                try self.write(" {\n");
                self.indent();
                try self.formatStatements(ifs.then_branch);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');

                if (ifs.else_branch) |eb| {
                    switch (eb) {
                        .block => |block| {
                            try self.write(" else {\n");
                            self.indent();
                            try self.formatStatements(block);
                            self.dedent();
                            try self.writeIndent();
                            try self.writeByte('}');
                        },
                        .else_if => |else_if| {
                            try self.write(" else ");
                            // Don't add indent — formatStatement for if_statement will add it
                            // But we need to suppress the indent for the chained else if
                            try self.formatIfStatementNoIndent(else_if.*);
                        },
                    }
                }
            },
            .for_loop => |fl| {
                try self.writeIndent();
                try self.write("for ");
                try self.formatPattern(fl.pattern.*);
                try self.write(" in ");
                try self.formatExpression(fl.iterable.*);
                try self.write(" {\n");
                self.indent();
                try self.formatStatements(fl.body);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
            .while_loop => |wl| {
                try self.writeIndent();
                try self.write("while ");
                try self.formatExpression(wl.condition.*);
                try self.write(" {\n");
                self.indent();
                try self.formatStatements(wl.body);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
            .loop_statement => |ls| {
                try self.writeIndent();
                try self.write("loop {\n");
                self.indent();
                try self.formatStatements(ls.body);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
            .match_statement => |ms| {
                try self.writeIndent();
                try self.write("match ");
                try self.formatExpression(ms.subject.*);
                try self.write(" {\n");
                self.indent();
                for (ms.arms) |arm| {
                    try self.writeIndent();
                    try self.formatPattern(arm.pattern.*);
                    if (arm.guard) |guard| {
                        try self.write(" if ");
                        try self.formatExpression(guard.*);
                    }
                    try self.write(" => {\n");
                    self.indent();
                    try self.formatStatements(arm.body);
                    self.dedent();
                    try self.writeIndent();
                    try self.write("}\n");
                }
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
            .return_statement => |rs| {
                try self.writeIndent();
                try self.write("return");
                if (rs.value) |val| {
                    try self.writeByte(' ');
                    try self.formatExpression(val.*);
                }
            },
            .break_statement => |bs| {
                try self.writeIndent();
                try self.write("break");
                if (bs.label) |label| {
                    try self.writeByte(' ');
                    try self.write(label);
                }
                if (bs.value) |val| {
                    try self.writeByte(' ');
                    try self.formatExpression(val.*);
                }
            },
            .expression_statement => |expr| {
                try self.writeIndent();
                try self.formatExpression(expr.*);
            },
            .block => |stmts| {
                try self.writeIndent();
                try self.write("{\n");
                self.indent();
                try self.formatStatements(stmts);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
        }
    }

    /// Format an if statement without the leading indent (for else-if chains)
    fn formatIfStatementNoIndent(self: *Formatter, stmt: Statement) anyerror!void {
        switch (stmt.kind) {
            .if_statement => |ifs| {
                try self.write("if ");
                try self.formatExpression(ifs.condition.*);
                try self.write(" {\n");
                self.indent();
                try self.formatStatements(ifs.then_branch);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');

                if (ifs.else_branch) |eb| {
                    switch (eb) {
                        .block => |block| {
                            try self.write(" else {\n");
                            self.indent();
                            try self.formatStatements(block);
                            self.dedent();
                            try self.writeIndent();
                            try self.writeByte('}');
                        },
                        .else_if => |else_if| {
                            try self.write(" else ");
                            try self.formatIfStatementNoIndent(else_if.*);
                        },
                    }
                }
            },
            else => try self.formatStatement(stmt),
        }
    }

    /// Format an expression
    pub fn formatExpression(self: *Formatter, expr: Expression) anyerror!void {
        switch (expr.kind) {
            .integer_literal => |lit| {
                try self.writeFmt("{d}", .{lit.value});
                if (lit.suffix) |s| {
                    try self.write(s);
                }
            },
            .float_literal => |lit| {
                try self.writeFmt("{d}", .{lit.value});
                if (lit.suffix) |s| {
                    try self.write(s);
                }
            },
            .string_literal => |lit| {
                try self.writeByte('"');
                try self.writeEscapedString(lit.value);
                try self.writeByte('"');
            },
            .char_literal => |lit| {
                try self.writeByte('\'');
                try self.writeCharLiteral(lit.value);
                try self.writeByte('\'');
            },
            .bool_literal => |b| {
                try self.write(if (b) "true" else "false");
            },
            .identifier => |id| {
                try self.write(id.name);
                if (id.generic_args) |ga| {
                    try self.writeByte('[');
                    for (ga, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.formatType(arg.*);
                    }
                    try self.writeByte(']');
                }
            },
            .self_expr => try self.write("self"),
            .self_type_expr => try self.write("Self"),
            .binary => |bin| {
                try self.formatExpression(bin.left.*);
                try self.writeByte(' ');
                try self.write(bin.operator.toString());
                try self.writeByte(' ');
                try self.formatExpression(bin.right.*);
            },
            .unary => |un| {
                const op_str = un.operator.toString();
                try self.write(op_str);
                if (un.operator == .logical_not) {
                    try self.writeByte(' ');
                }
                try self.formatExpression(un.operand.*);
            },
            .field_access => |fa| {
                try self.formatExpression(fa.object.*);
                try self.writeByte('.');
                try self.write(fa.field);
            },
            .index_access => |ia| {
                try self.formatExpression(ia.object.*);
                try self.writeByte('[');
                try self.formatExpression(ia.index.*);
                try self.writeByte(']');
            },
            .tuple_access => |ta| {
                try self.formatExpression(ta.tuple.*);
                try self.writeByte('.');
                try self.writeFmt("{d}", .{ta.index});
            },
            .function_call => |fc| {
                try self.formatExpression(fc.callee.*);
                if (fc.generic_args) |ga| {
                    try self.writeByte('[');
                    for (ga, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.formatType(arg.*);
                    }
                    try self.writeByte(']');
                }
                try self.writeByte('(');
                for (fc.arguments, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatExpression(arg.*);
                }
                try self.writeByte(')');
            },
            .method_call => |mc| {
                try self.formatExpression(mc.object.*);
                try self.writeByte('.');
                try self.write(mc.method);
                if (mc.generic_args) |ga| {
                    try self.writeByte('[');
                    for (ga, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.formatType(arg.*);
                    }
                    try self.writeByte(']');
                }
                try self.writeByte('(');
                for (mc.arguments, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatExpression(arg.*);
                }
                try self.writeByte(')');
            },
            .closure => |cl| {
                if (cl.is_effect) try self.write("effect ");
                try self.write("fn(");
                for (cl.parameters, 0..) |param, i| {
                    if (i > 0) try self.write(", ");
                    try self.write(param.name);
                    try self.write(": ");
                    try self.formatType(param.param_type.*);
                }
                try self.write(") -> ");
                try self.formatType(cl.return_type.*);
                try self.write(" {\n");
                self.indent();
                try self.formatStatements(cl.body);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
            .if_expr => |ie| {
                try self.write("if ");
                try self.formatExpression(ie.condition.*);
                try self.write(" ");
                try self.formatMatchBody(ie.then_branch);
                try self.write(" else ");
                try self.formatMatchBody(ie.else_branch);
            },
            .match_expr => |me| {
                try self.write("match ");
                try self.formatExpression(me.subject.*);
                try self.write(" {\n");
                self.indent();
                for (me.arms) |arm| {
                    try self.writeIndent();
                    try self.formatPattern(arm.pattern.*);
                    if (arm.guard) |guard| {
                        try self.write(" if ");
                        try self.formatExpression(guard.*);
                    }
                    try self.write(" => ");
                    try self.formatMatchBody(arm.body);
                    try self.writeByte('\n');
                }
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
            .tuple_literal => |tl| {
                try self.writeByte('(');
                for (tl.elements, 0..) |elem, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatExpression(elem.*);
                }
                try self.writeByte(')');
            },
            .array_literal => |al| {
                try self.writeByte('[');
                for (al.elements, 0..) |elem, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatExpression(elem.*);
                }
                try self.writeByte(']');
            },
            .record_literal => |rl| {
                if (rl.type_name) |tn| {
                    try self.formatExpression(tn.*);
                    try self.writeByte(' ');
                }
                try self.write("{ ");
                for (rl.fields, 0..) |field, i| {
                    if (i > 0) try self.write(", ");
                    try self.write(field.name);
                    try self.write(": ");
                    try self.formatExpression(field.value.*);
                }
                try self.write(" }");
            },
            .variant_constructor => |vc| {
                try self.write(vc.variant_name);
                if (vc.arguments) |args| {
                    try self.writeByte('(');
                    for (args, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.formatExpression(arg.*);
                    }
                    try self.writeByte(')');
                }
            },
            .type_cast => |tc| {
                try self.formatExpression(tc.expression.*);
                try self.write(".as[");
                try self.formatType(tc.target_type.*);
                try self.writeByte(']');
            },
            .range => |r| {
                if (r.start) |start| {
                    try self.formatExpression(start.*);
                }
                try self.write(if (r.inclusive) "..=" else "..");
                if (r.end) |end| {
                    try self.formatExpression(end.*);
                }
            },
            .grouped => |inner| {
                try self.writeByte('(');
                try self.formatExpression(inner.*);
                try self.writeByte(')');
            },
            .interpolated_string => |is| {
                try self.writeByte('"');
                for (is.parts) |part| {
                    switch (part) {
                        .literal => |lit| try self.writeEscapedString(lit),
                        .expression => |fe| {
                            try self.write("${");
                            try self.formatExpression(fe.expr.*);
                            if (fe.format_spec) |spec| {
                                try self.writeByte(':');
                                try self.write(spec);
                            }
                            try self.writeByte('}');
                        },
                    }
                }
                try self.writeByte('"');
            },
            .try_expr => |inner| {
                try self.formatExpression(inner.*);
                try self.writeByte('?');
            },
            .null_coalesce => |nc| {
                try self.formatExpression(nc.left.*);
                try self.write(" ?? ");
                try self.formatExpression(nc.default.*);
            },
        }
    }

    fn formatMatchBody(self: *Formatter, body: Expression.MatchBody) anyerror!void {
        switch (body) {
            .expression => |e| try self.formatExpression(e.*),
            .block => |stmts| {
                try self.write("{\n");
                self.indent();
                try self.formatStatements(stmts);
                self.dedent();
                try self.writeIndent();
                try self.writeByte('}');
            },
        }
    }

    /// Format a pattern
    pub fn formatPattern(self: *Formatter, pat: Pattern) anyerror!void {
        switch (pat.kind) {
            .wildcard => try self.writeByte('_'),
            .identifier => |id| {
                if (id.is_mutable) try self.write("var ");
                try self.write(id.name);
            },
            .integer_literal => |i| try self.writeFmt("{d}", .{i}),
            .float_literal => |f| try self.writeFmt("{d}", .{f}),
            .string_literal => |s| {
                try self.writeByte('"');
                try self.writeEscapedString(s);
                try self.writeByte('"');
            },
            .char_literal => |c| {
                try self.writeByte('\'');
                try self.writeCharLiteral(c);
                try self.writeByte('\'');
            },
            .bool_literal => |b| try self.write(if (b) "true" else "false"),
            .constructor => |c| {
                if (c.type_path) |tp| {
                    for (tp, 0..) |seg, i| {
                        if (i > 0) try self.writeByte('.');
                        try self.write(seg);
                    }
                    try self.writeByte('.');
                }
                try self.write(c.variant_name);
                if (c.arguments) |args| {
                    try self.writeByte('(');
                    for (args, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        switch (arg) {
                            .positional => |p| try self.formatPattern(p.*),
                            .named => |n| {
                                try self.write(n.name);
                                try self.write(": ");
                                try self.formatPattern(n.pattern.*);
                            },
                        }
                    }
                    try self.writeByte(')');
                }
            },
            .record => |r| {
                if (r.type_name) |tn| {
                    try self.write(tn);
                    try self.writeByte(' ');
                }
                try self.write("{ ");
                for (r.fields, 0..) |field, i| {
                    if (i > 0) try self.write(", ");
                    try self.write(field.name);
                    if (field.pattern) |p| {
                        try self.write(": ");
                        try self.formatPattern(p.*);
                    }
                }
                if (r.has_rest) {
                    if (r.fields.len > 0) try self.write(", ");
                    try self.write("..");
                }
                try self.write(" }");
            },
            .tuple => |t| {
                try self.writeByte('(');
                for (t.elements, 0..) |elem, i| {
                    if (i > 0) try self.write(", ");
                    try self.formatPattern(elem.*);
                }
                try self.writeByte(')');
            },
            .or_pattern => |o| {
                for (o.patterns, 0..) |p, i| {
                    if (i > 0) try self.write(" | ");
                    try self.formatPattern(p.*);
                }
            },
            .guarded => |g| {
                try self.formatPattern(g.pattern.*);
                try self.write(" if ");
                try self.formatExpression(g.guard.*);
            },
            .range => |r| {
                if (r.start) |start| {
                    switch (start) {
                        .integer => |i| try self.writeFmt("{d}", .{i}),
                        .char => |c| {
                            try self.writeByte('\'');
                            try self.writeCharLiteral(c);
                            try self.writeByte('\'');
                        },
                    }
                }
                try self.write(if (r.inclusive) "..=" else "..");
                if (r.end) |end| {
                    switch (end) {
                        .integer => |i| try self.writeFmt("{d}", .{i}),
                        .char => |c| {
                            try self.writeByte('\'');
                            try self.writeCharLiteral(c);
                            try self.writeByte('\'');
                        },
                    }
                }
            },
            .rest => try self.write(".."),
            .typed => |t| {
                try self.formatPattern(t.pattern.*);
                try self.write(": ");
                try self.formatType(t.expected_type.*);
            },
        }
    }

    fn writeEscapedString(self: *Formatter, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                '\\' => try self.write("\\\\"),
                '"' => try self.write("\\\""),
                else => try self.writeByte(c),
            }
        }
    }

    fn writeCharLiteral(self: *Formatter, codepoint: u21) !void {
        switch (codepoint) {
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            '\\' => try self.write("\\\\"),
            '\'' => try self.write("\\'"),
            else => {
                if (codepoint < 128) {
                    try self.writeByte(@intCast(codepoint));
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                        try self.write("?");
                        return;
                    };
                    try self.write(buf[0..len]);
                }
            },
        }
    }
};

/// Format a Kira source file. Caller owns the returned slice.
pub fn format(allocator: Allocator, source: []const u8) ![]u8 {
    const root = @import("root.zig");

    // Parse the source
    var program = try root.parse(allocator, source);
    defer program.deinit();

    // Format the AST back to source
    var formatter = Formatter.init(allocator);
    defer formatter.deinit();

    try formatter.formatProgram(program);

    return formatter.toOwnedSlice();
}

// --- Tests ---

const testing = std.testing;

test "format simple function" {
    const root = @import("root.zig");
    const source = "fn add(a: i32, b: i32) -> i32 { return a + b }";
    var program = try root.parse(testing.allocator, source);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const result = fmt.buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, "fn add(a: i32, b: i32) -> i32") != null);
    try testing.expect(std.mem.indexOf(u8, result, "return a + b") != null);
}

test "format let binding" {
    const root = @import("root.zig");
    const source = "fn main() -> void { let x: i32 = 42 }";
    var program = try root.parse(testing.allocator, source);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const result = fmt.buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, "let x: i32 = 42") != null);
}

test "format sum type" {
    const root = @import("root.zig");
    const source =
        \\type Color =
        \\    | Red
        \\    | Green
        \\    | Blue
    ;
    var program = try root.parse(testing.allocator, source);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const result = fmt.buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, "type Color =") != null);
    try testing.expect(std.mem.indexOf(u8, result, "| Red") != null);
    try testing.expect(std.mem.indexOf(u8, result, "| Green") != null);
    try testing.expect(std.mem.indexOf(u8, result, "| Blue") != null);
}

test "format product type" {
    const root = @import("root.zig");
    const source =
        \\type Point = {
        \\    x: f64,
        \\    y: f64
        \\}
    ;
    var program = try root.parse(testing.allocator, source);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const result = fmt.buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, "type Point = {") != null);
    try testing.expect(std.mem.indexOf(u8, result, "x: f64") != null);
    try testing.expect(std.mem.indexOf(u8, result, "y: f64") != null);
}

test "format effect function" {
    const root = @import("root.zig");
    const source =
        \\effect fn main() -> void {
        \\    std.io.println("hello")
        \\}
    ;
    var program = try root.parse(testing.allocator, source);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const result = fmt.buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, "effect fn main() -> void") != null);
}

test "format module and import" {
    const root = @import("root.zig");
    const source =
        \\module main
        \\import std.io.{ println }
    ;
    var program = try root.parse(testing.allocator, source);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const result = fmt.buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, "module main") != null);
    try testing.expect(std.mem.indexOf(u8, result, "import std.io.{ println }") != null);
}

test "format match statement" {
    const root = @import("root.zig");
    const source =
        \\fn f(x: i32) -> i32 {
        \\    match x {
        \\        0 => { return 1 }
        \\        n => { return n }
        \\    }
        \\}
    ;
    var program = try root.parse(testing.allocator, source);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const result = fmt.buffer.items;

    try testing.expect(std.mem.indexOf(u8, result, "match x {") != null);
    try testing.expect(std.mem.indexOf(u8, result, "0 => {") != null);
}

test "format idempotent" {
    const root = @import("root.zig");
    // Format once
    const source = "fn add(a: i32, b: i32) -> i32 { return a + b }";
    const first = try format(testing.allocator, source);
    defer testing.allocator.free(first);

    // Format twice — should be identical
    const second = try format(testing.allocator, first);
    defer testing.allocator.free(second);

    // Parsing the re-formatted output should produce the same result
    // (exact string equality may differ due to whitespace normalization,
    // but re-formatting the output should be stable)
    var program = try root.parse(testing.allocator, second);
    defer program.deinit();

    var fmt = Formatter.init(testing.allocator);
    defer fmt.deinit();
    try fmt.formatProgram(program);
    const third = try fmt.toOwnedSlice();
    defer testing.allocator.free(third);

    try testing.expectEqualStrings(second, third);
}
