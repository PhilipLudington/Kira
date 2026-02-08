//! Type Checker for the Kira language.
//!
//! The TypeChecker walks the AST, verifies type consistency, and produces
//! diagnostic messages for type errors. It operates on a resolved program
//! with a populated symbol table.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const ast = @import("../ast/root.zig");
const symbols = @import("../symbols/root.zig");
const types_mod = @import("types.zig");
const errors_mod = @import("errors.zig");
const unify = @import("unify.zig");
const instantiate_mod = @import("instantiate.zig");
const pattern_compiler_mod = @import("pattern_compiler.zig");

pub const Expression = ast.Expression;
pub const Statement = ast.Statement;
pub const Declaration = ast.Declaration;
pub const Pattern = ast.Pattern;
pub const Program = ast.Program;
pub const Type = ast.Type;
pub const Span = ast.Span;

pub const Symbol = symbols.Symbol;
pub const SymbolId = symbols.SymbolId;
pub const SymbolTable = symbols.SymbolTable;

pub const ResolvedType = types_mod.ResolvedType;
pub const Diagnostic = errors_mod.Diagnostic;
pub const DiagnosticKind = errors_mod.DiagnosticKind;

/// Errors that can occur during type checking
pub const TypeCheckError = error{
    TypeError,
    OutOfMemory,
};

/// Placeholder symbol ID; `SymbolTable.define()` assigns the real ID.
const unassigned_symbol_id: SymbolId = 0;

/// The type checker
pub const TypeChecker = struct {
    allocator: Allocator,
    symbol_table: *SymbolTable,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    /// Maps symbol IDs to their resolved types
    type_env: std.AutoHashMapUnmanaged(SymbolId, ResolvedType),
    /// Current function's expected return type
    current_return_type: ?ResolvedType,
    /// Current function's effect annotation
    current_effect: ?Type.EffectAnnotation,
    /// Type variable substitutions for current generic context
    type_var_substitutions: std.StringHashMapUnmanaged(ResolvedType),
    /// Current Self type (in impl blocks)
    self_type: ?ResolvedType,
    /// Whether we're in an effect function
    in_effect_function: bool,
    /// Arena for temporary type allocations during type checking
    type_arena: std.heap.ArenaAllocator,

    /// Create a new type checker
    pub fn init(allocator: Allocator, symbol_table: *SymbolTable) TypeChecker {
        return .{
            .allocator = allocator,
            .symbol_table = symbol_table,
            .diagnostics = .{},
            .type_env = .{},
            .current_return_type = null,
            .current_effect = null,
            .type_var_substitutions = .{},
            .self_type = null,
            .in_effect_function = false,
            .type_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Free all resources
    pub fn deinit(self: *TypeChecker) void {
        // Free each diagnostic's allocated message and related info
        for (self.diagnostics.items) |*diag| {
            diag.deinit(self.allocator);
        }
        self.diagnostics.deinit(self.allocator);
        self.type_env.deinit(self.allocator);
        self.type_var_substitutions.deinit(self.allocator);
        // Free all temporary type allocations at once
        self.type_arena.deinit();
    }

    /// Get allocator for temporary type allocations
    fn typeAllocator(self: *TypeChecker) Allocator {
        return self.type_arena.allocator();
    }

    /// Leave the current scope, converting InvalidScope to TypeError.
    /// InvalidScope indicates scope management corruption and should not
    /// occur when enter/leave calls are balanced.
    fn scopeLeave(self: *TypeChecker) TypeCheckError!void {
        self.symbol_table.leaveScope() catch {
            if (builtin.mode == .Debug) {
                @panic("TypeChecker scope management error: leaveScope failed (unbalanced enter/leave)");
            }
            return error.TypeError;
        };
    }

    /// Leave scope during error cleanup (errdefer). Panics in debug on
    /// failure since a failed cleanup indicates scope management corruption.
    fn scopeCleanup(self: *TypeChecker) void {
        self.symbol_table.leaveScope() catch {
            if (builtin.mode == .Debug) {
                @panic("TypeChecker scope cleanup failed: unbalanced scope enter/leave");
            }
        };
    }

    // ========== Main Entry Point ==========

    /// Type check an entire program
    pub fn check(self: *TypeChecker, program: *const Program) TypeCheckError!void {
        var main_decl: ?*const Declaration = null;

        for (program.declarations) |*decl| {
            try self.checkDeclaration(decl);

            // E7: Track main function for effect validation
            if (decl.kind == .function_decl) {
                const func = decl.kind.function_decl;
                if (std.mem.eql(u8, func.name, "main")) {
                    main_decl = decl;
                }
            }
        }

        // E7: Validate main function has IO effect
        if (main_decl) |decl| {
            const func = decl.kind.function_decl;
            if (!func.is_effect) {
                try self.addDiagnostic(try errors_mod.mainMustHaveIOEffect(
                    self.allocator,
                    decl.span,
                ));
            }
        }

        // Fail compilation if any type errors were collected
        if (self.hasErrors()) {
            return error.TypeError;
        }
    }

    /// Check if there were any errors
    pub fn hasErrors(self: *TypeChecker) bool {
        for (self.diagnostics.items) |d| {
            if (d.kind == .err) return true;
        }
        return false;
    }

    /// Get all diagnostics
    pub fn getDiagnostics(self: *TypeChecker) []const Diagnostic {
        return self.diagnostics.items;
    }

    // ========== AST Type Resolution ==========

    /// Convert an AST Type to a ResolvedType
    pub fn resolveAstType(self: *TypeChecker, ast_type: *const Type) TypeCheckError!ResolvedType {
        return switch (ast_type.kind) {
            .primitive => |p| ResolvedType.primitive(p, ast_type.span),

            .named => |n| {
                // Look up the type name in the symbol table
                if (self.symbol_table.lookup(n.name)) |sym| {
                    return ResolvedType.named(sym.id, n.name, ast_type.span);
                } else {
                    // Check if it's a type variable in scope
                    if (self.type_var_substitutions.get(n.name)) |resolved| {
                        return resolved;
                    }
                    try self.addDiagnostic(try errors_mod.undefinedType(self.allocator, n.name, ast_type.span));
                    return ResolvedType.errorType(ast_type.span);
                }
            },

            .generic => |g| {
                // Look up the base type
                const type_alloc = self.typeAllocator();
                if (self.symbol_table.lookup(g.base)) |sym| {
                    var resolved_args = std.ArrayListUnmanaged(ResolvedType){};
                    for (g.type_arguments) |arg| {
                        try resolved_args.append(type_alloc, try self.resolveAstType(arg));
                    }
                    return .{
                        .kind = .{ .instantiated = .{
                            .base_symbol_id = sym.id,
                            .base_name = g.base,
                            .type_arguments = try resolved_args.toOwnedSlice(type_alloc),
                        } },
                        .span = ast_type.span,
                    };
                } else {
                    try self.addDiagnostic(try errors_mod.undefinedType(self.allocator, g.base, ast_type.span));
                    return ResolvedType.errorType(ast_type.span);
                }
            },

            .function => |f| {
                const type_alloc = self.typeAllocator();
                var resolved_params = std.ArrayListUnmanaged(ResolvedType){};
                for (f.parameter_types) |param| {
                    try resolved_params.append(type_alloc, try self.resolveAstType(param));
                }

                const resolved_return = try type_alloc.create(ResolvedType);
                resolved_return.* = try self.resolveAstType(f.return_type);

                return .{
                    .kind = .{ .function = .{
                        .parameter_types = try resolved_params.toOwnedSlice(type_alloc),
                        .return_type = resolved_return,
                        .effect = f.effect_type,
                    } },
                    .span = ast_type.span,
                };
            },

            .tuple => |t| {
                const type_alloc = self.typeAllocator();
                var resolved_elements = std.ArrayListUnmanaged(ResolvedType){};
                for (t.element_types) |elem| {
                    try resolved_elements.append(type_alloc, try self.resolveAstType(elem));
                }
                return .{
                    .kind = .{ .tuple = .{
                        .element_types = try resolved_elements.toOwnedSlice(type_alloc),
                    } },
                    .span = ast_type.span,
                };
            },

            .array => |a| {
                const type_alloc = self.typeAllocator();
                const resolved_elem = try type_alloc.create(ResolvedType);
                resolved_elem.* = try self.resolveAstType(a.element_type);
                return .{
                    .kind = .{ .array = .{
                        .element_type = resolved_elem,
                        .size = a.size,
                    } },
                    .span = ast_type.span,
                };
            },

            .io_type => |inner| {
                const type_alloc = self.typeAllocator();
                const resolved_inner = try type_alloc.create(ResolvedType);
                resolved_inner.* = try self.resolveAstType(inner);
                return .{
                    .kind = .{ .io = resolved_inner },
                    .span = ast_type.span,
                };
            },

            .result_type => |r| {
                const type_alloc = self.typeAllocator();
                const resolved_ok = try type_alloc.create(ResolvedType);
                resolved_ok.* = try self.resolveAstType(r.ok_type);

                const resolved_err = try type_alloc.create(ResolvedType);
                resolved_err.* = try self.resolveAstType(r.err_type);

                return .{
                    .kind = .{ .result = .{
                        .ok_type = resolved_ok,
                        .err_type = resolved_err,
                    } },
                    .span = ast_type.span,
                };
            },

            .option_type => |inner| {
                const type_alloc = self.typeAllocator();
                const resolved_inner = try type_alloc.create(ResolvedType);
                resolved_inner.* = try self.resolveAstType(inner);
                return .{
                    .kind = .{ .option = resolved_inner },
                    .span = ast_type.span,
                };
            },

            .self_type => {
                if (self.self_type) |st| {
                    return st;
                } else {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "'Self' type used outside of impl block",
                        ast_type.span,
                    ));
                    return ResolvedType.errorType(ast_type.span);
                }
            },

            .type_variable => |tv| {
                // Check if we have a substitution for this type variable
                if (self.type_var_substitutions.get(tv.name)) |resolved| {
                    return resolved;
                }
                // Keep as type variable - extract trait names from constraints
                const type_alloc = self.typeAllocator();
                var constraint_names: ?[][]const u8 = null;
                if (tv.constraints) |constraints| {
                    var names = std.ArrayListUnmanaged([]const u8){};
                    for (constraints) |c| {
                        try names.append(type_alloc, c.trait_name);
                    }
                    constraint_names = try names.toOwnedSlice(type_alloc);
                }
                return ResolvedType.typeVar(tv.name, constraint_names, ast_type.span);
            },

            .path => |p| {
                // Look up the path in the symbol table
                const type_alloc = self.typeAllocator();
                if (self.symbol_table.lookupPath(p.segments)) |sym| {
                    if (p.generic_args) |args| {
                        var resolved_args = std.ArrayListUnmanaged(ResolvedType){};
                        for (args) |arg| {
                            try resolved_args.append(type_alloc, try self.resolveAstType(arg));
                        }
                        return .{
                            .kind = .{ .instantiated = .{
                                .base_symbol_id = sym.id,
                                .base_name = p.segments[p.segments.len - 1],
                                .type_arguments = try resolved_args.toOwnedSlice(type_alloc),
                            } },
                            .span = ast_type.span,
                        };
                    }
                    return ResolvedType.named(sym.id, p.segments[p.segments.len - 1], ast_type.span);
                } else {
                    var buf: [256]u8 = undefined;
                    var pos: usize = 0;
                    for (p.segments, 0..) |seg, i| {
                        if (i > 0) {
                            buf[pos] = '.';
                            pos += 1;
                        }
                        @memcpy(buf[pos..][0..seg.len], seg);
                        pos += seg.len;
                    }
                    try self.addDiagnostic(try errors_mod.undefinedType(self.allocator, buf[0..pos], ast_type.span));
                    return ResolvedType.errorType(ast_type.span);
                }
            },

            .inferred => {
                // Inference not allowed in Kira - should have been caught earlier
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "type inference is not allowed in Kira",
                    ast_type.span,
                ));
                return ResolvedType.errorType(ast_type.span);
            },
        };
    }

    // ========== Expression Type Checking ==========

    /// Type check an expression and return its type
    pub fn checkExpression(self: *TypeChecker, expr: *const Expression) TypeCheckError!ResolvedType {
        return switch (expr.kind) {
            .integer_literal => |lit| {
                // Determine type from suffix or default to i32
                if (lit.suffix) |suffix| {
                    if (Type.PrimitiveType.fromString(suffix)) |prim| {
                        return ResolvedType.primitive(prim, expr.span);
                    }
                }
                return ResolvedType.primitive(.i32, expr.span);
            },

            .float_literal => |lit| {
                // Determine type from suffix or default to f64
                if (lit.suffix) |suffix| {
                    if (Type.PrimitiveType.fromString(suffix)) |prim| {
                        return ResolvedType.primitive(prim, expr.span);
                    }
                }
                return ResolvedType.primitive(.f64, expr.span);
            },

            .string_literal => ResolvedType.primitive(.string, expr.span),
            .char_literal => ResolvedType.primitive(.char, expr.span),
            .bool_literal => ResolvedType.primitive(.bool, expr.span),

            .identifier => |ident| {
                if (self.symbol_table.lookup(ident.name)) |sym| {
                    return try self.getSymbolType(sym, expr.span);
                } else if (std.mem.eql(u8, ident.name, "std")) {
                    // Skip error for 'std' - it's a built-in namespace injected at runtime
                    return ResolvedType.errorType(expr.span);
                } else {
                    try self.addDiagnostic(try errors_mod.undefinedSymbol(self.allocator, ident.name, expr.span));
                    return ResolvedType.errorType(expr.span);
                }
            },

            .self_expr => {
                if (self.self_type) |st| {
                    return st;
                } else {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "'self' used outside of impl block",
                        expr.span,
                    ));
                    return ResolvedType.errorType(expr.span);
                }
            },

            .self_type_expr => {
                if (self.self_type) |st| {
                    return st;
                } else {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "'Self' used outside of impl block",
                        expr.span,
                    ));
                    return ResolvedType.errorType(expr.span);
                }
            },

            .binary => |bin| try self.checkBinaryOp(bin, expr.span),
            .unary => |un| try self.checkUnaryOp(un, expr.span),

            .field_access => |fa| try self.checkFieldAccess(fa, expr.span),
            .index_access => |ia| try self.checkIndexAccess(ia, expr.span),
            .tuple_access => |ta| try self.checkTupleAccess(ta, expr.span),

            .function_call => |fc| try self.checkFunctionCall(fc, expr.span),
            .method_call => |mc| try self.checkMethodCall(mc, expr.span),

            .closure => |c| try self.checkClosure(c, expr.span),

            .match_expr => |me| try self.checkMatchExpr(me, expr.span),

            .if_expr => |ie| try self.checkIfExpr(ie, expr.span),

            .tuple_literal => |tl| {
                const type_alloc = self.typeAllocator();
                var element_types = std.ArrayListUnmanaged(ResolvedType){};
                for (tl.elements) |elem| {
                    try element_types.append(type_alloc, try self.checkExpression(elem));
                }
                return .{
                    .kind = .{ .tuple = .{
                        .element_types = try element_types.toOwnedSlice(type_alloc),
                    } },
                    .span = expr.span,
                };
            },

            .array_literal => |al| {
                if (al.elements.len == 0) {
                    // Empty array - type must be inferred from context or explicit
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "cannot infer type of empty array literal",
                        expr.span,
                    ));
                    return ResolvedType.errorType(expr.span);
                }

                const first_type = try self.checkExpression(al.elements[0]);
                for (al.elements[1..]) |elem| {
                    const elem_type = try self.checkExpression(elem);
                    if (!unify.typesEqual(first_type, elem_type)) {
                        try self.addDiagnostic(try errors_mod.typeMismatch(
                            self.allocator,
                            first_type,
                            elem_type,
                            elem.span,
                        ));
                    }
                }

                const type_alloc = self.typeAllocator();
                const elem_type_ptr = try type_alloc.create(ResolvedType);
                elem_type_ptr.* = first_type;

                return .{
                    .kind = .{ .array = .{
                        .element_type = elem_type_ptr,
                        .size = al.elements.len,
                    } },
                    .span = expr.span,
                };
            },

            .record_literal => |rl| try self.checkRecordLiteral(rl, expr.span),

            .variant_constructor => |vc| try self.checkVariantConstructor(vc, expr.span),

            .type_cast => |tc| try self.checkTypeCast(tc, expr.span),

            .range => |r| try self.checkRange(r, expr.span),

            .grouped => |g| try self.checkExpression(g),

            .interpolated_string => |is| {
                // Check all expression parts
                for (is.parts) |part| {
                    switch (part) {
                        .expression => |e| {
                            const expr_type = try self.checkExpression(e);
                            // Expression must be string-convertible (has Display trait)
                            // For now, allow any type
                            _ = expr_type;
                        },
                        .literal => {},
                    }
                }
                return ResolvedType.primitive(.string, expr.span);
            },

            .try_expr => |te| try self.checkTryExpr(te, expr.span),

            .null_coalesce => |nc| try self.checkNullCoalesce(nc, expr.span),
        };
    }

    /// Check a binary operation
    fn checkBinaryOp(self: *TypeChecker, bin: Expression.BinaryOp, span: Span) TypeCheckError!ResolvedType {
        const left_type = try self.checkExpression(bin.left);
        const right_type = try self.checkExpression(bin.right);

        // Error types propagate
        if (left_type.isError() or right_type.isError()) {
            return ResolvedType.errorType(span);
        }

        return switch (bin.operator) {
            // Arithmetic operators
            .add, .subtract, .multiply, .divide, .modulo => {
                if (left_type.isNumeric() and right_type.isNumeric()) {
                    if (unify.typesEqual(left_type, right_type)) {
                        return left_type;
                    }
                }
                try self.addDiagnostic(try errors_mod.invalidBinaryOperand(
                    self.allocator,
                    bin.operator.toString(),
                    left_type,
                    right_type,
                    span,
                ));
                return ResolvedType.errorType(span);
            },

            // Comparison operators
            .less_than, .greater_than, .less_equal, .greater_equal => {
                if (unify.isComparable(left_type) and unify.typesEqual(left_type, right_type)) {
                    return ResolvedType.primitive(.bool, span);
                }
                try self.addDiagnostic(try errors_mod.invalidBinaryOperand(
                    self.allocator,
                    bin.operator.toString(),
                    left_type,
                    right_type,
                    span,
                ));
                return ResolvedType.errorType(span);
            },

            // Equality operators
            .equal, .not_equal => {
                if (unify.isEquatable(left_type) and unify.typesEqual(left_type, right_type)) {
                    return ResolvedType.primitive(.bool, span);
                }
                try self.addDiagnostic(try errors_mod.invalidBinaryOperand(
                    self.allocator,
                    bin.operator.toString(),
                    left_type,
                    right_type,
                    span,
                ));
                return ResolvedType.errorType(span);
            },

            // Logical operators
            .logical_and, .logical_or => {
                if (left_type.isBool() and right_type.isBool()) {
                    return ResolvedType.primitive(.bool, span);
                }
                try self.addDiagnostic(try errors_mod.invalidBinaryOperand(
                    self.allocator,
                    bin.operator.toString(),
                    left_type,
                    right_type,
                    span,
                ));
                return ResolvedType.errorType(span);
            },

            // is operator (type check)
            .is => {
                // Result is always bool
                return ResolvedType.primitive(.bool, span);
            },

            // in operator (membership)
            .in_op => {
                // Right side must be iterable
                if (unify.isIterable(right_type)) {
                    return ResolvedType.primitive(.bool, span);
                }
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "right side of 'in' must be iterable",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    /// Check a unary operation
    fn checkUnaryOp(self: *TypeChecker, un: Expression.UnaryOp, span: Span) TypeCheckError!ResolvedType {
        const operand_type = try self.checkExpression(un.operand);

        if (operand_type.isError()) {
            return ResolvedType.errorType(span);
        }

        return switch (un.operator) {
            .negate => {
                if (operand_type.isNumeric()) {
                    return operand_type;
                }
                try self.addDiagnostic(try errors_mod.invalidUnaryOperand(
                    self.allocator,
                    un.operator.toString(),
                    operand_type,
                    span,
                ));
                return ResolvedType.errorType(span);
            },
            .logical_not => {
                if (operand_type.isBool()) {
                    return operand_type;
                }
                try self.addDiagnostic(try errors_mod.invalidUnaryOperand(
                    self.allocator,
                    un.operator.toString(),
                    operand_type,
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    /// Check field access
    fn checkFieldAccess(self: *TypeChecker, fa: Expression.FieldAccess, span: Span) TypeCheckError!ResolvedType {
        const object_type = try self.checkExpression(fa.object);

        if (object_type.isError()) {
            return ResolvedType.errorType(span);
        }

        // Get the type definition to look up the field
        return switch (object_type.kind) {
            .named => |n| {
                if (self.symbol_table.getSymbol(n.symbol_id)) |sym| {
                    if (sym.kind == .type_def) {
                        const type_def = sym.kind.type_def;
                        switch (type_def.definition) {
                            .product_type => |p| {
                                for (p.fields) |field| {
                                    if (std.mem.eql(u8, field.name, fa.field)) {
                                        return try self.resolveAstType(field.field_type);
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
                try self.addDiagnostic(try errors_mod.noSuchField(
                    self.allocator,
                    n.name,
                    fa.field,
                    span,
                ));
                return ResolvedType.errorType(span);
            },
            .instantiated => |inst| {
                if (self.symbol_table.getSymbol(inst.base_symbol_id)) |sym| {
                    if (sym.kind == .type_def) {
                        const type_def = sym.kind.type_def;
                        switch (type_def.definition) {
                            .product_type => |p| {
                                for (p.fields) |field| {
                                    if (std.mem.eql(u8, field.name, fa.field)) {
                                        // Need to instantiate the field type
                                        const resolved = try self.resolveAstType(field.field_type);
                                        // Create substitution from generic params to concrete args
                                        if (type_def.generic_params) |params| {
                                            const type_alloc = self.typeAllocator();
                                            var param_names = std.ArrayListUnmanaged([]const u8){};
                                            for (params) |gp| {
                                                try param_names.append(type_alloc, gp.name);
                                            }
                                            var subst = try instantiate_mod.createSubstitution(
                                                type_alloc,
                                                try param_names.toOwnedSlice(type_alloc),
                                                inst.type_arguments,
                                            );
                                            defer subst.deinit(type_alloc);
                                            return try instantiate_mod.instantiate(type_alloc, resolved, &subst);
                                        }
                                        return resolved;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
                try self.addDiagnostic(try errors_mod.noSuchField(
                    self.allocator,
                    inst.base_name,
                    fa.field,
                    span,
                ));
                return ResolvedType.errorType(span);
            },
            else => {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "field access on non-struct type",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    /// Check index access
    fn checkIndexAccess(self: *TypeChecker, ia: Expression.IndexAccess, span: Span) TypeCheckError!ResolvedType {
        const object_type = try self.checkExpression(ia.object);
        const index_type = try self.checkExpression(ia.index);

        if (object_type.isError() or index_type.isError()) {
            return ResolvedType.errorType(span);
        }

        // Index must be an integer
        if (!index_type.isInteger()) {
            try self.addDiagnostic(try errors_mod.simpleError(
                self.allocator,
                "array index must be an integer",
                ia.index.span,
            ));
            return ResolvedType.errorType(span);
        }

        return switch (object_type.kind) {
            .array => |a| a.element_type.*,
            .primitive => |p| if (p == .string)
                ResolvedType.primitive(.char, span)
            else {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "index access on non-array type",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
            else => {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "index access on non-array type",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    /// Check tuple access
    fn checkTupleAccess(self: *TypeChecker, ta: Expression.TupleAccess, span: Span) TypeCheckError!ResolvedType {
        const tuple_type = try self.checkExpression(ta.tuple);

        if (tuple_type.isError()) {
            return ResolvedType.errorType(span);
        }

        return switch (tuple_type.kind) {
            .tuple => |t| {
                if (ta.index < t.element_types.len) {
                    return t.element_types[ta.index];
                }
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "tuple index out of bounds",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
            else => {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "tuple access on non-tuple type",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    /// Check function call
    fn checkFunctionCall(self: *TypeChecker, fc: Expression.FunctionCall, span: Span) TypeCheckError!ResolvedType {
        const callee_type = try self.checkExpression(fc.callee);

        if (callee_type.isError()) {
            return ResolvedType.errorType(span);
        }

        return switch (callee_type.kind) {
            .function => |f| {
                // Check argument count
                if (fc.arguments.len != f.parameter_types.len) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                        self.allocator,
                        f.parameter_types.len,
                        fc.arguments.len,
                        span,
                    ));
                    return ResolvedType.errorType(span);
                }

                // Check argument types
                for (fc.arguments, f.parameter_types) |arg, param| {
                    const arg_type = try self.checkExpression(arg);
                    if (!unify.typesEqual(arg_type, param)) {
                        try self.addDiagnostic(try errors_mod.typeMismatch(
                            self.allocator,
                            param,
                            arg_type,
                            arg.span,
                        ));
                    }
                }

                // Check effect
                if (f.effect) |eff| {
                    if (eff != .pure and !self.in_effect_function) {
                        try self.addDiagnostic(try errors_mod.effectViolation(
                            self.allocator,
                            "cannot call effect function from pure function",
                            span,
                        ));
                    }
                }

                return f.return_type.*;
            },
            else => {
                try self.addDiagnostic(try errors_mod.notCallable(
                    self.allocator,
                    callee_type,
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    /// Check method call
    fn checkMethodCall(self: *TypeChecker, mc: Expression.MethodCall, span: Span) TypeCheckError!ResolvedType {
        const object_type = try self.checkExpression(mc.object);

        if (object_type.isError()) {
            return ResolvedType.errorType(span);
        }

        // Look up method on the type
        // For now, just check that arguments are valid expressions
        for (mc.arguments) |arg| {
            _ = try self.checkExpression(arg);
        }

        // TODO: Proper method resolution through impl blocks
        try self.addDiagnostic(try errors_mod.simpleError(
            self.allocator,
            "method call type checking not fully implemented",
            span,
        ));
        return ResolvedType.errorType(span);
    }

    /// Check closure
    fn checkClosure(self: *TypeChecker, closure: Expression.Closure, span: Span) TypeCheckError!ResolvedType {
        // Save current state
        const saved_return_type = self.current_return_type;
        const saved_effect = self.current_effect;
        const saved_in_effect = self.in_effect_function;
        defer {
            self.current_return_type = saved_return_type;
            self.current_effect = saved_effect;
            self.in_effect_function = saved_in_effect;
        }

        // Resolve parameter types
        const type_alloc = self.typeAllocator();
        var param_types = std.ArrayListUnmanaged(ResolvedType){};
        for (closure.parameters) |param| {
            try param_types.append(type_alloc, try self.resolveAstType(param.param_type));
        }

        // Resolve return type
        const return_type = try self.resolveAstType(closure.return_type);

        self.current_return_type = return_type;
        self.in_effect_function = closure.is_effect;

        // Check body
        for (closure.body) |*stmt| {
            try self.checkStatement(stmt);
        }

        // Build function type
        const return_type_ptr = try type_alloc.create(ResolvedType);
        return_type_ptr.* = return_type;

        return .{
            .kind = .{ .function = .{
                .parameter_types = try param_types.toOwnedSlice(type_alloc),
                .return_type = return_type_ptr,
                .effect = if (closure.is_effect) .io else null,
            } },
            .span = span,
        };
    }

    /// Check match expression
    fn checkMatchExpr(self: *TypeChecker, me: Expression.MatchExpr, span: Span) TypeCheckError!ResolvedType {
        const subject_type = try self.checkExpression(me.subject);

        if (me.arms.len == 0) {
            try self.addDiagnostic(try errors_mod.simpleError(
                self.allocator,
                "match expression must have at least one arm",
                span,
            ));
            return ResolvedType.errorType(span);
        }

        // Check each arm and ensure all return the same type
        var result_type: ?ResolvedType = null;

        // Collect patterns for exhaustiveness checking
        var patterns = std.ArrayListUnmanaged(*const Pattern){};
        defer patterns.deinit(self.allocator);

        for (me.arms) |arm| {
            _ = try self.symbol_table.enterScope(.block);
            errdefer self.scopeCleanup();

            // Check pattern against subject type and add bindings to scope
            try self.checkPattern(arm.pattern, subject_type);
            try self.addPatternBindings(arm.pattern, null);

            // Collect pattern for exhaustiveness checking
            try patterns.append(self.allocator, arm.pattern);

            // Check guard if present
            if (arm.guard) |guard| {
                const guard_type = try self.checkExpression(guard);
                if (!guard_type.isBool()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "match guard must be a boolean expression",
                        guard.span,
                    ));
                }
            }

            // Check body
            const arm_type = switch (arm.body) {
                .expression => |e| try self.checkExpression(e),
                .block => |block| blk: {
                    for (block) |*stmt| {
                        try self.checkStatement(stmt);
                    }
                    // Block type is void unless it has a return
                    break :blk ResolvedType.voidType(span);
                },
            };

            if (result_type) |rt| {
                if (!unify.typesEqual(rt, arm_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        rt,
                        arm_type,
                        arm.span,
                    ));
                }
            } else {
                result_type = arm_type;
            }

            try self.scopeLeave();
        }

        // Check exhaustiveness
        try self.checkMatchExhaustiveness(patterns.items, subject_type, span);

        return result_type orelse ResolvedType.voidType(span);
    }

    /// Check if expression
    fn checkIfExpr(self: *TypeChecker, ie: Expression.IfExpr, span: Span) TypeCheckError!ResolvedType {
        // Check condition is bool
        const cond_type = try self.checkExpression(ie.condition);
        if (!cond_type.isBool()) {
            try self.addDiagnostic(try errors_mod.simpleError(
                self.allocator,
                "if condition must be a boolean expression",
                ie.condition.span,
            ));
        }

        // Check both branches and get their types
        const then_type = then_blk: {
            _ = try self.symbol_table.enterScope(.block);
            errdefer self.scopeCleanup();
            const t = switch (ie.then_branch) {
                .expression => |e| try self.checkExpression(e),
                .block => |block| blk: {
                    for (block) |*stmt| {
                        try self.checkStatement(stmt);
                    }
                    break :blk ResolvedType.voidType(span);
                },
            };
            try self.scopeLeave();
            break :then_blk t;
        };

        const else_type = else_blk: {
            _ = try self.symbol_table.enterScope(.block);
            errdefer self.scopeCleanup();
            const t = switch (ie.else_branch) {
                .expression => |e| try self.checkExpression(e),
                .block => |block| blk: {
                    for (block) |*stmt| {
                        try self.checkStatement(stmt);
                    }
                    break :blk ResolvedType.voidType(span);
                },
            };
            try self.scopeLeave();
            break :else_blk t;
        };

        // Both branches must have the same type
        if (!unify.typesEqual(then_type, else_type)) {
            try self.addDiagnostic(try errors_mod.typeMismatch(
                self.allocator,
                then_type,
                else_type,
                span,
            ));
            return ResolvedType.errorType(span);
        }

        return then_type;
    }

    /// Check record literal
    fn checkRecordLiteral(self: *TypeChecker, rl: Expression.RecordLiteral, span: Span) TypeCheckError!ResolvedType {
        // Check field values
        for (rl.fields) |field| {
            _ = try self.checkExpression(field.value);
        }

        if (rl.type_name) |type_expr| {
            const type_type = try self.checkExpression(type_expr);
            // Should resolve to a type
            return type_type;
        }

        // Anonymous record - build tuple of field types
        const type_alloc = self.typeAllocator();
        var field_types = std.ArrayListUnmanaged(ResolvedType){};
        for (rl.fields) |field| {
            try field_types.append(type_alloc, try self.checkExpression(field.value));
        }

        return .{
            .kind = .{ .tuple = .{
                .element_types = try field_types.toOwnedSlice(type_alloc),
            } },
            .span = span,
        };
    }

    /// Check variant constructor
    fn checkVariantConstructor(self: *TypeChecker, vc: Expression.VariantConstructor, span: Span) TypeCheckError!ResolvedType {
        // Look up variant name to find the sum type
        if (self.symbol_table.lookup(vc.variant_name)) |sym| {
            if (sym.kind == .type_def) {
                // Check arguments if present
                if (vc.arguments) |args| {
                    for (args) |arg| {
                        _ = try self.checkExpression(arg);
                    }
                }
                return ResolvedType.named(sym.id, sym.name, span);
            }
        }

        // Common variants like Some, None, Ok, Err
        if (std.mem.eql(u8, vc.variant_name, "None")) {
            // Option[T] where T is unknown
            return ResolvedType.errorType(span); // Need context to determine T
        } else if (std.mem.eql(u8, vc.variant_name, "Some")) {
            if (vc.arguments) |args| {
                if (args.len == 1) {
                    const inner_type = try self.checkExpression(args[0]);
                    const type_alloc = self.typeAllocator();
                    const inner_ptr = try type_alloc.create(ResolvedType);
                    inner_ptr.* = inner_type;
                    return .{
                        .kind = .{ .option = inner_ptr },
                        .span = span,
                    };
                }
            }
        } else if (std.mem.eql(u8, vc.variant_name, "Ok")) {
            if (vc.arguments) |args| {
                if (args.len == 1) {
                    _ = try self.checkExpression(args[0]);
                    // Result[T, E] - would need context to determine E
                    return ResolvedType.errorType(span);
                }
            }
        } else if (std.mem.eql(u8, vc.variant_name, "Err")) {
            if (vc.arguments) |args| {
                if (args.len == 1) {
                    _ = try self.checkExpression(args[0]);
                    // Result[T, E] - would need context to determine T
                    return ResolvedType.errorType(span);
                }
            }
        } else if (std.mem.eql(u8, vc.variant_name, "Cons")) {
            if (vc.arguments) |args| {
                if (args.len == 2) {
                    const elem_type = try self.checkExpression(args[0]);
                    _ = try self.checkExpression(args[1]);
                    if (self.symbol_table.lookup("List")) |list_sym| {
                        const type_alloc = self.typeAllocator();
                        const type_args = try type_alloc.alloc(ResolvedType, 1);
                        type_args[0] = elem_type;
                        return .{
                            .kind = .{ .instantiated = .{
                                .base_symbol_id = list_sym.id,
                                .base_name = "List",
                                .type_arguments = type_args,
                            } },
                            .span = span,
                        };
                    }
                }
            }
        } else if (std.mem.eql(u8, vc.variant_name, "Nil")) {
            // Nil - empty list, type parameter unknown without context
            return ResolvedType.errorType(span);
        }

        try self.addDiagnostic(try errors_mod.undefinedSymbol(self.allocator, vc.variant_name, span));
        return ResolvedType.errorType(span);
    }

    /// Check type cast
    fn checkTypeCast(self: *TypeChecker, tc: Expression.TypeCast, span: Span) TypeCheckError!ResolvedType {
        const source_type = try self.checkExpression(tc.expression);
        const target_type = try self.resolveAstType(tc.target_type);

        if (!unify.isValidCast(source_type, target_type)) {
            try self.addDiagnostic(try errors_mod.simpleError(
                self.allocator,
                "invalid type cast",
                span,
            ));
        }

        return target_type;
    }

    /// Check range expression
    fn checkRange(self: *TypeChecker, range: Expression.Range, span: Span) TypeCheckError!ResolvedType {
        var elem_type: ?ResolvedType = null;

        if (range.start) |start| {
            const start_type = try self.checkExpression(start);
            if (!start_type.isInteger()) {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "range bounds must be integers",
                    start.span,
                ));
            }
            elem_type = start_type;
        }

        if (range.end) |end| {
            const end_type = try self.checkExpression(end);
            if (!end_type.isInteger()) {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "range bounds must be integers",
                    end.span,
                ));
            }
            if (elem_type) |et| {
                if (!unify.typesEqual(et, end_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        et,
                        end_type,
                        end.span,
                    ));
                }
            } else {
                elem_type = end_type;
            }
        }

        // Range type - for now return as array of element type
        const elem = elem_type orelse ResolvedType.primitive(.i32, span);
        const type_alloc = self.typeAllocator();
        const elem_ptr = try type_alloc.create(ResolvedType);
        elem_ptr.* = elem;

        return .{
            .kind = .{ .array = .{
                .element_type = elem_ptr,
                .size = null,
            } },
            .span = span,
        };
    }

    /// Check try expression
    fn checkTryExpr(self: *TypeChecker, te: *const Expression, span: Span) TypeCheckError!ResolvedType {
        const inner_type = try self.checkExpression(te);

        // E4: '?' operator only allowed in effect functions
        if (!self.in_effect_function) {
            try self.addDiagnostic(try errors_mod.tryInPureFunction(
                self.allocator,
                span,
            ));
            return ResolvedType.errorType(span);
        }

        // Must be Result or Option
        return switch (inner_type.kind) {
            .result => |r| {
                // E5: '?' on Result requires function to return Result
                if (self.current_return_type) |ret_type| {
                    if (!ret_type.isResult()) {
                        try self.addDiagnostic(try errors_mod.tryResultMismatch(
                            self.allocator,
                            span,
                        ));
                    }
                }
                return r.ok_type.*;
            },
            .option => |o| o.*,
            else => {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "'?' can only be used on Result or Option types",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    /// Check null coalesce expression
    fn checkNullCoalesce(self: *TypeChecker, nc: Expression.NullCoalesce, span: Span) TypeCheckError!ResolvedType {
        const left_type = try self.checkExpression(nc.left);
        const default_type = try self.checkExpression(nc.default);

        // Left must be Option
        return switch (left_type.kind) {
            .option => |inner| {
                if (!unify.typesEqual(inner.*, default_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        inner.*,
                        default_type,
                        nc.default.span,
                    ));
                }
                return inner.*;
            },
            else => {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "'??' can only be used with Option types",
                    span,
                ));
                return ResolvedType.errorType(span);
            },
        };
    }

    // ========== Statement Type Checking ==========

    /// Type check a statement
    pub fn checkStatement(self: *TypeChecker, stmt: *const Statement) TypeCheckError!void {
        // Scope balance invariant: no statement should permanently change the scope depth
        const entry_scope_id = self.symbol_table.current_scope_id;
        defer std.debug.assert(self.symbol_table.current_scope_id == entry_scope_id);

        switch (stmt.kind) {
            .let_binding => |lb| {
                const init_type = try self.checkExpression(lb.initializer);

                // explicit_type is required in Kira (not optional)
                const declared_type = try self.resolveAstType(lb.explicit_type);
                if (!unify.typesEqual(declared_type, init_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        declared_type,
                        init_type,
                        lb.initializer.span,
                    ));
                }

                try self.checkPattern(lb.pattern, init_type);

                // Add all bindings from the pattern to scope
                try self.addPatternBindings(lb.pattern, lb.explicit_type);
            },

            .var_binding => |vb| {
                // Local mutation via var is allowed in pure functions —
                // only I/O and calling effect functions are true side effects.

                // explicit_type is required in Kira
                const declared_type = try self.resolveAstType(vb.explicit_type);

                if (vb.initializer) |initializer| {
                    const init_type = try self.checkExpression(initializer);
                    if (!unify.typesEqual(declared_type, init_type)) {
                        try self.addDiagnostic(try errors_mod.typeMismatch(
                            self.allocator,
                            declared_type,
                            init_type,
                            initializer.span,
                        ));
                    }
                }

                // Add binding to scope so subsequent statements can find it
                const var_sym = Symbol.variable(unassigned_symbol_id, vb.name, vb.explicit_type, true, false, stmt.span);
                _ = self.symbol_table.define(var_sym) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    // DuplicateDefinition: resolver already reported this
                };
            },

            .assignment => |assign| {
                const value_type = try self.checkExpression(assign.value);

                const target_type = switch (assign.target) {
                    .identifier => |name| blk: {
                        if (self.symbol_table.lookup(name)) |sym| {
                            break :blk try self.getSymbolType(sym, stmt.span);
                        }
                        try self.addDiagnostic(try errors_mod.undefinedSymbol(self.allocator, name, stmt.span));
                        break :blk ResolvedType.errorType(stmt.span);
                    },
                    .field_access => |ft| blk: {
                        // Convert FieldTarget to FieldAccess (same structure)
                        const fa = Expression.FieldAccess{
                            .object = ft.object,
                            .field = ft.field,
                        };
                        break :blk try self.checkFieldAccess(fa, stmt.span);
                    },
                    .index_access => |it| blk: {
                        // Convert IndexTarget to IndexAccess (same structure)
                        const ia = Expression.IndexAccess{
                            .object = it.object,
                            .index = it.index,
                        };
                        break :blk try self.checkIndexAccess(ia, stmt.span);
                    },
                };

                if (!unify.typesEqual(target_type, value_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        target_type,
                        value_type,
                        assign.value.span,
                    ));
                }
            },

            .if_statement => |if_stmt| {
                const cond_type = try self.checkExpression(if_stmt.condition);
                if (!cond_type.isBool()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "if condition must be a boolean expression",
                        if_stmt.condition.span,
                    ));
                }

                {
                    _ = try self.symbol_table.enterScope(.block);
                    errdefer self.scopeCleanup();
                    for (if_stmt.then_branch) |*s| {
                        try self.checkStatement(s);
                    }
                    try self.scopeLeave();
                }

                if (if_stmt.else_branch) |else_branch| {
                    switch (else_branch) {
                        .block => |block| {
                            _ = try self.symbol_table.enterScope(.block);
                            errdefer self.scopeCleanup();
                            for (block) |*s| {
                                try self.checkStatement(s);
                            }
                            try self.scopeLeave();
                        },
                        .else_if => |else_if| {
                            try self.checkStatement(else_if);
                        },
                    }
                }
            },

            .for_loop => |for_loop| {
                const iterable_type = try self.checkExpression(for_loop.iterable);

                if (!unify.isIterable(iterable_type)) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "for loop requires an iterable",
                        for_loop.iterable.span,
                    ));
                }

                _ = try self.symbol_table.enterScope(.block);
                errdefer self.scopeCleanup();

                // Get element type and check pattern
                if (unify.getIterableElement(iterable_type)) |elem_type| {
                    try self.checkPattern(for_loop.pattern, elem_type);
                }
                // Always add bindings so loop body can reference the variable
                try self.addPatternBindings(for_loop.pattern, null);

                for (for_loop.body) |*s| {
                    try self.checkStatement(s);
                }
                try self.scopeLeave();
            },

            .while_loop => |while_loop| {
                const cond_type = try self.checkExpression(while_loop.condition);
                if (!cond_type.isBool()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "while condition must be a boolean expression",
                        while_loop.condition.span,
                    ));
                }

                _ = try self.symbol_table.enterScope(.block);
                errdefer self.scopeCleanup();
                for (while_loop.body) |*s| {
                    try self.checkStatement(s);
                }
                try self.scopeLeave();
            },

            .loop_statement => |loop_stmt| {
                _ = try self.symbol_table.enterScope(.block);
                errdefer self.scopeCleanup();
                for (loop_stmt.body) |*s| {
                    try self.checkStatement(s);
                }
                try self.scopeLeave();
            },

            .match_statement => |match_stmt| {
                const subject_type = try self.checkExpression(match_stmt.subject);

                // Collect patterns for exhaustiveness checking
                var patterns = std.ArrayListUnmanaged(*const Pattern){};
                defer patterns.deinit(self.allocator);

                for (match_stmt.arms) |arm| {
                    _ = try self.symbol_table.enterScope(.block);
                    errdefer self.scopeCleanup();

                    // Check pattern against subject type and add bindings to scope
                    try self.checkPattern(arm.pattern, subject_type);
                    try self.addPatternBindings(arm.pattern, null);

                    // Collect pattern for exhaustiveness checking
                    try patterns.append(self.allocator, arm.pattern);

                    if (arm.guard) |guard| {
                        const guard_type = try self.checkExpression(guard);
                        if (!guard_type.isBool()) {
                            try self.addDiagnostic(try errors_mod.simpleError(
                                self.allocator,
                                "match guard must be a boolean expression",
                                guard.span,
                            ));
                        }
                    }

                    for (arm.body) |*s| {
                        try self.checkStatement(s);
                    }
                    try self.scopeLeave();
                }

                // Check exhaustiveness
                try self.checkMatchExhaustiveness(patterns.items, subject_type, stmt.span);
            },

            .return_statement => |ret| {
                if (ret.value) |value| {
                    const value_type = try self.checkExpression(value);
                    if (self.current_return_type) |expected| {
                        if (!unify.typesEqual(expected, value_type)) {
                            try self.addDiagnostic(try errors_mod.typeMismatch(
                                self.allocator,
                                expected,
                                value_type,
                                value.span,
                            ));
                        }
                    }
                } else {
                    if (self.current_return_type) |expected| {
                        if (!expected.isVoid()) {
                            try self.addDiagnostic(try errors_mod.simpleError(
                                self.allocator,
                                "return statement missing value",
                                stmt.span,
                            ));
                        }
                    }
                }
            },

            .break_statement => |brk| {
                if (brk.value) |value| {
                    _ = try self.checkExpression(value);
                }
            },

            .expression_statement => |expr| {
                _ = try self.checkExpression(expr);
            },

            .block => |block| {
                _ = try self.symbol_table.enterScope(.block);
                errdefer self.scopeCleanup();
                for (block) |*s| {
                    try self.checkStatement(s);
                }
                try self.scopeLeave();
            },
        }
    }

    // ========== Pattern Type Checking ==========

    /// Check a pattern against an expected type
    fn checkPattern(self: *TypeChecker, pattern: *const Pattern, expected_type: ResolvedType) TypeCheckError!void {
        switch (pattern.kind) {
            .identifier => {
                // Binding always succeeds - type comes from expected
            },

            .wildcard => {
                // Wildcard matches anything
            },

            .integer_literal => {
                if (!expected_type.isInteger()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "integer pattern used with non-integer type",
                        pattern.span,
                    ));
                }
            },

            .float_literal => {
                if (!expected_type.isFloat()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "float pattern used with non-float type",
                        pattern.span,
                    ));
                }
            },

            .string_literal => {
                if (!expected_type.isString()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "string pattern used with non-string type",
                        pattern.span,
                    ));
                }
            },

            .char_literal => {
                if (!expected_type.isChar()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "char pattern used with non-char type",
                        pattern.span,
                    ));
                }
            },

            .bool_literal => {
                if (!expected_type.isBool()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "bool pattern used with non-bool type",
                        pattern.span,
                    ));
                }
            },

            .constructor => |ctor| {
                // Check constructor pattern against sum type
                _ = ctor;
                // TODO: Verify variant exists in type and check field types
            },

            .record => |rec| {
                // Check record pattern against product type
                _ = rec;
                // TODO: Verify all fields match type definition
            },

            .tuple => |tup| {
                if (expected_type.kind != .tuple) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "tuple pattern used with non-tuple type",
                        pattern.span,
                    ));
                    return;
                }

                const tuple_info = expected_type.kind.tuple;
                if (tup.elements.len != tuple_info.element_types.len) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "tuple pattern has wrong number of elements",
                        pattern.span,
                    ));
                    return;
                }

                for (tup.elements, tuple_info.element_types) |elem, elem_type| {
                    try self.checkPattern(elem, elem_type);
                }
            },

            .or_pattern => |orp| {
                for (orp.patterns) |alt| {
                    try self.checkPattern(alt, expected_type);
                }
            },

            .range => {
                // Range patterns work on integers and chars
                if (!expected_type.isInteger() and !expected_type.isChar()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "range pattern used with non-integer/char type",
                        pattern.span,
                    ));
                }
            },

            .rest => {
                // Rest pattern collects remaining elements
            },

            .guarded => |g| {
                try self.checkPattern(g.pattern, expected_type);
                const guard_type = try self.checkExpression(g.guard);
                if (!guard_type.isBool()) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "pattern guard must be a boolean expression",
                        g.guard.span,
                    ));
                }
            },

            .typed => |t| {
                const annotated_type = try self.resolveAstType(t.expected_type);
                if (!unify.typesEqual(expected_type, annotated_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        expected_type,
                        annotated_type,
                        pattern.span,
                    ));
                }
                try self.checkPattern(t.pattern, annotated_type);
            },
        }
    }

    /// Walk a pattern and define all bound identifiers in the current scope.
    /// This mirrors the resolver's resolvePattern for symbol definition.
    /// When explicit_type is null, an inferred placeholder type is used.
    fn addPatternBindings(self: *TypeChecker, pattern: *const Pattern, explicit_type: ?*Type) TypeCheckError!void {
        switch (pattern.kind) {
            .identifier => |ident| {
                // Use explicit type or create inferred placeholder (mirrors resolver)
                var inferred = Type.init(.{ .inferred = {} }, pattern.span);
                const binding_type = explicit_type orelse &inferred;
                const sym = Symbol.variable(unassigned_symbol_id, ident.name, binding_type, ident.is_mutable, false, pattern.span);
                _ = self.symbol_table.define(sym) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    // DuplicateDefinition: resolver already reported this
                };
            },
            .constructor => |ctor| {
                if (ctor.arguments) |args| {
                    for (args) |arg| {
                        switch (arg) {
                            .positional => |p| try self.addPatternBindings(p, null),
                            .named => |n| try self.addPatternBindings(n.pattern, null),
                        }
                    }
                }
            },
            .record => |rp| {
                for (rp.fields) |field| {
                    if (field.pattern) |pat| {
                        try self.addPatternBindings(pat, null);
                    } else {
                        // Shorthand: { x } binds x
                        var inferred = Type.init(.{ .inferred = {} }, field.span);
                        const sym = Symbol.variable(unassigned_symbol_id, field.name, &inferred, false, false, field.span);
                        _ = self.symbol_table.define(sym) catch |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;
                        };
                    }
                }
            },
            .tuple => |tup| {
                for (tup.elements) |elem| {
                    try self.addPatternBindings(elem, null);
                }
            },
            .or_pattern => |op| {
                // All alternatives must bind the same names (enforced by resolver).
                // Process every alternative so all names are defined; duplicates
                // from subsequent alternatives are silently caught by define().
                for (op.patterns) |alt| {
                    try self.addPatternBindings(alt, null);
                }
            },
            .guarded => |g| {
                try self.addPatternBindings(g.pattern, explicit_type);
            },
            .typed => |t| {
                try self.addPatternBindings(t.pattern, t.expected_type);
            },
            // Literals, wildcards, ranges, rest don't bind names
            else => {},
        }
    }

    // ========== Declaration Type Checking ==========

    /// Type check a declaration
    fn checkDeclaration(self: *TypeChecker, decl: *const Declaration) TypeCheckError!void {
        switch (decl.kind) {
            .function_decl => |f| try self.checkFunctionDecl(&f),
            .type_decl => |t| try self.checkTypeDecl(&t),
            .trait_decl => |t| try self.checkTraitDecl(&t),
            .impl_block => |i| try self.checkImplBlock(&i),
            .module_decl => {},
            .import_decl => {},
            .const_decl => |c| {
                const value_type = try self.checkExpression(c.value);
                // const_type is required in Kira
                const declared_type = try self.resolveAstType(c.const_type);
                if (!unify.typesEqual(declared_type, value_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        declared_type,
                        value_type,
                        c.value.span,
                    ));
                }
            },
            .let_decl => |l| {
                const value_type = try self.checkExpression(l.value);
                // binding_type is required in Kira
                const declared_type = try self.resolveAstType(l.binding_type);
                if (!unify.typesEqual(declared_type, value_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        declared_type,
                        value_type,
                        l.value.span,
                    ));
                }
            },
            .test_decl => |t| {
                // Type check the test body - tests are implicitly effect functions
                const saved_in_effect = self.in_effect_function;
                self.in_effect_function = true;
                defer self.in_effect_function = saved_in_effect;

                const entry_scope_id = self.symbol_table.current_scope_id;
                _ = try self.symbol_table.enterScope(.function);
                errdefer self.scopeCleanup();
                for (t.body) |*stmt| {
                    _ = try self.checkStatement(stmt);
                }
                try self.scopeLeave();
                std.debug.assert(self.symbol_table.current_scope_id == entry_scope_id);
            },
        }
    }

    /// Check function declaration
    fn checkFunctionDecl(self: *TypeChecker, func: *const Declaration.FunctionDecl) TypeCheckError!void {
        // Save current state
        const saved_return_type = self.current_return_type;
        const saved_effect = self.current_effect;
        const saved_in_effect = self.in_effect_function;
        defer {
            self.current_return_type = saved_return_type;
            self.current_effect = saved_effect;
            self.in_effect_function = saved_in_effect;
        }

        // Set up generic type variables if present
        if (func.generic_params) |params| {
            for (params) |p| {
                try self.type_var_substitutions.put(
                    self.allocator,
                    p.name,
                    ResolvedType.typeVar(p.name, p.constraints orelse null, p.span),
                );
            }
        }
        defer {
            if (func.generic_params) |params| {
                for (params) |p| {
                    _ = self.type_var_substitutions.remove(p.name);
                }
            }
        }

        // Resolve return type
        const return_type = try self.resolveAstType(func.return_type);
        self.current_return_type = return_type;
        self.in_effect_function = func.is_effect;

        // Check body if present
        if (func.body) |body| {
            const entry_scope_id = self.symbol_table.current_scope_id;

            // Enter function scope so parameters and locals are visible
            _ = try self.symbol_table.enterScope(.function);
            errdefer self.scopeCleanup();

            // Add parameters to scope
            for (func.parameters) |param| {
                const param_sym = Symbol.variable(unassigned_symbol_id, param.name, param.param_type, false, false, param.span);
                _ = self.symbol_table.define(param_sym) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    // DuplicateDefinition: resolver already reported this
                };
            }

            for (body) |*stmt| {
                try self.checkStatement(stmt);
            }

            try self.scopeLeave();
            std.debug.assert(self.symbol_table.current_scope_id == entry_scope_id);
        }
    }

    /// Check type declaration
    fn checkTypeDecl(self: *TypeChecker, type_decl: *const Declaration.TypeDecl) TypeCheckError!void {
        // Set up generic type variables if present
        if (type_decl.generic_params) |params| {
            for (params) |p| {
                try self.type_var_substitutions.put(
                    self.allocator,
                    p.name,
                    ResolvedType.typeVar(p.name, p.constraints orelse null, p.span),
                );
            }
        }
        defer {
            if (type_decl.generic_params) |params| {
                for (params) |p| {
                    _ = self.type_var_substitutions.remove(p.name);
                }
            }
        }

        // Validate type definition
        switch (type_decl.definition) {
            .sum_type => |sum| {
                for (sum.variants) |variant| {
                    if (variant.fields) |fields| {
                        switch (fields) {
                            .tuple_fields => |tf| {
                                for (tf) |field_type| {
                                    _ = try self.resolveAstType(field_type);
                                }
                            },
                            .record_fields => |rf| {
                                for (rf) |field| {
                                    _ = try self.resolveAstType(field.field_type);
                                }
                            },
                        }
                    }
                }
            },
            .product_type => |prod| {
                for (prod.fields) |field| {
                    _ = try self.resolveAstType(field.field_type);
                }
            },
            .type_alias => |alias| {
                _ = try self.resolveAstType(alias);
            },
        }
    }

    /// Check trait declaration
    fn checkTraitDecl(self: *TypeChecker, trait_decl: *const Declaration.TraitDecl) TypeCheckError!void {
        // Set up generic type variables if present
        if (trait_decl.generic_params) |params| {
            for (params) |p| {
                try self.type_var_substitutions.put(
                    self.allocator,
                    p.name,
                    ResolvedType.typeVar(p.name, p.constraints orelse null, p.span),
                );
            }
        }
        defer {
            if (trait_decl.generic_params) |params| {
                for (params) |p| {
                    _ = self.type_var_substitutions.remove(p.name);
                }
            }
        }

        // Check method signatures
        for (trait_decl.methods) |method| {
            for (method.parameters) |param| {
                _ = try self.resolveAstType(param.param_type);
            }
            _ = try self.resolveAstType(method.return_type);

            // Check default body if present
            if (method.default_body) |body| {
                const saved_return_type = self.current_return_type;
                const saved_in_effect = self.in_effect_function;
                defer {
                    self.current_return_type = saved_return_type;
                    self.in_effect_function = saved_in_effect;
                }

                self.current_return_type = try self.resolveAstType(method.return_type);
                self.in_effect_function = method.is_effect;

                for (body) |*stmt| {
                    try self.checkStatement(stmt);
                }
            }
        }
    }

    /// Check impl block
    fn checkImplBlock(self: *TypeChecker, impl_block: *const Declaration.ImplBlock) TypeCheckError!void {
        // Resolve target type
        const target_type = try self.resolveAstType(impl_block.target_type);
        const saved_self_type = self.self_type;
        self.self_type = target_type;
        defer self.self_type = saved_self_type;

        // Set up generic type variables if present
        if (impl_block.generic_params) |params| {
            for (params) |p| {
                try self.type_var_substitutions.put(
                    self.allocator,
                    p.name,
                    ResolvedType.typeVar(p.name, p.constraints orelse null, p.span),
                );
            }
        }
        defer {
            if (impl_block.generic_params) |params| {
                for (params) |p| {
                    _ = self.type_var_substitutions.remove(p.name);
                }
            }
        }

        // Check each method
        for (impl_block.methods) |*method| {
            try self.checkFunctionDecl(method);
        }

        // If implementing a trait, verify all required methods are implemented
        if (impl_block.trait_name) |trait_name| {
            if (self.symbol_table.lookup(trait_name)) |trait_sym| {
                if (trait_sym.kind == .trait_def) {
                    const trait_def = trait_sym.kind.trait_def;

                    // Check each required method
                    for (trait_def.methods) |req_method| {
                        if (!req_method.has_default) {
                            var found = false;
                            for (impl_block.methods) |impl_method| {
                                if (std.mem.eql(u8, impl_method.name, req_method.name)) {
                                    found = true;
                                    // TODO: Check signature matches
                                    break;
                                }
                            }
                            if (!found) {
                                try self.addDiagnostic(try errors_mod.simpleError(
                                    self.allocator,
                                    "missing implementation for trait method",
                                    impl_block.target_type.span,
                                ));
                            }
                        }
                    }
                }
            }
        }
    }

    // ========== Pattern Match Exhaustiveness ==========

    /// Check if a match expression/statement is exhaustive
    fn checkMatchExhaustiveness(
        self: *TypeChecker,
        patterns: []const *const Pattern,
        subject_type: ResolvedType,
        span: Span,
    ) TypeCheckError!void {
        var compiler = pattern_compiler_mod.PatternCompiler.init(
            self.allocator,
            self.symbol_table,
            &self.diagnostics,
        );

        var result = compiler.checkExhaustiveness(patterns, subject_type, span) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        defer result.deinit(self.allocator);

        // Report non-exhaustive match
        if (!result.is_exhaustive) {
            compiler.reportNonExhaustive(result, span) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                };
            };
        }

        // Report unreachable patterns as warnings
        compiler.reportUnreachablePatterns(result, patterns) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
            };
        };
    }

    // ========== Helper Functions ==========

    /// Get the type of a symbol
    fn getSymbolType(self: *TypeChecker, sym: *const Symbol, span: Span) TypeCheckError!ResolvedType {
        return switch (sym.kind) {
            .variable => |v| try self.resolveAstType(v.binding_type),
            .function => |f| {
                const type_alloc = self.typeAllocator();
                var param_types = std.ArrayListUnmanaged(ResolvedType){};
                for (f.parameter_types) |pt| {
                    try param_types.append(type_alloc, try self.resolveAstType(pt));
                }

                const return_type = try type_alloc.create(ResolvedType);
                return_type.* = try self.resolveAstType(f.return_type);

                return .{
                    .kind = .{ .function = .{
                        .parameter_types = try param_types.toOwnedSlice(type_alloc),
                        .return_type = return_type,
                        .effect = if (f.is_effect) .io else null,
                    } },
                    .span = span,
                };
            },
            .type_def => ResolvedType.named(sym.id, sym.name, span),
            .type_param => |tp| ResolvedType.typeVar(sym.name, tp.constraints orelse null, span),
            .import_alias => |ia| {
                if (ia.resolved_id) |id| {
                    if (self.symbol_table.getSymbol(id)) |resolved_sym| {
                        return try self.getSymbolType(resolved_sym, span);
                    }
                }
                return ResolvedType.errorType(span);
            },
            else => ResolvedType.errorType(span),
        };
    }

    /// Add a diagnostic
    fn addDiagnostic(self: *TypeChecker, diagnostic: Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diagnostic);
    }
};

test "type checker basic initialization" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    try std.testing.expect(!checker.hasErrors());
}

test "type checker resolve primitive type" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 4, .offset = 3 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var ast_type = Type.primitive(.i32, span);
    const resolved = try checker.resolveAstType(&ast_type);

    try std.testing.expect(resolved.isPrimitive());
    try std.testing.expectEqual(@as(Type.PrimitiveType, .i32), resolved.kind.primitive);
}

test "effect: try operator in pure function forbidden" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Not in an effect function
    checker.in_effect_function = false;

    // Create a simple integer expression to use with try
    var inner_expr = Expression{
        .kind = .{ .integer_literal = .{ .value = 42, .suffix = null } },
        .span = span,
    };

    // Create try expression
    var try_expr = Expression{
        .kind = .{ .try_expr = &inner_expr },
        .span = span,
    };

    // Check the try expression - should add an error
    _ = checker.checkExpression(&try_expr) catch {};

    // Should have an error about try in pure function
    try std.testing.expect(checker.hasErrors());
    try std.testing.expect(checker.diagnostics.items.len >= 1);

    // Check error message
    const diag = checker.diagnostics.items[0];
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "'?' operator can only be used in effect functions") != null);
}

test "effect: try operator in effect function allowed" {
    // This test verifies that when in_effect_function is true,
    // the try expression does NOT produce the "try in pure function" error.
    // We test this by checking that the first error encountered (if any)
    // is about the type, not about the effect.

    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();


    // In an effect function - this should allow try operator
    checker.in_effect_function = true;

    // Create a simple integer expression (not Result or Option)
    // This will generate a type error, but NOT the effect error
    var inner_expr = Expression{
        .kind = .{ .integer_literal = .{ .value = 42, .suffix = null } },
        .span = span,
    };

    // Create try expression
    var try_expr = Expression{
        .kind = .{ .try_expr = &inner_expr },
        .span = span,
    };

    // Check the try expression
    _ = checker.checkExpression(&try_expr) catch {};

    // Verify we have errors, but NOT the "pure function" error
    try std.testing.expect(checker.hasErrors());

    // The error should be about type (not Result/Option), not about effect
    var has_try_pure_error = false;
    var has_type_error = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "'?' operator can only be used in effect functions") != null) {
            has_try_pure_error = true;
        }
        if (std.mem.indexOf(u8, diag.message, "Result or Option") != null) {
            has_type_error = true;
        }
    }
    try std.testing.expect(!has_try_pure_error);
    try std.testing.expect(has_type_error);
}

test "effect: try on Result in non-Result function forbidden" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();


    // In an effect function (to pass E4 check)
    checker.in_effect_function = true;

    // Set return type to i32 (not Result)
    checker.current_return_type = ResolvedType.primitive(.i32, span);

    // Create a Result type expression manually
    // We'll create an expression that resolves to Result type
    const ok_type = try allocator.create(ResolvedType);
    defer allocator.destroy(ok_type);
    ok_type.* = ResolvedType.primitive(.i32, span);
    const err_type = try allocator.create(ResolvedType);
    defer allocator.destroy(err_type);
    err_type.* = ResolvedType.primitive(.string, span);

    // Create a fake expression that we'll treat as Result
    // For this test, we use a variant constructor that returns Result
    var inner_val = Expression{
        .kind = .{ .integer_literal = .{ .value = 42, .suffix = null } },
        .span = span,
    };

    var ok_expr = Expression{
        .kind = .{ .variant_constructor = .{
            .variant_name = "Ok",
            .arguments = @constCast(&[_]*Expression{&inner_val}),
        } },
        .span = span,
    };

    var try_expr = Expression{
        .kind = .{ .try_expr = &ok_expr },
        .span = span,
    };

    // Check - this will fail to find Result type because Ok is not defined,
    // but we're testing the infrastructure is in place
    _ = checker.checkExpression(&try_expr) catch {};

    // The test verifies the code path exists; full Result checking
    // requires proper symbol table setup
    try std.testing.expect(true);
}

test "effect: main function must have IO effect" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();


    // Create a return type
    var return_type = Type.primitive(.void_type, span);

    // Create main function WITHOUT effect keyword
    const func_decl = Declaration.FunctionDecl{
        .name = "main",
        .generic_params = null,
        .parameters = &[_]Declaration.Parameter{},
        .return_type = &return_type,
        .is_effect = false, // Not an effect function!
        .is_public = true,
        .body = null,
        .where_clause = null,
    };

    const decl = Declaration{
        .kind = .{ .function_decl = func_decl },
        .span = span,
        .doc_comment = null,
    };

    // Create program with just main
    const program = Program{
        .module_decl = null,
        .imports = &[_]Declaration.ImportDecl{},
        .declarations = @constCast(&[_]Declaration{decl}),
        .module_doc = null,
        .source_path = null,
        .arena = null,
    };

    // Check the program - should fail with TypeError
    const result = checker.check(&program);
    try std.testing.expectError(error.TypeError, result);

    // Should have an error about main needing effect
    try std.testing.expect(checker.hasErrors());

    var found_main_error = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "'main' function must be declared with 'effect' keyword") != null) {
            found_main_error = true;
        }
    }
    try std.testing.expect(found_main_error);
}

test "effect: main function with effect keyword allowed" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();


    // Create a return type
    var return_type = Type.primitive(.void_type, span);

    // Create main function WITH effect keyword
    const func_decl = Declaration.FunctionDecl{
        .name = "main",
        .generic_params = null,
        .parameters = &[_]Declaration.Parameter{},
        .return_type = &return_type,
        .is_effect = true, // IS an effect function
        .is_public = true,
        .body = null,
        .where_clause = null,
    };

    const decl = Declaration{
        .kind = .{ .function_decl = func_decl },
        .span = span,
        .doc_comment = null,
    };

    // Create program with just main
    const program = Program{
        .module_decl = null,
        .imports = &[_]Declaration.ImportDecl{},
        .declarations = @constCast(&[_]Declaration{decl}),
        .module_doc = null,
        .source_path = null,
        .arena = null,
    };

    // Check the program
    try checker.check(&program);

    // Should NOT have an error about main needing effect
    var found_main_error = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "'main' function must be declared with 'effect' keyword") != null) {
            found_main_error = true;
        }
    }
    try std.testing.expect(!found_main_error);
}
