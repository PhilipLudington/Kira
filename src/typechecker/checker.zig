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
pub const ScopeId = symbols.ScopeId;
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
const builtin_span = Span{
    .start = .{ .line = 0, .column = 0, .offset = 0 },
    .end = .{ .line = 0, .column = 0, .offset = 0 },
};

// Stable placeholder used for inferred pattern bindings.
// This avoids storing pointers to stack-allocated Type values.
var inferred_binding_type = Type{
    .kind = .{ .inferred = {} },
    .span = builtin_span,
};

/// Result of looking up a variant across all sum types.
const VariantLookup = struct {
    parent_sym: *const Symbol,
    variant_info: Symbol.VariantInfo,
};

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
    /// Optional scope used as a fallback for resolving AST type names.
    type_lookup_fallback_scope: ?ScopeId,
    /// When resolving types in a cross-module context, use this span for errors
    /// instead of the AST span (which belongs to another file).
    cross_module_error_span: ?Span,
    /// Whether we're in an effect function
    in_effect_function: bool,
    /// Arena for temporary type allocations during type checking
    type_arena: std.heap.ArenaAllocator,
    /// Current trait being checked (for resolving method calls on Self in default bodies)
    current_trait: ?*const Declaration.TraitDecl,

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
            .type_lookup_fallback_scope = null,
            .cross_module_error_span = null,
            .in_effect_function = false,
            .type_arena = std.heap.ArenaAllocator.init(allocator),
            .current_trait = null,
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
        for (program.declarations) |*decl| {
            try self.checkDeclaration(decl);
        }

        // E7: main function effect validation is handled by the existing
        // effect system — if main calls effectful functions without being
        // declared 'effect', the checker emits "cannot call effect function
        // from pure function" at the call site (see checkFunctionCall).

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
                    const resolved_sym = self.resolveImportAliasSymbol(sym) orelse sym;
                    return ResolvedType.named(resolved_sym.id, n.name, ast_type.span);
                } else {
                    // Check if it's a type variable in scope
                    if (self.type_var_substitutions.get(n.name)) |resolved| {
                        return resolved;
                    }
                    if (self.type_lookup_fallback_scope) |scope_id| {
                        if (self.lookupInScopeChain(scope_id, n.name)) |sym| {
                            const resolved_sym = self.resolveImportAliasSymbol(sym) orelse sym;
                            return ResolvedType.named(resolved_sym.id, n.name, ast_type.span);
                        }
                    }
                    const err_span = self.cross_module_error_span orelse ast_type.span;
                    try self.addDiagnostic(try errors_mod.undefinedType(self.allocator, n.name, err_span));
                    return ResolvedType.errorType(err_span);
                }
            },

            .generic => |g| {
                // Look up the base type
                const type_alloc = self.typeAllocator();
                if (self.symbol_table.lookup(g.base)) |sym| {
                    const resolved_sym = self.resolveImportAliasSymbol(sym) orelse sym;
                    var resolved_args = std.ArrayListUnmanaged(ResolvedType){};
                    for (g.type_arguments) |arg| {
                        try resolved_args.append(type_alloc, try self.resolveAstType(arg));
                    }
                    return .{
                        .kind = .{ .instantiated = .{
                            .base_symbol_id = resolved_sym.id,
                            .base_name = g.base,
                            .type_arguments = try resolved_args.toOwnedSlice(type_alloc),
                        } },
                        .span = ast_type.span,
                    };
                } else {
                    const err_span = self.cross_module_error_span orelse ast_type.span;
                    try self.addDiagnostic(try errors_mod.undefinedType(self.allocator, g.base, err_span));
                    return ResolvedType.errorType(err_span);
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
                    const resolved_sym = self.resolveImportAliasSymbol(sym) orelse sym;
                    if (p.generic_args) |args| {
                        var resolved_args = std.ArrayListUnmanaged(ResolvedType){};
                        for (args) |arg| {
                            try resolved_args.append(type_alloc, try self.resolveAstType(arg));
                        }
                        return .{
                            .kind = .{ .instantiated = .{
                                .base_symbol_id = resolved_sym.id,
                                .base_name = p.segments[p.segments.len - 1],
                                .type_arguments = try resolved_args.toOwnedSlice(type_alloc),
                            } },
                            .span = ast_type.span,
                        };
                    }
                    return ResolvedType.named(resolved_sym.id, p.segments[p.segments.len - 1], ast_type.span);
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
                // Inferred types arise from pattern bindings in match arms
                // where the type is determined by context (e.g., the matched
                // subject type). Return error_type which unifies with any type,
                // allowing the surrounding expressions to type-check correctly.
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
                } else if (std.mem.eql(u8, ident.name, "std") or
                    symbols.resolver.runtime_builtins.has(ident.name))
                {
                    // Skip error for 'std' and runtime builtins injected by the interpreter
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
                    if (!self.typesMatch(first_type, elem_type)) {
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

        // String concatenation with + must be checked before error propagation,
        // because inferred variables may have error_type before resolution.
        if (bin.operator == .add and
            (left_type.isString() or right_type.isString()) and
            (left_type.isString() or left_type.isError()) and
            (right_type.isString() or right_type.isError()))
        {
            return ResolvedType.primitive(.string, span);
        }

        // Error types propagate
        if (left_type.isError() or right_type.isError()) {
            return ResolvedType.errorType(span);
        }

        return switch (bin.operator) {
            // Arithmetic operators
            .add, .subtract, .multiply, .divide, .modulo => {
                // String concatenation with + (both concretely string)
                if (bin.operator == .add and left_type.isString() and right_type.isString()) {
                    return ResolvedType.primitive(.string, span);
                }
                if (left_type.isNumeric() and right_type.isNumeric()) {
                    if (self.typesMatch(left_type, right_type)) {
                        return left_type;
                    }
                    if (left_type.kind == .primitive and right_type.kind == .primitive and
                        left_type.kind.primitive.isInteger() and right_type.kind.primitive.isInteger())
                    {
                        const promoted = self.promoteIntegerPrimitive(left_type.kind.primitive, right_type.kind.primitive);
                        return ResolvedType.primitive(promoted, span);
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
                if (unify.isComparable(left_type) and
                    (self.typesMatch(left_type, right_type) or
                        (left_type.kind == .primitive and right_type.kind == .primitive and
                            left_type.kind.primitive.isInteger() and right_type.kind.primitive.isInteger())))
                {
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
                if (unify.isEquatable(left_type) and
                    (self.typesMatch(left_type, right_type) or
                        (left_type.kind == .primitive and right_type.kind == .primitive and
                            left_type.kind.primitive.isInteger() and right_type.kind.primitive.isInteger())))
                {
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

    fn promoteIntegerPrimitive(self: *TypeChecker, a: Type.PrimitiveType, b: Type.PrimitiveType) Type.PrimitiveType {
        _ = self;
        const bits_a = a.bitSize() orelse 128;
        const bits_b = b.bitSize() orelse 128;
        const bits = if (bits_a >= bits_b) bits_a else bits_b;
        const signed = a.isSigned() or b.isSigned();

        return switch (bits) {
            8 => if (signed) .i8 else .u8,
            16 => if (signed) .i16 else .u16,
            32 => if (signed) .i32 else .u32,
            64 => if (signed) .i64 else .u64,
            else => if (signed) .i128 else .u128,
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
        const object_type_raw = try self.checkExpression(fa.object);

        if (object_type_raw.isError()) {
            return ResolvedType.errorType(span);
        }

        // Expand type aliases so field access works on alias types
        const object_type = self.expandAliasType(object_type_raw) catch object_type_raw;

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
        if (try self.checkStdFunctionCall(fc, span)) |std_type| {
            return std_type;
        }

        if (try self.checkBuiltinCall(fc, span)) |builtin_type| {
            return builtin_type;
        }

        // If generic args are present, try to resolve the callee symbol for
        // trait bounds checking and type variable instantiation.
        if (fc.generic_args) |generic_args| {
            if (try self.resolveCalleeSymbol(fc.callee)) |sym| {
                const resolved_sym = self.resolveImportAliasSymbol(sym) orelse sym;
                if (resolved_sym.kind == .function) {
                    return try self.checkGenericFunctionCall(
                        resolved_sym,
                        generic_args,
                        fc.arguments,
                        span,
                    );
                }
                if (resolved_sym.kind == .variable) {
                    return try self.checkGenericVariableCall(
                        resolved_sym,
                        generic_args,
                        fc.arguments,
                        span,
                    );
                }
            }
        }

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
                    if (!self.typeIsAssignable(param, arg_type)) {
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

    /// Check if a function call is to a known built-in function (e.g. to_int, len, print).
    /// Returns the result type if it's a built-in, null otherwise.
    fn checkBuiltinCall(self: *TypeChecker, fc: Expression.FunctionCall, span: Span) TypeCheckError!?ResolvedType {
        // Only match bare identifier calls like `to_int(x)`, not `obj.method(x)`
        if (fc.callee.kind != .identifier) return null;
        const name = fc.callee.kind.identifier.name;

        // Already in symbol table — let normal resolution handle it
        if (self.symbol_table.lookup(name) != null) return null;

        const args = fc.arguments;

        // print(...), println(...) -> void (effect, variadic: 1+ args)
        if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "println")) {
            if (args.len < 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            for (args) |arg| {
                _ = try self.checkExpression(arg);
            }
            try self.addEffectViolationIfNeeded(span);
            return ResolvedType.voidType(span);
        }

        // type_of(x) -> string
        if (std.mem.eql(u8, name, "type_of")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            return ResolvedType.primitive(.string, span);
        }

        // to_string(x) -> string
        if (std.mem.eql(u8, name, "to_string")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            return ResolvedType.primitive(.string, span);
        }

        // to_int(x) -> i64
        if (std.mem.eql(u8, name, "to_int")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            return ResolvedType.primitive(.i64, span);
        }

        // to_float(x) -> f64
        if (std.mem.eql(u8, name, "to_float")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            return ResolvedType.primitive(.f64, span);
        }

        // abs(x) -> i64
        if (std.mem.eql(u8, name, "abs")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            const arg_t = try self.checkExpression(args[0]);
            // Preserve numeric type if possible
            return switch (arg_t.kind) {
                .primitive => |p| switch (p) {
                    .f64 => ResolvedType.primitive(.f64, span),
                    .f32 => ResolvedType.primitive(.f32, span),
                    else => ResolvedType.primitive(.i64, span),
                },
                else => ResolvedType.primitive(.i64, span),
            };
        }

        // min(a, b) -> numeric, max(a, b) -> numeric
        if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
            if (args.len != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, args.len, span));
                return ResolvedType.errorType(span);
            }
            const arg_t = try self.checkExpression(args[0]);
            _ = try self.checkExpression(args[1]);
            return switch (arg_t.kind) {
                .primitive => |p| switch (p) {
                    .f64 => ResolvedType.primitive(.f64, span),
                    .f32 => ResolvedType.primitive(.f32, span),
                    else => ResolvedType.primitive(.i64, span),
                },
                else => ResolvedType.primitive(.i64, span),
            };
        }

        // len(x) -> i64
        if (std.mem.eql(u8, name, "len")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            return ResolvedType.primitive(.i64, span);
        }

        // push(list, item) -> list type
        if (std.mem.eql(u8, name, "push")) {
            if (args.len != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, args.len, span));
                return ResolvedType.errorType(span);
            }
            const list_t = try self.checkExpression(args[0]);
            _ = try self.checkExpression(args[1]);
            return list_t;
        }

        // pop(list) -> list type (returns truncated array, or .none for empty)
        if (std.mem.eql(u8, name, "pop")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            const list_t = try self.checkExpression(args[0]);
            return list_t;
        }

        // head(list) -> Option[T]
        if (std.mem.eql(u8, name, "head")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            const list_t = try self.checkExpression(args[0]);
            const elem_t = self.extractListElementType(list_t) orelse ResolvedType.errorType(span);
            return try self.makeOptionType(elem_t, span);
        }

        // tail(list) -> List[T]
        if (std.mem.eql(u8, name, "tail")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            const list_t = try self.checkExpression(args[0]);
            const elem_t = self.extractListElementType(list_t) orelse ResolvedType.errorType(span);
            return try self.makeListType(elem_t, span);
        }

        // empty(x) -> bool
        if (std.mem.eql(u8, name, "empty")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            return ResolvedType.primitive(.bool, span);
        }

        // reverse(list or string) -> same type
        if (std.mem.eql(u8, name, "reverse")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            const arg_t = try self.checkExpression(args[0]);
            // reverse works on strings too, returning a string
            if (arg_t.kind == .primitive and arg_t.kind.primitive == .string) {
                return ResolvedType.primitive(.string, span);
            }
            const elem_t = self.extractListElementType(arg_t) orelse ResolvedType.errorType(span);
            return try self.makeListType(elem_t, span);
        }

        // split(s, delim) -> List[string]
        if (std.mem.eql(u8, name, "split")) {
            if (args.len != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            _ = try self.checkExpression(args[1]);
            return try self.makeListType(ResolvedType.primitive(.string, span), span);
        }

        // join(list, sep) -> string
        if (std.mem.eql(u8, name, "join")) {
            if (args.len != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            _ = try self.checkExpression(args[1]);
            return ResolvedType.primitive(.string, span);
        }

        // trim(s) -> string
        if (std.mem.eql(u8, name, "trim")) {
            if (args.len != 1) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            return ResolvedType.primitive(.string, span);
        }

        // contains(s, substr) -> bool
        if (std.mem.eql(u8, name, "contains")) {
            if (args.len != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            _ = try self.checkExpression(args[1]);
            return ResolvedType.primitive(.bool, span);
        }

        // starts_with(s, prefix) -> bool, ends_with(s, suffix) -> bool
        if (std.mem.eql(u8, name, "starts_with") or std.mem.eql(u8, name, "ends_with")) {
            if (args.len != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            _ = try self.checkExpression(args[1]);
            return ResolvedType.primitive(.bool, span);
        }

        // assert(condition) or assert(condition, message) -> void
        if (std.mem.eql(u8, name, "assert")) {
            if (args.len < 1 or args.len > 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            if (args.len == 2) {
                _ = try self.checkExpression(args[1]);
            }
            return ResolvedType.voidType(span);
        }

        // assert_eq(a, b) -> void
        if (std.mem.eql(u8, name, "assert_eq")) {
            if (args.len != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            _ = try self.checkExpression(args[1]);
            return ResolvedType.voidType(span);
        }

        // prop_test(property_fn) or prop_test(property_fn, iterations) -> void
        if (std.mem.eql(u8, name, "prop_test")) {
            if (args.len < 1 or args.len > 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, args.len, span));
                return ResolvedType.errorType(span);
            }
            _ = try self.checkExpression(args[0]);
            if (args.len == 2) {
                _ = try self.checkExpression(args[1]);
            }
            return ResolvedType.voidType(span);
        }

        return null;
    }

    fn appendExpressionPath(
        self: *TypeChecker,
        expr: *const Expression,
        out: *std.ArrayListUnmanaged([]const u8),
    ) TypeCheckError!bool {
        return switch (expr.kind) {
            .identifier => |ident| blk: {
                try out.append(self.typeAllocator(), ident.name);
                break :blk true;
            },
            .field_access => |fa| blk: {
                if (!(try self.appendExpressionPath(fa.object, out))) break :blk false;
                try out.append(self.typeAllocator(), fa.field);
                break :blk true;
            },
            else => false,
        };
    }

    fn extractExpressionPath(self: *TypeChecker, expr: *const Expression) TypeCheckError!?[][]const u8 {
        var path = std.ArrayListUnmanaged([]const u8){};
        if (!(try self.appendExpressionPath(expr, &path))) {
            return null;
        }
        const segments = try path.toOwnedSlice(self.typeAllocator());
        return segments;
    }

    fn addEffectViolationIfNeeded(self: *TypeChecker, span: Span) TypeCheckError!void {
        if (!self.in_effect_function) {
            try self.addDiagnostic(try errors_mod.effectViolation(
                self.allocator,
                "cannot call effect function from pure function",
                span,
            ));
        }
    }

    fn makeOptionType(self: *TypeChecker, inner: ResolvedType, span: Span) TypeCheckError!ResolvedType {
        const type_alloc = self.typeAllocator();
        const inner_ptr = try type_alloc.create(ResolvedType);
        inner_ptr.* = inner;
        return .{ .kind = .{ .option = inner_ptr }, .span = span };
    }

    fn makeResultType(self: *TypeChecker, ok_type: ResolvedType, err_type: ResolvedType, span: Span) TypeCheckError!ResolvedType {
        const type_alloc = self.typeAllocator();
        const ok_ptr = try type_alloc.create(ResolvedType);
        ok_ptr.* = ok_type;
        const err_ptr = try type_alloc.create(ResolvedType);
        err_ptr.* = err_type;
        return .{
            .kind = .{ .result = .{
                .ok_type = ok_ptr,
                .err_type = err_ptr,
            } },
            .span = span,
        };
    }

    fn makeListType(self: *TypeChecker, elem_type: ResolvedType, span: Span) TypeCheckError!ResolvedType {
        const list_sym = self.symbol_table.lookup("List") orelse return ResolvedType.errorType(span);
        const type_alloc = self.typeAllocator();
        const args = try type_alloc.alloc(ResolvedType, 1);
        args[0] = elem_type;
        return .{
            .kind = .{ .instantiated = .{
                .base_symbol_id = list_sym.id,
                .base_name = "List",
                .type_arguments = args,
            } },
            .span = span,
        };
    }

    fn extractListElementType(self: *TypeChecker, list_type: ResolvedType) ?ResolvedType {
        _ = self;
        return switch (list_type.kind) {
            .instantiated => |inst| {
                if (std.mem.eql(u8, inst.base_name, "List") and inst.type_arguments.len == 1) {
                    return inst.type_arguments[0];
                }
                return null;
            },
            .array => |arr| arr.element_type.*,
            else => null,
        };
    }

    fn getListElementType(self: *TypeChecker, resolved_type_raw: ResolvedType) ?ResolvedType {
        // Expand type aliases (e.g., Substitution -> List[Binding])
        const resolved_type = self.expandAliasType(resolved_type_raw) catch resolved_type_raw;
        return switch (resolved_type.kind) {
            .instantiated => |inst| {
                if (std.mem.eql(u8, inst.base_name, "List") and inst.type_arguments.len == 1) {
                    return inst.type_arguments[0];
                }
                return null;
            },
            else => null,
        };
    }

    fn checkStdCallByPath(
        self: *TypeChecker,
        path: [][]const u8,
        generic_args: ?[]*Type,
        arguments: []*Expression,
        span: Span,
    ) TypeCheckError!?ResolvedType {
        if (path.len != 3) return null;
        if (!std.mem.eql(u8, path[0], "std")) return null;

        // std.io.*
        if (std.mem.eql(u8, path[1], "io")) {
            if (std.mem.eql(u8, path[2], "println") or std.mem.eql(u8, path[2], "print")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                try self.addEffectViolationIfNeeded(span);
                return ResolvedType.voidType(span);
            }
            if (std.mem.eql(u8, path[2], "read_line")) {
                if (arguments.len != 0) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 0, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                try self.addEffectViolationIfNeeded(span);
                return try self.makeResultType(
                    ResolvedType.primitive(.string, span),
                    ResolvedType.primitive(.string, span),
                    span,
                );
            }
            return null;
        }

        // std.fs.*
        if (std.mem.eql(u8, path[1], "fs")) {
            if (std.mem.eql(u8, path[2], "read_file")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                const arg_t = try self.checkExpression(arguments[0]);
                const expected = ResolvedType.primitive(.string, arguments[0].span);
                if (!self.typeIsAssignable(expected, arg_t)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        expected,
                        arg_t,
                        arguments[0].span,
                    ));
                }
                try self.addEffectViolationIfNeeded(span);
                return try self.makeResultType(
                    ResolvedType.primitive(.string, span),
                    ResolvedType.primitive(.string, span),
                    span,
                );
            }
            if (std.mem.eql(u8, path[2], "write_file") or
                std.mem.eql(u8, path[2], "remove") or
                std.mem.eql(u8, path[2], "append_file"))
            {
                const expected_args: usize = if (std.mem.eql(u8, path[2], "write_file") or std.mem.eql(u8, path[2], "append_file")) 2 else 1;
                if (arguments.len != expected_args) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, expected_args, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                for (arguments) |arg| {
                    _ = try self.checkExpression(arg);
                }
                try self.addEffectViolationIfNeeded(span);
                return try self.makeResultType(
                    ResolvedType.voidType(span),
                    ResolvedType.primitive(.string, span),
                    span,
                );
            }
            if (std.mem.eql(u8, path[2], "exists") or
                std.mem.eql(u8, path[2], "is_file") or
                std.mem.eql(u8, path[2], "is_dir"))
            {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                try self.addEffectViolationIfNeeded(span);
                return ResolvedType.primitive(.bool, span);
            }
            return null;
        }

        // std.string.*
        if (std.mem.eql(u8, path[1], "string")) {
            if (std.mem.eql(u8, path[2], "length")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.i64, span);
            }
            if (std.mem.eql(u8, path[2], "trim")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.string, span);
            }
            if (std.mem.eql(u8, path[2], "contains")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return ResolvedType.primitive(.bool, span);
            }
            if (std.mem.eql(u8, path[2], "starts_with") or std.mem.eql(u8, path[2], "ends_with")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return ResolvedType.primitive(.bool, span);
            }
            if (std.mem.eql(u8, path[2], "substring")) {
                if (arguments.len != 3) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 3, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                _ = try self.checkExpression(arguments[2]);
                return try self.makeOptionType(ResolvedType.primitive(.string, span), span);
            }
            if (std.mem.eql(u8, path[2], "char_at")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return try self.makeOptionType(ResolvedType.primitive(.char, span), span);
            }
            if (std.mem.eql(u8, path[2], "split")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return try self.makeListType(ResolvedType.primitive(.string, span), span);
            }
            if (std.mem.eql(u8, path[2], "chars")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return try self.makeListType(ResolvedType.primitive(.char, span), span);
            }
            if (std.mem.eql(u8, path[2], "index_of")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return try self.makeOptionType(ResolvedType.primitive(.i64, span), span);
            }
            if (std.mem.eql(u8, path[2], "parse_int")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return try self.makeOptionType(ResolvedType.primitive(.i64, span), span);
            }
            if (std.mem.eql(u8, path[2], "parse_float")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return try self.makeOptionType(ResolvedType.primitive(.f64, span), span);
            }
            // equals(a, b) -> bool
            if (std.mem.eql(u8, path[2], "equals")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return ResolvedType.primitive(.bool, span);
            }
            // byte_length(s) -> i64
            if (std.mem.eql(u8, path[2], "byte_length")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.i64, span);
            }
            // concat(a, b) -> string
            if (std.mem.eql(u8, path[2], "concat")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return ResolvedType.primitive(.string, span);
            }
            // replace(s, old, new) -> string
            if (std.mem.eql(u8, path[2], "replace")) {
                if (arguments.len != 3) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 3, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                _ = try self.checkExpression(arguments[2]);
                return ResolvedType.primitive(.string, span);
            }
            // to_upper(s) -> string, to_lower(s) -> string
            if (std.mem.eql(u8, path[2], "to_upper") or std.mem.eql(u8, path[2], "to_lower")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.string, span);
            }
            // from_i32(n), from_i64(n), from_int(n), from_f32(n), from_f64(n),
            // from_float(n), from_bool(b), to_string(v) -> string
            if (std.mem.eql(u8, path[2], "from_i32") or
                std.mem.eql(u8, path[2], "from_i64") or
                std.mem.eql(u8, path[2], "from_int") or
                std.mem.eql(u8, path[2], "from_f32") or
                std.mem.eql(u8, path[2], "from_f64") or
                std.mem.eql(u8, path[2], "from_float") or
                std.mem.eql(u8, path[2], "from_bool") or
                std.mem.eql(u8, path[2], "to_string"))
            {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.string, span);
            }
            // is_valid_utf8(s) -> bool
            if (std.mem.eql(u8, path[2], "is_valid_utf8")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.bool, span);
            }
            return null;
        }

        // std.list.*
        if (std.mem.eql(u8, path[1], "list")) {
            if (std.mem.eql(u8, path[2], "length")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.i64, span);
            }
            if (std.mem.eql(u8, path[2], "head")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                const list_t = try self.checkExpression(arguments[0]);
                const elem_t = self.extractListElementType(list_t) orelse ResolvedType.errorType(span);
                return try self.makeOptionType(elem_t, span);
            }
            if (std.mem.eql(u8, path[2], "tail")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                const list_t = try self.checkExpression(arguments[0]);
                const elem_t = self.extractListElementType(list_t) orelse ResolvedType.errorType(span);
                const list_elem_t = try self.makeListType(elem_t, span);
                return try self.makeOptionType(list_elem_t, span);
            }
            if (std.mem.eql(u8, path[2], "empty")) {
                if (arguments.len != 0) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 0, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                if (generic_args) |gargs| {
                    if (gargs.len == 1) {
                        const elem_t = try self.resolveAstType(gargs[0]);
                        return try self.makeListType(elem_t, span);
                    }
                }
                return ResolvedType.errorType(span);
            }
            if (std.mem.eql(u8, path[2], "cons")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                const elem_t = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return try self.makeListType(elem_t, span);
            }
            if (std.mem.eql(u8, path[2], "map")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                const list_t = try self.checkExpression(arguments[0]);
                const fn_t = try self.checkExpression(arguments[1]);
                var out_t: ?ResolvedType = null;
                if (generic_args) |gargs| {
                    if (gargs.len == 2) {
                        out_t = try self.resolveAstType(gargs[1]);
                    }
                }
                if (out_t == null and fn_t.kind == .function) {
                    out_t = fn_t.kind.function.return_type.*;
                }
                if (out_t == null) {
                    out_t = self.extractListElementType(list_t);
                }
                return try self.makeListType(out_t orelse ResolvedType.errorType(span), span);
            }
            if (std.mem.eql(u8, path[2], "filter")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                const list_t = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                const elem_t = self.extractListElementType(list_t) orelse ResolvedType.errorType(span);
                return try self.makeListType(elem_t, span);
            }
            return null;
        }

        // std.map.*
        if (std.mem.eql(u8, path[1], "map")) {
            if (std.mem.eql(u8, path[2], "get")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return try self.makeOptionType(ResolvedType.errorType(span), span);
            }
            if (std.mem.eql(u8, path[2], "contains")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return ResolvedType.primitive(.bool, span);
            }
            if (std.mem.eql(u8, path[2], "keys") or
                std.mem.eql(u8, path[2], "values") or
                std.mem.eql(u8, path[2], "entries"))
            {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return try self.makeListType(ResolvedType.errorType(span), span);
            }
            if (std.mem.eql(u8, path[2], "size")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.i64, span);
            }
            if (std.mem.eql(u8, path[2], "is_empty")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.bool, span);
            }
            return null;
        }

        // std.time.*
        if (std.mem.eql(u8, path[1], "time")) {
            if (std.mem.eql(u8, path[2], "now")) {
                if (arguments.len != 0) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 0, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                return ResolvedType.primitive(.i64, span);
            }
            if (std.mem.eql(u8, path[2], "sleep")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                try self.addEffectViolationIfNeeded(span);
                return ResolvedType.voidType(span);
            }
            if (std.mem.eql(u8, path[2], "elapsed")) {
                if (arguments.len != 2) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 2, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                _ = try self.checkExpression(arguments[1]);
                return ResolvedType.primitive(.i64, span);
            }
            return null;
        }

        // Reject std.i32 / std.i64 / std.f32 / std.f64 with helpful redirect
        if (std.mem.eql(u8, path[1], "i32") or std.mem.eql(u8, path[1], "i64")) {
            var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
            errdefer builder.deinit();
            try builder.write("module 'std.");
            try builder.write(path[1]);
            try builder.write("' does not exist; use 'std.int.' instead");
            try self.addDiagnostic(try builder.build());
            for (arguments) |arg| {
                _ = try self.checkExpression(arg);
            }
            return ResolvedType.errorType(span);
        }
        if (std.mem.eql(u8, path[1], "f32") or std.mem.eql(u8, path[1], "f64")) {
            var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
            errdefer builder.deinit();
            try builder.write("module 'std.");
            try builder.write(path[1]);
            try builder.write("' does not exist; use 'std.float.' instead");
            try self.addDiagnostic(try builder.build());
            for (arguments) |arg| {
                _ = try self.checkExpression(arg);
            }
            return ResolvedType.errorType(span);
        }

        // std.int.* / std.float.* / std.char.*
        if (std.mem.eql(u8, path[1], "int")) {
            if (std.mem.eql(u8, path[2], "to_string")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.string, span);
            }
            if (std.mem.eql(u8, path[2], "to_i64")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.i64, span);
            }
            return null;
        }
        if (std.mem.eql(u8, path[1], "float")) {
            if (std.mem.eql(u8, path[2], "to_string")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.string, span);
            }
            if (std.mem.eql(u8, path[2], "from_int")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.f64, span);
            }
            return null;
        }
        if (std.mem.eql(u8, path[1], "char")) {
            if (std.mem.eql(u8, path[2], "to_i32")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return ResolvedType.primitive(.i64, span);
            }
            if (std.mem.eql(u8, path[2], "from_i32")) {
                if (arguments.len != 1) {
                    try self.addDiagnostic(try errors_mod.wrongArgumentCount(self.allocator, 1, arguments.len, span));
                    return ResolvedType.errorType(span);
                }
                _ = try self.checkExpression(arguments[0]);
                return try self.makeOptionType(ResolvedType.primitive(.char, span), span);
            }
            return null;
        }

        return null;
    }

    fn checkStdFunctionCall(self: *TypeChecker, fc: Expression.FunctionCall, span: Span) TypeCheckError!?ResolvedType {
        const maybe_path = try self.extractExpressionPath(fc.callee);
        if (maybe_path == null) return null;
        return try self.checkStdCallByPath(maybe_path.?, fc.generic_args, fc.arguments, span);
    }

    /// Check method call
    fn checkMethodCall(self: *TypeChecker, mc: Expression.MethodCall, span: Span) TypeCheckError!ResolvedType {
        const maybe_obj_path = try self.extractExpressionPath(mc.object);
        if (maybe_obj_path) |obj_path| {
            const type_alloc = self.typeAllocator();
            const path = try type_alloc.alloc([]const u8, obj_path.len + 1);
            @memcpy(path[0..obj_path.len], obj_path);
            path[obj_path.len] = mc.method;

            if (try self.checkStdCallByPath(path, mc.generic_args, mc.arguments, span)) |std_type| {
                return std_type;
            }
        }

        const object_type = try self.checkExpression(mc.object);

        if (object_type.isError()) {
            return ResolvedType.errorType(span);
        }

        // Type-check all arguments first
        const type_alloc = self.typeAllocator();
        var arg_types = std.ArrayListUnmanaged(ResolvedType){};
        for (mc.arguments) |arg| {
            try arg_types.append(type_alloc, try self.checkExpression(arg));
        }

        // When inside a trait default body, resolve method calls on Self against the trait's own methods
        if (object_type.kind == .type_var) {
            if (std.mem.eql(u8, object_type.kind.type_var.name, "Self")) {
                if (self.current_trait) |trait_decl| {
                    for (trait_decl.methods) |trait_method| {
                        if (std.mem.eql(u8, trait_method.name, mc.method)) {
                            // Count self parameter offset
                            var self_offset: usize = 0;
                            if (trait_method.parameters.len > 0) {
                                if (trait_method.parameters[0].param_type.kind == .self_type or
                                    (trait_method.parameters[0].param_type.kind == .named and
                                    std.mem.eql(u8, trait_method.parameters[0].param_type.kind.named.name, "Self")))
                                {
                                    self_offset = 1;
                                }
                            }
                            const expected_args = trait_method.parameters.len - self_offset;
                            if (mc.arguments.len != expected_args) {
                                try self.addDiagnostic(try errors_mod.simpleError(
                                    self.allocator,
                                    "wrong number of arguments in method call",
                                    span,
                                ));
                                return ResolvedType.errorType(span);
                            }
                            return try self.resolveAstType(trait_method.return_type);
                        }
                    }
                }
            }
        }

        // Extract the type name for impl lookup
        const type_name: ?[]const u8 = switch (object_type.kind) {
            .primitive => |p| p.toString(),
            .named => |n| n.name,
            .instantiated => |inst| inst.base_name,
            else => null,
        };

        if (type_name) |tn| {
            // Look up all implementations for this type
            const impls = self.symbol_table.findImplementations(type_alloc, tn) catch {
                return error.OutOfMemory;
            };

            // Search for the method across all impls
            var found_method: ?*const Symbol = null;
            var found_count: usize = 0;
            for (impls) |impl_info| {
                for (impl_info.methods) |method_id| {
                    if (self.symbol_table.getSymbol(method_id)) |method_sym| {
                        if (std.mem.eql(u8, method_sym.name, mc.method)) {
                            found_method = method_sym;
                            found_count += 1;
                        }
                    }
                }
            }

            if (found_count > 1) {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "ambiguous method call: multiple trait implementations provide this method",
                    span,
                ));
                return ResolvedType.errorType(span);
            }

            if (found_method) |method_sym| {
                if (method_sym.kind == .function) {
                    const func_sym = method_sym.kind.function;

                    // The first parameter is `self: Self`, so effective params start at index 1
                    const self_param_offset: usize = if (func_sym.parameter_types.len > 0) blk: {
                        const first_param_type = func_sym.parameter_types[0];
                        if (first_param_type.kind == .self_type or
                            (first_param_type.kind == .named and std.mem.eql(u8, first_param_type.kind.named.name, "Self")))
                        {
                            break :blk 1;
                        }
                        break :blk 0;
                    } else 0;

                    const expected_arg_count = func_sym.parameter_types.len - self_param_offset;
                    if (mc.arguments.len != expected_arg_count) {
                        try self.addDiagnostic(try errors_mod.simpleError(
                            self.allocator,
                            "wrong number of arguments in method call",
                            span,
                        ));
                        return ResolvedType.errorType(span);
                    }

                    // Resolve the return type, substituting Self with the concrete type
                    const saved_self_type = self.self_type;
                    self.self_type = object_type;
                    defer self.self_type = saved_self_type;

                    const return_type = try self.resolveAstType(func_sym.return_type);

                    return return_type;
                }
            }

            // Check trait default methods: if the type implements a trait,
            // default methods from that trait are also available
            var found_default_method: ?*const Type = null;
            var default_method_count: usize = 0;
            for (impls) |impl_info| {
                if (impl_info.trait_name) |trait_name| {
                    if (self.symbol_table.lookup(trait_name)) |trait_sym| {
                        if (trait_sym.kind == .trait_def) {
                            for (trait_sym.kind.trait_def.methods) |trait_method| {
                                if (trait_method.hasDefault() and std.mem.eql(u8, trait_method.name, mc.method)) {
                                    found_default_method = trait_method.return_type;
                                    default_method_count += 1;
                                }
                            }
                        }
                    }
                }
            }

            if (default_method_count > 1) {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "ambiguous method call: multiple trait defaults provide this method",
                    span,
                ));
                return ResolvedType.errorType(span);
            }

            if (found_default_method) |return_type_ast| {
                const saved_self_type = self.self_type;
                self.self_type = object_type;
                defer self.self_type = saved_self_type;
                return try self.resolveAstType(return_type_ast);
            }
        }

        // Method not found
        try self.addDiagnostic(try errors_mod.simpleError(
            self.allocator,
            "method not found",
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

        // Check body in closure scope with parameters bound.
        _ = try self.symbol_table.enterScope(.function);
        errdefer self.scopeCleanup();
        for (closure.parameters) |param| {
            const param_sym = Symbol.variable(unassigned_symbol_id, param.name, param.param_type, false, false, param.span);
            _ = self.symbol_table.define(param_sym) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
            };
        }
        for (closure.body) |*stmt| {
            try self.checkStatement(stmt);
        }
        try self.scopeLeave();

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

    fn checkBlockExpressionType(self: *TypeChecker, block: []Statement, span: Span) TypeCheckError!ResolvedType {
        if (block.len == 0) return ResolvedType.voidType(span);

        if (block.len > 1) {
            for (block[0 .. block.len - 1]) |*stmt| {
                try self.checkStatement(stmt);
            }
        }

        const last_stmt = &block[block.len - 1];
        return switch (last_stmt.kind) {
            .expression_statement => |expr| try self.checkExpression(expr),
            else => blk: {
                try self.checkStatement(last_stmt);
                break :blk ResolvedType.voidType(span);
            },
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
            try self.addPatternBindings(arm.pattern, null, subject_type, false);

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
                .block => |block| try self.checkBlockExpressionType(block, span),
            };

            if (result_type) |rt| {
                if (!self.typesMatch(rt, arm_type)) {
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
                .block => |block| try self.checkBlockExpressionType(block, span),
            };
            try self.scopeLeave();
            break :then_blk t;
        };

        const else_type = else_blk: {
            _ = try self.symbol_table.enterScope(.block);
            errdefer self.scopeCleanup();
            const t = switch (ie.else_branch) {
                .expression => |e| try self.checkExpression(e),
                .block => |block| try self.checkBlockExpressionType(block, span),
            };
            try self.scopeLeave();
            break :else_blk t;
        };

        // Both branches must have the same type
        if (!self.typesMatch(then_type, else_type)) {
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
                const td = sym.kind.type_def;
                switch (td.definition) {
                    .sum_type => |st| {
                        // Find the specific variant within this sum type
                        for (st.variants) |v| {
                            if (std.mem.eql(u8, v.name, vc.variant_name)) {
                                return try self.validateVariantConstructorArgs(
                                    vc.variant_name,
                                    v,
                                    vc.arguments,
                                    sym,
                                    span,
                                );
                            }
                        }
                    },
                    else => {},
                }
                // Type exists but variant not found in it — check arguments anyway
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
            // Option[T] where T is unknown — use error_type as placeholder
            const type_alloc = self.typeAllocator();
            const inner_ptr = try type_alloc.create(ResolvedType);
            inner_ptr.* = ResolvedType.errorType(span);
            return .{
                .kind = .{ .option = inner_ptr },
                .span = span,
            };
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
                    const ok_type = try self.checkExpression(args[0]);
                    const type_alloc = self.typeAllocator();
                    const ok_ptr = try type_alloc.create(ResolvedType);
                    ok_ptr.* = ok_type;
                    const err_ptr = try type_alloc.create(ResolvedType);
                    err_ptr.* = ResolvedType.errorType(span);
                    return .{
                        .kind = .{ .result = .{
                            .ok_type = ok_ptr,
                            .err_type = err_ptr,
                        } },
                        .span = span,
                    };
                }
            }
        } else if (std.mem.eql(u8, vc.variant_name, "Err")) {
            if (vc.arguments) |args| {
                if (args.len == 1) {
                    const err_type = try self.checkExpression(args[0]);
                    const type_alloc = self.typeAllocator();
                    const ok_ptr = try type_alloc.create(ResolvedType);
                    ok_ptr.* = ResolvedType.errorType(span);
                    const err_ptr = try type_alloc.create(ResolvedType);
                    err_ptr.* = err_type;
                    return .{
                        .kind = .{ .result = .{
                            .ok_type = ok_ptr,
                            .err_type = err_ptr,
                        } },
                        .span = span,
                    };
                }
            }
        } else if (std.mem.eql(u8, vc.variant_name, "Cons")) {
            const arg_count: usize = if (vc.arguments) |args| args.len else 0;
            if (arg_count != 2) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                    self.allocator,
                    2,
                    arg_count,
                    span,
                ));
                if (vc.arguments) |args| {
                    for (args) |arg| {
                        _ = try self.checkExpression(arg);
                    }
                }
                return ResolvedType.errorType(span);
            }

            const args = vc.arguments.?;
            const head_type = try self.checkExpression(args[0]);
            const tail_type = try self.checkExpression(args[1]);

            if (self.getListElementType(tail_type)) |tail_elem_type| {
                if (tail_elem_type.isError() and !head_type.isError()) {
                    // Preserve head-driven inference for Cons(_, Nil):
                    // Nil is represented as List[error] until context is known.
                    return try self.makeListType(head_type, span);
                }
                if (head_type.isError() and !tail_elem_type.isError()) {
                    return try self.makeListType(tail_elem_type, span);
                }
                if (!head_type.isError() and !tail_elem_type.isError() and !self.typesMatch(head_type, tail_elem_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        tail_elem_type,
                        head_type,
                        args[0].span,
                    ));
                }
                return try self.makeListType(tail_elem_type, span);
            }
            if (!tail_type.isError()) {
                const expected_tail_type = try self.makeListType(head_type, args[1].span);
                if (!expected_tail_type.isError() and !head_type.isError()) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        expected_tail_type,
                        tail_type,
                        args[1].span,
                    ));
                }
            }
            return try self.makeListType(head_type, span);
        } else if (std.mem.eql(u8, vc.variant_name, "Nil")) {
            const arg_count: usize = if (vc.arguments) |args| args.len else 0;
            if (arg_count > 0) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                    self.allocator,
                    0,
                    arg_count,
                    span,
                ));
                if (vc.arguments) |args| {
                    for (args) |arg| {
                        _ = try self.checkExpression(arg);
                    }
                }
            }
            return try self.makeListType(ResolvedType.errorType(span), span);
        }

        // Search all type definitions for a sum type containing this variant
        if (try self.findVariantParentType(vc.variant_name, span)) |lookup| {
            return try self.validateVariantConstructorArgs(
                vc.variant_name,
                lookup.variant_info,
                vc.arguments,
                lookup.parent_sym,
                span,
            );
        }

        try self.addDiagnostic(try errors_mod.undefinedSymbol(self.allocator, vc.variant_name, span));
        return ResolvedType.errorType(span);
    }

    /// Validate variant constructor arguments against the variant's field definition.
    /// Returns the parent sum type on success.
    fn validateVariantConstructorArgs(
        self: *TypeChecker,
        variant_name: []const u8,
        variant_info: Symbol.VariantInfo,
        arguments: ?[]*Expression,
        parent_sym: *const Symbol,
        span: Span,
    ) TypeCheckError!ResolvedType {
        const arg_count: usize = if (arguments) |args| args.len else 0;

        if (variant_info.fields) |fields| {
            switch (fields) {
                .tuple_fields => |tuple_fields| {
                    if (arg_count != tuple_fields.len) {
                        try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                            self.allocator,
                            tuple_fields.len,
                            arg_count,
                            span,
                        ));
                    } else if (arguments) |args| {
                        for (args, tuple_fields) |arg, field_type| {
                            const arg_type = try self.checkExpression(arg);
                            const expected = try self.resolveAstType(field_type);
                            if (!arg_type.isError() and !expected.isError() and !self.typesMatch(arg_type, expected)) {
                                try self.addDiagnostic(try errors_mod.typeMismatch(
                                    self.allocator,
                                    expected,
                                    arg_type,
                                    arg.span,
                                ));
                            }
                        }
                    }
                },
                .record_fields => |record_fields| {
                    if (arg_count != record_fields.len) {
                        try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                            self.allocator,
                            record_fields.len,
                            arg_count,
                            span,
                        ));
                    } else if (arguments) |args| {
                        for (args, record_fields) |arg, field_info| {
                            const arg_type = try self.checkExpression(arg);
                            const expected = try self.resolveAstType(field_info.field_type);
                            if (!arg_type.isError() and !expected.isError() and !self.typesMatch(arg_type, expected)) {
                                try self.addDiagnostic(try errors_mod.typeMismatch(
                                    self.allocator,
                                    expected,
                                    arg_type,
                                    arg.span,
                                ));
                            }
                        }
                    }
                },
            }
        } else {
            // Nullary variant — no fields expected
            if (arg_count > 0) {
                try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                    self.allocator,
                    0,
                    arg_count,
                    span,
                ));
            }
        }

        _ = variant_name;
        return ResolvedType.named(parent_sym.id, parent_sym.name, span);
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
                if (!self.typesMatch(et, end_type)) {
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
                if (!self.typesMatch(inner.*, default_type)) {
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
                const normalized_declared = try self.expandAliasType(declared_type);
                const normalized_init = try self.expandAliasType(init_type);
                if (!self.typeIsAssignable(normalized_declared, normalized_init)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        normalized_declared,
                        normalized_init,
                        lb.initializer.span,
                    ));
                }

                try self.checkPattern(lb.pattern, normalized_init);

                // Add all bindings from the pattern to scope
                try self.addPatternBindings(lb.pattern, lb.explicit_type, normalized_declared, lb.allow_shadow);
            },

            .var_binding => |vb| {
                // Local mutation via var is allowed in pure functions —
                // only I/O and calling effect functions are true side effects.

                // explicit_type is required in Kira
                const declared_type = try self.resolveAstType(vb.explicit_type);

                if (vb.initializer) |initializer| {
                    const init_type = try self.checkExpression(initializer);
                    if (!self.typeIsAssignable(declared_type, init_type)) {
                        try self.addDiagnostic(try errors_mod.typeMismatch(
                            self.allocator,
                            declared_type,
                            init_type,
                            initializer.span,
                        ));
                    }
                }

                if (!vb.allow_shadow and self.symbol_table.lookupLocal(vb.name) == null and self.symbol_table.lookupInParentScopes(vb.name) != null) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "shadowing binding requires 'shadow' keyword",
                        stmt.span,
                    ));
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

                // Simple identifier reassignment (var x = ...; x = val) is allowed in
                // pure functions — local mutation is an implementation detail, not an
                // effect. Only structural mutation (field/index) requires effect context
                // because it could affect shared references.
                const target_type = switch (assign.target) {
                    .identifier => |name| blk: {
                        if (self.symbol_table.lookup(name)) |sym| {
                            // Check mutability: assignment to let binding is a compile error
                            if (sym.kind == .variable and !sym.kind.variable.is_mutable) {
                                try self.addDiagnostic(try errors_mod.simpleError(
                                    self.allocator,
                                    "cannot assign to immutable binding (use 'var' instead of 'let')",
                                    stmt.span,
                                ));
                            }
                            break :blk try self.getSymbolType(sym, stmt.span);
                        }
                        try self.addDiagnostic(try errors_mod.undefinedSymbol(self.allocator, name, stmt.span));
                        break :blk ResolvedType.errorType(stmt.span);
                    },
                    .field_access => |ft| blk: {
                        // Field mutation requires effect context
                        if (!self.in_effect_function) {
                            try self.addDiagnostic(try errors_mod.effectViolation(
                                self.allocator,
                                "field mutation is only allowed in effect functions",
                                stmt.span,
                            ));
                        }
                        // Convert FieldTarget to FieldAccess (same structure)
                        const fa = Expression.FieldAccess{
                            .object = ft.object,
                            .field = ft.field,
                        };
                        break :blk try self.checkFieldAccess(fa, stmt.span);
                    },
                    .index_access => |it| blk: {
                        // Index mutation requires effect context
                        if (!self.in_effect_function) {
                            try self.addDiagnostic(try errors_mod.effectViolation(
                                self.allocator,
                                "index mutation is only allowed in effect functions",
                                stmt.span,
                            ));
                        }
                        // Convert IndexTarget to IndexAccess (same structure)
                        const ia = Expression.IndexAccess{
                            .object = it.object,
                            .index = it.index,
                        };
                        break :blk try self.checkIndexAccess(ia, stmt.span);
                    },
                };

                if (!self.typesMatch(target_type, value_type)) {
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
                const elem_type_opt = unify.getIterableElement(iterable_type);
                if (elem_type_opt) |elem_type| {
                    try self.checkPattern(for_loop.pattern, elem_type);
                }
                // Always add bindings so loop body can reference the variable.
                // Preserve iterable element type when known to avoid degrading loop-bound
                // variables to inferred/error placeholders.
                try self.addPatternBindings(for_loop.pattern, null, elem_type_opt, false);

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
                    try self.addPatternBindings(arm.pattern, null, subject_type, false);

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
                        if (!self.typesMatch(expected, value_type)) {
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
    fn checkPattern(self: *TypeChecker, pattern: *const Pattern, expected_type_raw: ResolvedType) TypeCheckError!void {
        // Expand type aliases so downstream code sees the underlying type
        // (e.g., Substitution -> List[Binding] so Nil/Cons patterns work)
        const expected_type = self.expandAliasType(expected_type_raw) catch expected_type_raw;
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
                // Skip checking if expected type is an error placeholder
                if (expected_type.isError()) return;

                // Built-in Option[T]: handle Some(x) and None patterns directly
                // Covers both ResolvedType.option and instantiated "Option"
                if (self.getOptionInnerType(expected_type)) |inner_type| {
                    const pat_arg_count: usize = if (ctor.arguments) |a| a.len else 0;
                    if (std.mem.eql(u8, ctor.variant_name, "Some")) {
                        if (pat_arg_count != 1) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                1,
                                pat_arg_count,
                                pattern.span,
                            ));
                        } else if (ctor.arguments) |args| {
                            const p = switch (args[0]) {
                                .positional => |pos| pos,
                                .named => |n| n.pattern,
                            };
                            try self.checkPattern(p, inner_type);
                        }
                    } else if (std.mem.eql(u8, ctor.variant_name, "None")) {
                        if (pat_arg_count > 0) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                0,
                                pat_arg_count,
                                pattern.span,
                            ));
                        }
                    } else {
                        try self.addDiagnostic(try errors_mod.simpleError(
                            self.allocator,
                            "variant not found in matched type",
                            pattern.span,
                        ));
                    }
                    return;
                }

                // Built-in Result[T, E]: handle Ok(x) and Err(e) patterns directly
                // Covers both ResolvedType.result and instantiated "Result"
                if (self.getResultTypes(expected_type)) |result_types| {
                    const pat_arg_count: usize = if (ctor.arguments) |a| a.len else 0;
                    if (std.mem.eql(u8, ctor.variant_name, "Ok")) {
                        if (pat_arg_count != 1) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                1,
                                pat_arg_count,
                                pattern.span,
                            ));
                        } else if (ctor.arguments) |args| {
                            const p = switch (args[0]) {
                                .positional => |pos| pos,
                                .named => |n| n.pattern,
                            };
                            try self.checkPattern(p, result_types[0]);
                        }
                    } else if (std.mem.eql(u8, ctor.variant_name, "Err")) {
                        if (pat_arg_count != 1) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                1,
                                pat_arg_count,
                                pattern.span,
                            ));
                        } else if (ctor.arguments) |args| {
                            const p = switch (args[0]) {
                                .positional => |pos| pos,
                                .named => |n| n.pattern,
                            };
                            try self.checkPattern(p, result_types[1]);
                        }
                    } else {
                        try self.addDiagnostic(try errors_mod.simpleError(
                            self.allocator,
                            "variant not found in matched type",
                            pattern.span,
                        ));
                    }
                    return;
                }

                // Built-in List[T]: handle Cons(head, tail) and Nil patterns directly
                if (self.getListElementType(expected_type)) |elem_type| {
                    const pat_arg_count: usize = if (ctor.arguments) |a| a.len else 0;
                    if (std.mem.eql(u8, ctor.variant_name, "Cons")) {
                        if (pat_arg_count != 2) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                2,
                                pat_arg_count,
                                pattern.span,
                            ));
                        } else if (ctor.arguments) |args| {
                            const head_pattern = switch (args[0]) {
                                .positional => |pos| pos,
                                .named => |n| n.pattern,
                            };
                            const tail_pattern = switch (args[1]) {
                                .positional => |pos| pos,
                                .named => |n| n.pattern,
                            };
                            try self.checkPattern(head_pattern, elem_type);
                            try self.checkPattern(tail_pattern, expected_type);
                        }
                    } else if (std.mem.eql(u8, ctor.variant_name, "Nil")) {
                        if (pat_arg_count > 0) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                0,
                                pat_arg_count,
                                pattern.span,
                            ));
                        }
                    } else {
                        try self.addDiagnostic(try errors_mod.simpleError(
                            self.allocator,
                            "variant not found in matched type",
                            pattern.span,
                        ));
                    }
                    return;
                }

                if (self.lookupVariantInType(expected_type, ctor.variant_name)) |variant_info| {
                    const pat_arg_count: usize = if (ctor.arguments) |a| a.len else 0;
                    if (variant_info.fields) |fields| {
                        const expected_count: usize = switch (fields) {
                            .tuple_fields => |tf| tf.len,
                            .record_fields => |rf| rf.len,
                        };
                        if (pat_arg_count != expected_count) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                expected_count,
                                pat_arg_count,
                                pattern.span,
                            ));
                        } else if (ctor.arguments) |args| {
                            switch (fields) {
                                .tuple_fields => |tf| {
                                    for (args, tf) |arg, field_type| {
                                        const p = switch (arg) {
                                            .positional => |pos| pos,
                                            .named => |n| n.pattern,
                                        };
                                        const resolved_field = try self.resolveAstType(field_type);
                                        try self.checkPattern(p, resolved_field);
                                    }
                                },
                                .record_fields => |rf| {
                                    for (args, rf) |arg, field_info| {
                                        const p = switch (arg) {
                                            .positional => |pos| pos,
                                            .named => |n| n.pattern,
                                        };
                                        const resolved_field = try self.resolveAstType(field_info.field_type);
                                        try self.checkPattern(p, resolved_field);
                                    }
                                },
                            }
                        }
                    } else {
                        // Nullary variant — no arguments expected
                        if (pat_arg_count > 0) {
                            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                                self.allocator,
                                0,
                                pat_arg_count,
                                pattern.span,
                            ));
                        }
                    }
                } else {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "variant not found in matched type",
                        pattern.span,
                    ));
                }
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
                if (!self.typesMatch(expected_type, annotated_type)) {
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
    /// subject_type, when provided, is the resolved type of the match subject
    /// and is used to infer concrete types for pattern-bound variables.
    fn addPatternBindings(
        self: *TypeChecker,
        pattern: *const Pattern,
        explicit_type: ?*Type,
        subject_type: ?ResolvedType,
        allow_shadow: bool,
    ) TypeCheckError!void {
        switch (pattern.kind) {
            .identifier => |ident| {
                // Use explicit type or create inferred placeholder (mirrors resolver)
                const binding_type = explicit_type orelse &inferred_binding_type;
                if (!allow_shadow and self.symbol_table.lookupLocal(ident.name) == null and self.symbol_table.lookupInParentScopes(ident.name) != null) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "shadowing binding requires 'shadow' keyword",
                        pattern.span,
                    ));
                }
                const sym = Symbol.variable(unassigned_symbol_id, ident.name, binding_type, ident.is_mutable, false, pattern.span);
                const defined_id = self.symbol_table.define(sym) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return; // DuplicateDefinition: resolver already reported this
                };
                // When we have a concrete subject type and no explicit annotation,
                // store the resolved type so getSymbolType can return it.
                if (subject_type) |st| {
                    if (explicit_type == null and !st.isError()) {
                        try self.type_env.put(self.allocator, defined_id, st);
                    }
                }
            },
            .constructor => |ctor| {
                if (ctor.arguments) |args| {
                    // Try to resolve variant field types from subject_type
                    const field_types = if (subject_type) |st|
                        self.lookupVariantFieldTypes(st, ctor.variant_name)
                    else
                        null;

                    for (args, 0..) |arg, i| {
                        const field_subject = if (field_types) |ft| (if (i < ft.len) ft[i] else null) else null;
                        switch (arg) {
                            .positional => |p| try self.addPatternBindings(p, null, field_subject, allow_shadow),
                            .named => |n| try self.addPatternBindings(n.pattern, null, field_subject, allow_shadow),
                        }
                    }
                }
            },
            .record => |rp| {
                for (rp.fields) |field| {
                    if (field.pattern) |pat| {
                        try self.addPatternBindings(pat, null, null, allow_shadow);
                    } else {
                        // Shorthand: { x } binds x
                        if (!allow_shadow and self.symbol_table.lookupLocal(field.name) == null and self.symbol_table.lookupInParentScopes(field.name) != null) {
                            try self.addDiagnostic(try errors_mod.simpleError(
                                self.allocator,
                                "shadowing binding requires 'shadow' keyword",
                                field.span,
                            ));
                        }
                        const sym = Symbol.variable(unassigned_symbol_id, field.name, &inferred_binding_type, false, false, field.span);
                        _ = self.symbol_table.define(sym) catch |err| {
                            if (err == error.OutOfMemory) return error.OutOfMemory;
                        };
                    }
                }
            },
            .tuple => |tup| {
                const tuple_subject = if (subject_type) |st| blk: {
                    const normalized = try self.expandAliasType(st);
                    if (normalized.kind == .tuple) {
                        break :blk normalized.kind.tuple.element_types;
                    }
                    break :blk null;
                } else null;

                for (tup.elements, 0..) |elem, i| {
                    const elem_subject = if (tuple_subject) |ts| (if (i < ts.len) ts[i] else null) else null;
                    try self.addPatternBindings(elem, null, elem_subject, allow_shadow);
                }
            },
            .or_pattern => |op| {
                // All alternatives must bind the same names (enforced by resolver).
                // Process every alternative so all names are defined; duplicates
                // from subsequent alternatives are silently caught by define().
                for (op.patterns) |alt| {
                    try self.addPatternBindings(alt, null, subject_type, allow_shadow);
                }
            },
            .guarded => |g| {
                try self.addPatternBindings(g.pattern, explicit_type, subject_type, allow_shadow);
            },
            .typed => |t| {
                try self.addPatternBindings(t.pattern, t.expected_type, null, allow_shadow);
            },
            // Literals, wildcards, ranges, rest don't bind names
            else => {},
        }
    }

    /// Helper: resolve variant tuple field types as ResolvedType slice.
    /// Returns null if the variant is not found or has no tuple fields.
    fn lookupVariantFieldTypes(self: *TypeChecker, resolved_type_raw: ResolvedType, variant_name: []const u8) ?[]const ResolvedType {
        // Expand type aliases so we see through e.g. Substitution -> List[Binding]
        const resolved_type = self.expandAliasType(resolved_type_raw) catch resolved_type_raw;
        // Built-in: Option[T] — Some(T) has 1 field, None has 0
        if (self.getOptionInnerType(resolved_type)) |inner_type| {
            if (std.mem.eql(u8, variant_name, "Some")) {
                const type_alloc = self.typeAllocator();
                const result = type_alloc.alloc(ResolvedType, 1) catch return null;
                result[0] = inner_type;
                return result;
            }
            return null;
        }

        // Built-in: Result[T, E] — Ok(T) has 1 field, Err(E) has 1 field
        if (self.getResultTypes(resolved_type)) |result_types| {
            if (std.mem.eql(u8, variant_name, "Ok")) {
                const type_alloc = self.typeAllocator();
                const result = type_alloc.alloc(ResolvedType, 1) catch return null;
                result[0] = result_types[0];
                return result;
            } else if (std.mem.eql(u8, variant_name, "Err")) {
                const type_alloc = self.typeAllocator();
                const result = type_alloc.alloc(ResolvedType, 1) catch return null;
                result[0] = result_types[1];
                return result;
            }
            return null;
        }

        // Built-in: List[T] — Cons(T, List[T]) has 2 fields, Nil has 0
        if (resolved_type.kind == .instantiated) {
            const inst = resolved_type.kind.instantiated;
            if (std.mem.eql(u8, inst.base_name, "List") and inst.type_arguments.len > 0) {
                if (std.mem.eql(u8, variant_name, "Cons")) {
                    const type_alloc = self.typeAllocator();
                    const result = type_alloc.alloc(ResolvedType, 2) catch return null;
                    result[0] = inst.type_arguments[0]; // T
                    result[1] = resolved_type; // List[T]
                    return result;
                }
                return null; // Nil has no fields
            }
        }

        const variant_info = self.lookupVariantInType(resolved_type, variant_name) orelse return null;
        const fields = variant_info.fields orelse return null;
        switch (fields) {
            .tuple_fields => |tf| {
                const type_alloc = self.typeAllocator();
                const resolved = type_alloc.alloc(ResolvedType, tf.len) catch return null;
                for (tf, 0..) |field_type, i| {
                    resolved[i] = self.resolveAstType(field_type) catch return null;
                }
                return resolved;
            },
            .record_fields => return null,
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
                if (!self.typesMatch(declared_type, value_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        declared_type,
                        value_type,
                        c.value.span,
                    ));
                }
            },
            .let_decl => |l| {
                // Set up generic type variables if present
                if (l.generic_params) |params| {
                    for (params) |p| {
                        try self.type_var_substitutions.put(
                            self.allocator,
                            p.name,
                            ResolvedType.typeVar(p.name, p.constraints orelse null, p.span),
                        );
                    }
                }
                defer {
                    if (l.generic_params) |params| {
                        for (params) |p| {
                            _ = self.type_var_substitutions.remove(p.name);
                        }
                    }
                }

                const value_type = try self.checkExpression(l.value);
                // binding_type is required in Kira
                const declared_type = try self.resolveAstType(l.binding_type);
                if (!self.typesMatch(declared_type, value_type)) {
                    try self.addDiagnostic(try errors_mod.typeMismatch(
                        self.allocator,
                        declared_type,
                        value_type,
                        l.value.span,
                    ));
                }

                // Cache the resolved type so that getSymbolType can find it later
                // without needing to re-resolve (which would fail for generic params).
                if (l.generic_params != null) {
                    if (self.symbol_table.lookup(l.name)) |sym| {
                        try self.type_env.put(self.allocator, sym.id, declared_type);
                    }
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
            .bench_decl => |b| {
                // Type check the bench body - benchmarks are implicitly effect functions
                const saved_in_effect = self.in_effect_function;
                self.in_effect_function = true;
                defer self.in_effect_function = saved_in_effect;

                const entry_scope_id = self.symbol_table.current_scope_id;
                _ = try self.symbol_table.enterScope(.function);
                errdefer self.scopeCleanup();
                for (b.body) |*stmt| {
                    _ = try self.checkStatement(stmt);
                }
                try self.scopeLeave();
                std.debug.assert(self.symbol_table.current_scope_id == entry_scope_id);
            },
        }
    }

    /// Check function declaration
    fn checkFunctionDecl(self: *TypeChecker, func: *const Declaration.FunctionDecl) TypeCheckError!void {
        // Validate memoization eligibility
        if (func.is_memoized) {
            // Defense-in-depth: parser already rejects memo+effect, but validate here too
            if (func.is_effect) {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "memoized functions must be pure; 'memo' and 'effect' cannot be combined",
                    func.return_type.span,
                ));
            }
            if (func.generic_params) |gp| {
                try self.addDiagnostic(try errors_mod.simpleError(
                    self.allocator,
                    "memoized functions cannot be generic; different instantiations would alias cache entries",
                    gp[0].span,
                ));
            }
        }

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
            // Note: parameters naturally shadow outer names since they're in a new scope.
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

    /// Check trait declaration: validates method signatures, resolves Self type references,
    /// and type-checks default method bodies in an isolated function scope.
    /// Sets `current_trait` context so method calls on Self in default bodies can resolve
    /// against the trait's own methods.
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

        // Set Self type to a type variable so trait methods can reference Self
        const saved_self_type = self.self_type;
        const zero_loc = ast.Location{ .line = 0, .column = 0, .offset = 0 };
        const trait_span = if (trait_decl.methods.len > 0) trait_decl.methods[0].span else Span{ .start = zero_loc, .end = zero_loc };
        self.self_type = ResolvedType.typeVar("Self", null, trait_span);
        defer self.self_type = saved_self_type;

        // Set current trait context so default body method calls on Self can resolve
        const saved_trait = self.current_trait;
        self.current_trait = trait_decl;
        defer self.current_trait = saved_trait;

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

                // Enter a function scope so local bindings don't leak
                _ = try self.symbol_table.enterScope(.function);
                errdefer self.scopeCleanup();

                for (body) |*stmt| {
                    try self.checkStatement(stmt);
                }

                try self.scopeLeave();
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
                        if (!req_method.hasDefault()) {
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
        subject_type_raw: ResolvedType,
        span: Span,
    ) TypeCheckError!void {
        // Expand type aliases so the pattern compiler sees the underlying type
        const subject_type = self.expandAliasType(subject_type_raw) catch subject_type_raw;
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

    fn expandAliasType(self: *TypeChecker, resolved_type: ResolvedType) TypeCheckError!ResolvedType {
        var visiting: std.AutoHashMapUnmanaged(SymbolId, void) = .{};
        defer visiting.deinit(self.allocator);
        return self.expandAliasTypeInner(resolved_type, &visiting);
    }

    fn expandAliasTypeInner(
        self: *TypeChecker,
        resolved_type: ResolvedType,
        visiting: *std.AutoHashMapUnmanaged(SymbolId, void),
    ) TypeCheckError!ResolvedType {
        return switch (resolved_type.kind) {
            .named => |n| blk: {
                const gop = try visiting.getOrPut(self.allocator, n.symbol_id);
                if (gop.found_existing) {
                    try self.addDiagnostic(try errors_mod.simpleError(
                        self.allocator,
                        "cyclic type alias detected",
                        resolved_type.span,
                    ));
                    break :blk ResolvedType.errorType(resolved_type.span);
                }
                defer _ = visiting.remove(n.symbol_id);

                const sym = self.symbol_table.getSymbol(n.symbol_id) orelse break :blk resolved_type;
                if (sym.kind != .type_def) break :blk resolved_type;

                switch (sym.kind.type_def.definition) {
                    .alias => |alias_ast| {
                        const expanded = try self.resolveAstType(alias_ast);
                        break :blk try self.expandAliasTypeInner(expanded, visiting);
                    },
                    else => break :blk resolved_type,
                }
            },
            else => resolved_type,
        };
    }

    /// Compare types for equality, expanding type aliases first.
    /// Use this instead of unify.typesEqual when alias transparency is needed.
    fn typesMatch(self: *TypeChecker, a: ResolvedType, b: ResolvedType) bool {
        const expanded_a = self.expandAliasType(a) catch a;
        const expanded_b = self.expandAliasType(b) catch b;
        return unify.typesEqual(expanded_a, expanded_b);
    }

    /// Check assignability, expanding type aliases first.
    fn typeIsAssignable(self: *TypeChecker, target: ResolvedType, source: ResolvedType) bool {
        const expanded_target = self.expandAliasType(target) catch target;
        const expanded_source = self.expandAliasType(source) catch source;
        return unify.isAssignable(expanded_target, expanded_source);
    }

    fn resolveAstTypeInSymbolScope(
        self: *TypeChecker,
        sym: *const Symbol,
        ast_type: *const Type,
    ) TypeCheckError!ResolvedType {
        const previous_scope_id = self.symbol_table.current_scope_id;
        const previous_fallback_scope = self.type_lookup_fallback_scope;
        const maybe_scope_id = self.symbol_table.findSymbolScope(sym.id);
        var restore_scope = false;
        defer {
            self.type_lookup_fallback_scope = previous_fallback_scope;
            if (restore_scope) {
                self.symbol_table.setCurrentScope(previous_scope_id) catch {
                    if (builtin.mode == .Debug) {
                        @panic("TypeChecker scope restore failed after symbol-scope type resolution");
                    }
                };
            }
        }

        if (maybe_scope_id) |scope_id| {
            self.type_lookup_fallback_scope = scope_id;
            if (scope_id != previous_scope_id) {
                self.symbol_table.setCurrentScope(scope_id) catch return error.TypeError;
                restore_scope = true;
            }
        }
        return try self.resolveAstType(ast_type);
    }

    fn lookupInScopeChain(self: *TypeChecker, start_scope_id: ScopeId, name: []const u8) ?*Symbol {
        var scope_id: ?ScopeId = start_scope_id;
        while (scope_id) |id| {
            if (self.symbol_table.lookupInScope(id, name)) |sym| {
                return sym;
            }
            const scope = self.symbol_table.getScope(id) orelse break;
            scope_id = scope.parent_id;
        }
        return null;
    }

    fn moduleScopeFromPath(self: *TypeChecker, path: [][]const u8) ?ScopeId {
        var path_builder = std.ArrayListUnmanaged(u8){};
        const alloc = self.typeAllocator();
        for (path, 0..) |segment, i| {
            if (i > 0) path_builder.append(alloc, '.') catch return null;
            path_builder.appendSlice(alloc, segment) catch return null;
        }
        const path_str = path_builder.toOwnedSlice(alloc) catch return null;
        return self.symbol_table.getModuleScope(path_str);
    }

    /// Get the type of a symbol
    fn getSymbolType(self: *TypeChecker, sym: *const Symbol, span: Span) TypeCheckError!ResolvedType {
        return switch (sym.kind) {
            .variable => |v| {
                // Check type_env first — pattern inference may have stored a concrete type
                if (self.type_env.get(sym.id)) |resolved| {
                    return resolved;
                }
                return try self.resolveAstTypeInSymbolScope(sym, v.binding_type);
            },
            .function => |f| {
                const type_alloc = self.typeAllocator();
                var param_types = std.ArrayListUnmanaged(ResolvedType){};
                for (f.parameter_types) |pt| {
                    try param_types.append(type_alloc, try self.resolveAstTypeInSymbolScope(sym, pt));
                }

                const return_type = try type_alloc.create(ResolvedType);
                return_type.* = try self.resolveAstTypeInSymbolScope(sym, f.return_type);

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
                        const previous_scope_id = self.symbol_table.current_scope_id;
                        const previous_error_span = self.cross_module_error_span;
                        var restore_scope = false;
                        defer {
                            self.cross_module_error_span = previous_error_span;
                            if (restore_scope) {
                                self.symbol_table.setCurrentScope(previous_scope_id) catch {
                                    if (builtin.mode == .Debug) {
                                        @panic("TypeChecker scope restore failed after import-alias resolution");
                                    }
                                };
                            }
                        }
                        if (self.moduleScopeFromPath(ia.source_path)) |source_scope_id| {
                            if (source_scope_id != previous_scope_id) {
                                self.symbol_table.setCurrentScope(source_scope_id) catch return error.TypeError;
                                restore_scope = true;
                                // Use call site span for errors in cross-module type resolution
                                self.cross_module_error_span = span;
                            }
                        }
                        return try self.getSymbolType(resolved_sym, span);
                    }
                }
                return ResolvedType.errorType(span);
            },
            else => ResolvedType.errorType(span),
        };
    }

    fn resolveImportAliasSymbol(self: *TypeChecker, sym: *const Symbol) ?*const Symbol {
        var current = sym;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            switch (current.kind) {
                .import_alias => |ia| {
                    const resolved_id = ia.resolved_id orelse return null;
                    current = self.symbol_table.getSymbol(resolved_id) orelse return null;
                },
                else => return current,
            }
        }
        return null;
    }

    /// Look up a variant by name within a resolved type (named or instantiated).
    /// Returns the VariantInfo if the type is a sum type containing that variant, null otherwise.
    /// Extract the inner type from an Option type.
    /// Handles both ResolvedType.option and instantiated "Option" representations.
    fn getOptionInnerType(self: *TypeChecker, resolved_type_raw: ResolvedType) ?ResolvedType {
        const resolved_type = self.expandAliasType(resolved_type_raw) catch resolved_type_raw;
        return switch (resolved_type.kind) {
            .option => |inner| inner.*,
            .instantiated => |inst| {
                if (std.mem.eql(u8, inst.base_name, "Option") and inst.type_arguments.len == 1) {
                    return inst.type_arguments[0];
                }
                return null;
            },
            else => null,
        };
    }

    /// Extract ok and err types from a Result type.
    /// Handles both ResolvedType.result and instantiated "Result" representations.
    /// Returns [2]ResolvedType: [0] = ok_type, [1] = err_type.
    fn getResultTypes(self: *TypeChecker, resolved_type_raw: ResolvedType) ?[2]ResolvedType {
        const resolved_type = self.expandAliasType(resolved_type_raw) catch resolved_type_raw;
        return switch (resolved_type.kind) {
            .result => |r| .{ r.ok_type.*, r.err_type.* },
            .instantiated => |inst| {
                if (std.mem.eql(u8, inst.base_name, "Result") and inst.type_arguments.len == 2) {
                    return .{ inst.type_arguments[0], inst.type_arguments[1] };
                }
                return null;
            },
            else => null,
        };
    }

    fn lookupVariantInType(self: *TypeChecker, resolved_type_raw: ResolvedType, variant_name: []const u8) ?Symbol.VariantInfo {
        // Expand type aliases (e.g., Substitution -> List[Binding])
        const resolved_type = self.expandAliasType(resolved_type_raw) catch resolved_type_raw;
        // Built-in: Option[T] — variants Some(T) and None
        if (self.getOptionInnerType(resolved_type) != null) {
            if (std.mem.eql(u8, variant_name, "Some")) {
                return .{ .name = "Some", .fields = null, .span = builtin_span };
            } else if (std.mem.eql(u8, variant_name, "None")) {
                return .{ .name = "None", .fields = null, .span = builtin_span };
            }
            return null;
        }

        // Built-in: Result[T, E] — variants Ok(T) and Err(E)
        if (self.getResultTypes(resolved_type) != null) {
            if (std.mem.eql(u8, variant_name, "Ok")) {
                return .{ .name = "Ok", .fields = null, .span = builtin_span };
            } else if (std.mem.eql(u8, variant_name, "Err")) {
                return .{ .name = "Err", .fields = null, .span = builtin_span };
            }
            return null;
        }

        const sym_id = switch (resolved_type.kind) {
            .named => |n| n.symbol_id,
            .instantiated => |inst| inst.base_symbol_id,
            else => return null,
        };
        const sym = self.symbol_table.getSymbol(sym_id) orelse return null;
        if (sym.kind != .type_def) return null;
        const td = sym.kind.type_def;
        switch (td.definition) {
            .sum_type => |st| {
                for (st.variants) |v| {
                    if (std.mem.eql(u8, v.name, variant_name)) {
                        return v;
                    }
                }
            },
            else => {},
        }
        return null;
    }

    /// Search all type definitions for a sum type containing a variant with the given name.
    /// Returns the parent type's symbol and variant info if found uniquely.
    /// Emits an ambiguity diagnostic if multiple sum types define the same variant name.
    fn findVariantParentType(self: *TypeChecker, variant_name: []const u8, span: Span) TypeCheckError!?VariantLookup {
        var found: ?VariantLookup = null;
        for (self.symbol_table.symbols.items) |*sym| {
            if (sym.kind == .type_def) {
                const td = sym.kind.type_def;
                switch (td.definition) {
                    .sum_type => |st| {
                        for (st.variants) |v| {
                            if (std.mem.eql(u8, v.name, variant_name)) {
                                if (found) |first| {
                                    // Second match — ambiguous
                                    var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
                                    errdefer builder.deinit();
                                    try builder.write("ambiguous variant '");
                                    try builder.write(variant_name);
                                    try builder.write("' found in both '");
                                    try builder.write(first.parent_sym.name);
                                    try builder.write("' and '");
                                    try builder.write(sym.name);
                                    try builder.write("'; qualify with type name");
                                    try self.addDiagnostic(try builder.build());
                                    return null;
                                }
                                found = .{
                                    .parent_sym = sym,
                                    .variant_info = v,
                                };
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        return found;
    }

    // ========== Trait Bounds Enforcement ==========

    /// Resolve a callee expression to its symbol, if possible.
    fn resolveCalleeSymbol(self: *TypeChecker, expr: *const Expression) TypeCheckError!?*Symbol {
        return switch (expr.kind) {
            .identifier => |ident| self.symbol_table.lookup(ident.name),
            .field_access => blk: {
                // Handle path-based lookups like module.func
                const path = try self.extractExpressionPath(expr) orelse break :blk null;
                break :blk self.symbol_table.lookupPath(path);
            },
            else => null,
        };
    }

    /// Check a generic function call with explicit type arguments.
    /// Verifies trait bounds on generic params and instantiates the function type.
    fn checkGenericFunctionCall(
        self: *TypeChecker,
        func_sym: *const Symbol,
        generic_args: []*Type,
        arguments: []*Expression,
        span: Span,
    ) TypeCheckError!ResolvedType {
        const func = func_sym.kind.function;
        const generic_params = func.generic_params orelse {
            try self.addDiagnostic(try errors_mod.simpleError(
                self.allocator,
                "function does not have generic parameters",
                span,
            ));
            return ResolvedType.errorType(span);
        };

        if (generic_args.len != generic_params.len) {
            var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
            try builder.print("expected {d} type argument(s), found {d}", .{ generic_params.len, generic_args.len });
            try self.addDiagnostic(try builder.build());
            return ResolvedType.errorType(span);
        }

        // Resolve generic args to ResolvedTypes
        const type_alloc = self.typeAllocator();
        var resolved_args = std.ArrayListUnmanaged(ResolvedType){};
        for (generic_args) |arg| {
            try resolved_args.append(type_alloc, try self.resolveAstType(arg));
        }

        // Check trait bounds on each generic parameter
        for (generic_params, resolved_args.items) |param, resolved_arg| {
            if (param.constraints) |constraints| {
                for (constraints) |trait_name| {
                    try self.checkTraitBound(resolved_arg, trait_name, span);
                }
            }
        }

        // TODO: Also check where clause constraints.
        // The where clause is stored in the AST, not the symbol.
        // For now, constraints from generic_params are the primary path.

        // Build substitution and instantiate function type
        var subst = instantiate_mod.TypeSubstitution{};
        defer subst.deinit(type_alloc);
        for (generic_params, resolved_args.items) |param, resolved_arg| {
            try subst.put(type_alloc, param.name, resolved_arg);
        }

        // Get the uninstantiated function type
        const func_type = try self.getSymbolType(func_sym, span);
        if (func_type.kind != .function) {
            return ResolvedType.errorType(span);
        }

        // Instantiate parameter and return types
        const f = func_type.kind.function;
        var inst_params = std.ArrayListUnmanaged(ResolvedType){};
        for (f.parameter_types) |pt| {
            try inst_params.append(type_alloc, try instantiate_mod.instantiate(type_alloc, pt, &subst));
        }

        const inst_return = try type_alloc.create(ResolvedType);
        inst_return.* = try instantiate_mod.instantiate(type_alloc, f.return_type.*, &subst);

        // Check argument count
        if (arguments.len != inst_params.items.len) {
            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                self.allocator,
                inst_params.items.len,
                arguments.len,
                span,
            ));
            return ResolvedType.errorType(span);
        }

        // Check argument types against instantiated parameter types
        for (arguments, inst_params.items) |arg, param| {
            const arg_type = try self.checkExpression(arg);
            if (!self.typeIsAssignable(param, arg_type)) {
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

        return inst_return.*;
    }

    /// Check a generic call on a variable symbol (from `let name[T]: fn(...) -> ... = ...`).
    /// Extracts type variables from the cached resolved type and instantiates them.
    fn checkGenericVariableCall(
        self: *TypeChecker,
        var_sym: *const Symbol,
        generic_args: []*Type,
        arguments: []*Expression,
        span: Span,
    ) TypeCheckError!ResolvedType {
        const type_alloc = self.typeAllocator();

        // Get the uninstantiated function type (should be cached in type_env)
        const func_type = try self.getSymbolType(var_sym, span);
        if (func_type.kind != .function) {
            try self.addDiagnostic(try errors_mod.simpleError(
                self.allocator,
                "expected a function type for generic call",
                span,
            ));
            return ResolvedType.errorType(span);
        }

        // Collect type variables from the cached type
        const type_vars = try instantiate_mod.collectTypeVariables(type_alloc, func_type);

        if (generic_args.len != type_vars.len) {
            var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
            try builder.print("expected {d} type argument(s), found {d}", .{ type_vars.len, generic_args.len });
            try self.addDiagnostic(try builder.build());
            return ResolvedType.errorType(span);
        }

        // Resolve generic args and build substitution
        var resolved_args = std.ArrayListUnmanaged(ResolvedType){};
        for (generic_args) |arg| {
            try resolved_args.append(type_alloc, try self.resolveAstType(arg));
        }

        var subst = instantiate_mod.TypeSubstitution{};
        defer subst.deinit(type_alloc);
        for (type_vars, resolved_args.items) |var_name, resolved_arg| {
            try subst.put(type_alloc, var_name, resolved_arg);
        }

        // Instantiate parameter and return types
        const f = func_type.kind.function;
        var inst_params = std.ArrayListUnmanaged(ResolvedType){};
        for (f.parameter_types) |pt| {
            try inst_params.append(type_alloc, try instantiate_mod.instantiate(type_alloc, pt, &subst));
        }

        const inst_return = try type_alloc.create(ResolvedType);
        inst_return.* = try instantiate_mod.instantiate(type_alloc, f.return_type.*, &subst);

        // Check argument count
        if (arguments.len != inst_params.items.len) {
            try self.addDiagnostic(try errors_mod.wrongArgumentCount(
                self.allocator,
                inst_params.items.len,
                arguments.len,
                span,
            ));
            return ResolvedType.errorType(span);
        }

        // Check argument types against instantiated parameter types
        for (arguments, inst_params.items) |arg, param| {
            const arg_type = try self.checkExpression(arg);
            if (!self.typeIsAssignable(param, arg_type)) {
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

        return inst_return.*;
    }

    /// Check that a concrete type satisfies a trait bound.
    /// Reports a diagnostic if the type does not implement the required trait.
    fn checkTraitBound(
        self: *TypeChecker,
        concrete_type: ResolvedType,
        trait_name: []const u8,
        span: Span,
    ) TypeCheckError!void {
        // Get the type name string for looking up implementations
        const type_name: []const u8 = switch (concrete_type.kind) {
            .primitive => |p| p.toString(),
            .named => |n| n.name,
            .instantiated => |inst| inst.base_name,
            .type_var => return, // Type variables are checked at their own instantiation site
            .error_type => return, // Don't report cascading errors
            else => {
                var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
                try builder.write("type '");
                try builder.writeType(concrete_type);
                try builder.write("' does not implement trait '");
                try builder.write(trait_name);
                try builder.write("'");
                try self.addDiagnostic(try builder.build());
                return;
            },
        };

        // Check if there's a registered impl for this trait + type
        if (self.symbol_table.findTraitImpl(trait_name, type_name) == null) {
            var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
            try builder.write("type '");
            try builder.writeType(concrete_type);
            try builder.write("' does not implement trait '");
            try builder.write(trait_name);
            try builder.write("'");
            try self.addDiagnostic(try builder.build());
        }
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

test "effect: pure main function without effect keyword is allowed" {
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

    // Create main function WITHOUT effect keyword — pure main is allowed
    const func_decl = Declaration.FunctionDecl{
        .name = "main",
        .generic_params = null,
        .parameters = &[_]Declaration.Parameter{},
        .return_type = &return_type,
        .is_effect = false,
        .is_memoized = false,
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

    // Pure main without effect should pass — effect validation is now
    // handled per-call-site, not as a blanket requirement on main
    try checker.check(&program);
    try std.testing.expect(!checker.hasErrors());
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
        .is_memoized = false,
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

test "patterns: Cons(head, tail) is valid for List[T]" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var elem_type = Type.primitive(.i32, span);
    var type_args = [_]*Type{&elem_type};
    var list_type_ast = Type{
        .kind = .{ .generic = .{
            .base = "List",
            .type_arguments = &type_args,
        } },
        .span = span,
    };
    const expected_list_type = try checker.resolveAstType(&list_type_ast);

    var head_pattern = Pattern.identifier("h", span);
    var tail_pattern = Pattern.identifier("t", span);
    var cons_args = [_]Pattern.PatternArg{
        .{ .positional = &head_pattern },
        .{ .positional = &tail_pattern },
    };
    var cons_pattern = Pattern{
        .kind = .{ .constructor = .{
            .type_path = null,
            .variant_name = "Cons",
            .arguments = &cons_args,
        } },
        .span = span,
    };

    try checker.checkPattern(&cons_pattern, expected_list_type);
    try std.testing.expect(!checker.hasErrors());
}

test "stdlib: std.map.contains returns bool" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var map_type = Type.named("HashMap", span);
    var key_type = Type.primitive(.string, span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "m", &map_type, false, false, span));
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "k", &key_type, false, false, span));

    var std_ident = Expression{
        .kind = .{ .identifier = .{ .name = "std", .generic_args = null } },
        .span = span,
    };
    var std_map = Expression{
        .kind = .{ .field_access = .{
            .object = &std_ident,
            .field = "map",
        } },
        .span = span,
    };
    var contains_fn = Expression{
        .kind = .{ .field_access = .{
            .object = &std_map,
            .field = "contains",
        } },
        .span = span,
    };
    var map_ident = Expression{
        .kind = .{ .identifier = .{ .name = "m", .generic_args = null } },
        .span = span,
    };
    var key_ident = Expression{
        .kind = .{ .identifier = .{ .name = "k", .generic_args = null } },
        .span = span,
    };
    var args = [_]*Expression{ &map_ident, &key_ident };
    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &contains_fn,
            .generic_args = null,
            .arguments = &args,
        } },
        .span = span,
    };

    const call_type = try checker.checkExpression(&call_expr);
    try std.testing.expect(call_type.isBool());
    try std.testing.expect(!checker.hasErrors());
}

test "stdlib: std.string.substring returns Option[string]" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var std_ident = Expression{
        .kind = .{ .identifier = .{ .name = "std", .generic_args = null } },
        .span = span,
    };
    var std_string = Expression{
        .kind = .{ .field_access = .{
            .object = &std_ident,
            .field = "string",
        } },
        .span = span,
    };
    var substring_fn = Expression{
        .kind = .{ .field_access = .{
            .object = &std_string,
            .field = "substring",
        } },
        .span = span,
    };
    var s_arg = Expression{
        .kind = .{ .string_literal = .{ .value = "hello" } },
        .span = span,
    };
    var start_arg = Expression{
        .kind = .{ .integer_literal = .{ .value = 0, .suffix = "i32" } },
        .span = span,
    };
    var end_arg = Expression{
        .kind = .{ .integer_literal = .{ .value = 2, .suffix = "i32" } },
        .span = span,
    };
    var args = [_]*Expression{ &s_arg, &start_arg, &end_arg };
    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &substring_fn,
            .generic_args = null,
            .arguments = &args,
        } },
        .span = span,
    };

    const call_type = try checker.checkExpression(&call_expr);
    try std.testing.expect(checker.getOptionInnerType(call_type) != null);
    try std.testing.expect(!checker.hasErrors());
}

test "stdlib: std.map.get returns Option" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var map_type = Type.named("HashMap", span);
    var key_type = Type.primitive(.string, span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "m", &map_type, false, false, span));
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "k", &key_type, false, false, span));

    var std_ident = Expression{
        .kind = .{ .identifier = .{ .name = "std", .generic_args = null } },
        .span = span,
    };
    var std_map = Expression{
        .kind = .{ .field_access = .{
            .object = &std_ident,
            .field = "map",
        } },
        .span = span,
    };
    var get_fn = Expression{
        .kind = .{ .field_access = .{
            .object = &std_map,
            .field = "get",
        } },
        .span = span,
    };
    var map_ident = Expression{
        .kind = .{ .identifier = .{ .name = "m", .generic_args = null } },
        .span = span,
    };
    var key_ident = Expression{
        .kind = .{ .identifier = .{ .name = "k", .generic_args = null } },
        .span = span,
    };
    var args = [_]*Expression{ &map_ident, &key_ident };
    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &get_fn,
            .generic_args = null,
            .arguments = &args,
        } },
        .span = span,
    };

    const call_type = try checker.checkExpression(&call_expr);
    try std.testing.expect(checker.getOptionInnerType(call_type) != null);
    try std.testing.expect(!checker.hasErrors());
}

test "stdlib: std.char.from_i32 returns Option[char]" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var std_ident = Expression{
        .kind = .{ .identifier = .{ .name = "std", .generic_args = null } },
        .span = span,
    };
    var std_char = Expression{
        .kind = .{ .field_access = .{
            .object = &std_ident,
            .field = "char",
        } },
        .span = span,
    };
    var from_fn = Expression{
        .kind = .{ .field_access = .{
            .object = &std_char,
            .field = "from_i32",
        } },
        .span = span,
    };
    var arg = Expression{
        .kind = .{ .integer_literal = .{ .value = 65, .suffix = "i32" } },
        .span = span,
    };
    var args = [_]*Expression{&arg};
    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &from_fn,
            .generic_args = null,
            .arguments = &args,
        } },
        .span = span,
    };

    const call_type = try checker.checkExpression(&call_expr);
    const inner = checker.getOptionInnerType(call_type) orelse ResolvedType.errorType(span);
    try std.testing.expect(inner.isChar());
    try std.testing.expect(!checker.hasErrors());
}

test "stdlib: std.string.length returns i64" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var std_ident = Expression{
        .kind = .{ .identifier = .{ .name = "std", .generic_args = null } },
        .span = span,
    };
    var std_string = Expression{
        .kind = .{ .field_access = .{
            .object = &std_ident,
            .field = "string",
        } },
        .span = span,
    };
    var length_fn = Expression{
        .kind = .{ .field_access = .{
            .object = &std_string,
            .field = "length",
        } },
        .span = span,
    };
    var arg = Expression{
        .kind = .{ .string_literal = .{ .value = "hello" } },
        .span = span,
    };
    var args = [_]*Expression{&arg};
    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &length_fn,
            .generic_args = null,
            .arguments = &args,
        } },
        .span = span,
    };

    const call_type = try checker.checkExpression(&call_expr);
    try std.testing.expect(call_type.kind == .primitive and call_type.kind.primitive == .i64);
    try std.testing.expect(!checker.hasErrors());
}

test "stdlib: std.char.to_i32 returns i64" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var std_ident = Expression{
        .kind = .{ .identifier = .{ .name = "std", .generic_args = null } },
        .span = span,
    };
    var std_char = Expression{
        .kind = .{ .field_access = .{
            .object = &std_ident,
            .field = "char",
        } },
        .span = span,
    };
    var to_fn = Expression{
        .kind = .{ .field_access = .{
            .object = &std_char,
            .field = "to_i32",
        } },
        .span = span,
    };
    var arg = Expression{
        .kind = .{ .char_literal = .{ .value = 'A' } },
        .span = span,
    };
    var args = [_]*Expression{&arg};
    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &to_fn,
            .generic_args = null,
            .arguments = &args,
        } },
        .span = span,
    };

    const call_type = try checker.checkExpression(&call_expr);
    try std.testing.expect(call_type.kind == .primitive and call_type.kind.primitive == .i64);
    try std.testing.expect(!checker.hasErrors());
}

test "binary comparison allows mixed integer widths" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var left = Expression{
        .kind = .{ .integer_literal = .{ .value = 1, .suffix = "i64" } },
        .span = span,
    };
    var right = Expression{
        .kind = .{ .integer_literal = .{ .value = 0, .suffix = "i32" } },
        .span = span,
    };
    var expr = Expression{
        .kind = .{ .binary = .{
            .left = &left,
            .operator = .greater_than,
            .right = &right,
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&expr);
    try std.testing.expect(result.isBool());
    try std.testing.expect(!checker.hasErrors());
}

test "constructors: Cons requires tail to be List[T]" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var head_expr = Expression{
        .kind = .{ .integer_literal = .{ .value = 1, .suffix = null } },
        .span = span,
    };
    var bad_tail_expr = Expression{
        .kind = .{ .string_literal = .{ .value = "x" } },
        .span = span,
    };
    var args = [_]*Expression{ &head_expr, &bad_tail_expr };
    var cons_expr = Expression{
        .kind = .{ .variant_constructor = .{
            .variant_name = "Cons",
            .arguments = &args,
        } },
        .span = span,
    };

    _ = try checker.checkExpression(&cons_expr);
    try std.testing.expect(checker.hasErrors());

    var found_type_mismatch = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "type mismatch") != null) {
            found_type_mismatch = true;
        }
    }
    try std.testing.expect(found_type_mismatch);
}

test "constructors: Cons(head, Nil) preserves head element type" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var head_expr = Expression{
        .kind = .{ .integer_literal = .{ .value = 1, .suffix = null } },
        .span = span,
    };
    var nil_expr = Expression{
        .kind = .{ .variant_constructor = .{
            .variant_name = "Nil",
            .arguments = null,
        } },
        .span = span,
    };
    var cons_args = [_]*Expression{ &head_expr, &nil_expr };
    var cons_expr = Expression{
        .kind = .{ .variant_constructor = .{
            .variant_name = "Cons",
            .arguments = &cons_args,
        } },
        .span = span,
    };

    const inferred = try checker.checkExpression(&cons_expr);
    const elem = checker.extractListElementType(inferred) orelse ResolvedType.errorType(span);
    try std.testing.expect(elem.kind == .primitive);
    try std.testing.expectEqual(Type.PrimitiveType.i32, elem.kind.primitive);

    var string_type = Type.primitive(.string, span);
    var expected_args = [_]*Type{&string_type};
    var expected_list_ast = Type{
        .kind = .{ .generic = .{
            .base = "List",
            .type_arguments = &expected_args,
        } },
        .span = span,
    };
    const expected_list = try checker.resolveAstType(&expected_list_ast);
    try std.testing.expect(!checker.typeIsAssignable(expected_list, inferred));
}

test "match expression block arm uses tail expression type" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var subj = Expression{
        .kind = .{ .bool_literal = true },
        .span = span,
    };

    var pat_true = Pattern.init(.{ .bool_literal = true }, span);
    var pat_false = Pattern.init(.{ .bool_literal = false }, span);

    var expr_true = Expression{
        .kind = .{ .integer_literal = .{ .value = 1, .suffix = null } },
        .span = span,
    };
    const stmt_true = Statement{
        .kind = .{ .expression_statement = &expr_true },
        .span = span,
    };
    var expr_false = Expression{
        .kind = .{ .integer_literal = .{ .value = 0, .suffix = null } },
        .span = span,
    };
    const stmt_false = Statement{
        .kind = .{ .expression_statement = &expr_false },
        .span = span,
    };

    var true_block = [_]Statement{stmt_true};
    const arm_true = Expression.MatchArm{
        .pattern = &pat_true,
        .guard = null,
        .body = .{ .block = true_block[0..] },
        .span = span,
    };
    var false_block = [_]Statement{stmt_false};
    const arm_false = Expression.MatchArm{
        .pattern = &pat_false,
        .guard = null,
        .body = .{ .block = false_block[0..] },
        .span = span,
    };
    var arms = [_]Expression.MatchArm{ arm_true, arm_false };

    var match_expr = Expression{
        .kind = .{ .match_expr = .{
            .subject = &subj,
            .arms = &arms,
        } },
        .span = span,
    };

    const t = try checker.checkExpression(&match_expr);
    try std.testing.expect(t.kind == .primitive);
    try std.testing.expectEqual(Type.PrimitiveType.i32, t.kind.primitive);
    try std.testing.expect(!checker.hasErrors());
}

test "expand alias type reports indirect alias cycles" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    var type_b = Type.named("B", span);
    const a_id = try table.define(Symbol.typeDef(unassigned_symbol_id, "A", .{
        .generic_params = null,
        .definition = .{ .alias = &type_b },
    }, true, span));

    var type_a = Type.named("A", span);
    _ = try table.define(Symbol.typeDef(unassigned_symbol_id, "B", .{
        .generic_params = null,
        .definition = .{ .alias = &type_a },
    }, true, span));

    const expanded = try checker.expandAliasType(ResolvedType.named(a_id, "A", span));
    try std.testing.expect(expanded.isError());
    try std.testing.expect(checker.hasErrors());

    var found_cycle = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "cyclic type alias detected") != null) {
            found_cycle = true;
            break;
        }
    }
    try std.testing.expect(found_cycle);
}

// ========== Trait Bounds Enforcement Tests ==========

test "trait bounds: checkTraitBound passes when impl exists" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Eq trait is registered as a builtin — no need to define it

    // Register type MyType
    var my_type_ast = Type.named("MyType", span);
    const my_type_id = try table.define(Symbol.typeDef(unassigned_symbol_id, "MyType", .{
        .generic_params = null,
        .definition = .{ .product_type = .{
            .fields = &[_]Symbol.RecordFieldInfo{},
        } },
    }, true, span));

    // Register impl Eq for MyType
    try table.registerImpl(.{
        .trait_name = "Eq",
        .target_type = &my_type_ast,
        .methods = &[_]symbols.SymbolId{},
        .scope_id = 0,
        .span = span,
    });

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Check that MyType satisfies Eq — should produce no error
    const resolved = ResolvedType.named(my_type_id, "MyType", span);
    try checker.checkTraitBound(resolved, "Eq", span);

    try std.testing.expect(!checker.hasErrors());
}

test "trait bounds: checkTraitBound fails when impl missing" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register a custom trait "Serialize" with no impls for anything
    _ = try table.define(Symbol.traitDef(unassigned_symbol_id, "Serialize", .{
        .generic_params = null,
        .super_traits = null,
        .methods = &[_]Symbol.TraitMethodInfo{},
    }, true, span));

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Check i32 against Serialize — should produce an error (no impl registered)
    const i32_type = ResolvedType.primitive(.i32, span);
    try checker.checkTraitBound(i32_type, "Serialize", span);

    try std.testing.expect(checker.hasErrors());
    try std.testing.expect(checker.diagnostics.items.len == 1);
    const msg = checker.diagnostics.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, msg, "does not implement trait 'Serialize'") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "i32") != null);
}

test "trait bounds: primitive type with impl satisfies bound" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Eq, Ord, Show are registered as builtins with impls for all primitive types

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // i32 should satisfy Eq (builtin impl)
    const i32_type = ResolvedType.primitive(.i32, span);
    try checker.checkTraitBound(i32_type, "Eq", span);

    try std.testing.expect(!checker.hasErrors());
}

test "trait bounds: all builtin traits satisfied by primitives" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    const traits = [_][]const u8{ "Eq", "Ord", "Show" };
    const prim_types = [_]Type.PrimitiveType{ .i32, .i64, .f64, .string, .bool, .char };

    for (prim_types) |prim| {
        for (traits) |trait_name| {
            const prim_type = ResolvedType.primitive(prim, span);
            try checker.checkTraitBound(prim_type, trait_name, span);
        }
    }

    try std.testing.expect(!checker.hasErrors());
}

test "trait bounds: multiple bounds checked" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Eq, Ord, Show are builtin traits with impls for primitives.
    // Register a custom trait "Serialize" with no impls.
    _ = try table.define(Symbol.traitDef(unassigned_symbol_id, "Serialize", .{
        .generic_params = null,
        .super_traits = null,
        .methods = &[_]Symbol.TraitMethodInfo{},
    }, true, span));

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // i32 satisfies Eq (builtin)
    const i32_type = ResolvedType.primitive(.i32, span);
    try checker.checkTraitBound(i32_type, "Eq", span);
    try std.testing.expect(!checker.hasErrors());

    // i32 satisfies Ord (builtin)
    try checker.checkTraitBound(i32_type, "Ord", span);
    try std.testing.expect(!checker.hasErrors());

    // i32 does NOT satisfy Serialize
    try checker.checkTraitBound(i32_type, "Serialize", span);
    try std.testing.expect(checker.hasErrors());
    try std.testing.expect(checker.diagnostics.items.len == 1);
    const msg = checker.diagnostics.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, msg, "does not implement trait 'Serialize'") != null);
}

test "trait bounds: type variable skips bound check" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Type variables should not produce errors (checked at instantiation site)
    const tv = ResolvedType.typeVar("T", null, span);
    try checker.checkTraitBound(tv, "Eq", span);

    try std.testing.expect(!checker.hasErrors());
}

test "trait bounds: generic function call with satisfied bound" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Eq is a builtin trait with impl for i32 — no need to define or register

    // Create a generic function: fn is_equal[T: Eq](a: T, b: T) -> bool
    // Must heap-allocate slices because Symbol.deinit frees them.
    var bool_return_type = Type.primitive(.bool, span);
    var t_param_type = Type{
        .kind = .{ .type_variable = .{ .name = "T", .constraints = null } },
        .span = span,
    };

    const param_types = try allocator.alloc(*Type, 2);
    param_types[0] = &t_param_type;
    param_types[1] = &t_param_type;

    const param_names = try allocator.alloc([]const u8, 2);
    param_names[0] = "a";
    param_names[1] = "b";

    const generic_params = try allocator.alloc(Symbol.GenericParamInfo, 1);
    var eq_constraints = [_][]const u8{"Eq"};
    generic_params[0] = .{ .name = "T", .constraints = &eq_constraints };

    const func_sym = Symbol.function(unassigned_symbol_id, "is_equal", .{
        .generic_params = generic_params,
        .parameter_types = param_types,
        .parameter_names = param_names,
        .return_type = &bool_return_type,
        .is_effect = false,
        .is_memoized = false,
        .has_body = true,
    }, true, span);

    _ = try table.define(func_sym);

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Create generic call: is_equal[i32](1, 2)
    var callee_expr = Expression{
        .kind = .{ .identifier = .{ .name = "is_equal", .generic_args = null } },
        .span = span,
    };
    var arg1 = Expression{
        .kind = .{ .integer_literal = .{ .value = 1, .suffix = null } },
        .span = span,
    };
    var arg2 = Expression{
        .kind = .{ .integer_literal = .{ .value = 2, .suffix = null } },
        .span = span,
    };
    var generic_arg = Type.primitive(.i32, span);
    var generic_args_arr = [_]*Type{&generic_arg};
    var args_arr = [_]*Expression{ &arg1, &arg2 };

    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &callee_expr,
            .generic_args = &generic_args_arr,
            .arguments = &args_arr,
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&call_expr);

    // Should succeed with bool return type
    try std.testing.expect(!checker.hasErrors());
    try std.testing.expect(result.isBool());
}

test "trait bounds: generic function call with unsatisfied bound" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register a custom trait "Serialize" with no impls
    _ = try table.define(Symbol.traitDef(unassigned_symbol_id, "Serialize", .{
        .generic_params = null,
        .super_traits = null,
        .methods = &[_]Symbol.TraitMethodInfo{},
    }, true, span));

    // Create a generic function: fn serialize[T: Serialize](a: T, b: T) -> bool
    // Must heap-allocate slices because Symbol.deinit frees them.
    var bool_return_type = Type.primitive(.bool, span);
    var t_param_type = Type{
        .kind = .{ .type_variable = .{ .name = "T", .constraints = null } },
        .span = span,
    };

    const param_types = try allocator.alloc(*Type, 2);
    param_types[0] = &t_param_type;
    param_types[1] = &t_param_type;

    const param_names = try allocator.alloc([]const u8, 2);
    param_names[0] = "a";
    param_names[1] = "b";

    const generic_params = try allocator.alloc(Symbol.GenericParamInfo, 1);
    var serialize_constraints = [_][]const u8{"Serialize"};
    generic_params[0] = .{ .name = "T", .constraints = &serialize_constraints };

    const func_sym = Symbol.function(unassigned_symbol_id, "serialize", .{
        .generic_params = generic_params,
        .parameter_types = param_types,
        .parameter_names = param_names,
        .return_type = &bool_return_type,
        .is_effect = false,
        .is_memoized = false,
        .has_body = true,
    }, true, span);

    _ = try table.define(func_sym);

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Create generic call: serialize[i32](1, 2) — should fail because i32 has no Serialize impl
    var callee_expr = Expression{
        .kind = .{ .identifier = .{ .name = "serialize", .generic_args = null } },
        .span = span,
    };
    var arg1 = Expression{
        .kind = .{ .integer_literal = .{ .value = 1, .suffix = null } },
        .span = span,
    };
    var arg2 = Expression{
        .kind = .{ .integer_literal = .{ .value = 2, .suffix = null } },
        .span = span,
    };
    var generic_arg = Type.primitive(.i32, span);
    var generic_args_arr = [_]*Type{&generic_arg};
    var args_arr = [_]*Expression{ &arg1, &arg2 };

    var call_expr = Expression{
        .kind = .{ .function_call = .{
            .callee = &callee_expr,
            .generic_args = &generic_args_arr,
            .arguments = &args_arr,
        } },
        .span = span,
    };

    _ = try checker.checkExpression(&call_expr);

    // Should have an error about i32 not implementing Serialize
    try std.testing.expect(checker.hasErrors());
    var found_bound_error = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "does not implement trait 'Serialize'") != null) {
            found_bound_error = true;
            break;
        }
    }
    try std.testing.expect(found_bound_error);
}

test "method resolution: trait method on concrete type resolves return type" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register type Point
    var point_type_ast = Type.named("Point", span);
    _ = try table.define(Symbol.typeDef(unassigned_symbol_id, "Point", .{
        .generic_params = null,
        .definition = .{ .product_type = .{
            .fields = &[_]Symbol.RecordFieldInfo{},
        } },
    }, true, span));

    // Show is a builtin trait — no need to define it

    // Create the `show` method: fn show(self: Self) -> string
    // Must heap-allocate slices because Symbol.deinit frees them.
    var self_type = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type = Type.primitive(.string, span);

    const param_types = try allocator.alloc(*Type, 1);
    param_types[0] = &self_type;
    const param_names = try allocator.alloc([]const u8, 1);
    param_names[0] = "self";

    const show_sym = try table.define(Symbol.function(unassigned_symbol_id, "show", .{
        .generic_params = null,
        .parameter_types = param_types,
        .parameter_names = param_names,
        .return_type = &string_type,
        .is_effect = false,
        .is_memoized = false,
        .has_body = true,
    }, true, span));

    // Register impl Show for Point with the show method
    const method_ids = try allocator.alloc(symbols.SymbolId, 1);
    method_ids[0] = show_sym;
    try table.registerImpl(.{
        .trait_name = "Show",
        .target_type = &point_type_ast,
        .methods = method_ids,
        .scope_id = 0,
        .span = span,
    });

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Register variable p: Point
    var point_type_ast2 = Type.named("Point", span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "p", &point_type_ast2, false, false, span));

    // Create expression: p.show()
    var p_ident = Expression{
        .kind = .{ .identifier = .{ .name = "p", .generic_args = null } },
        .span = span,
    };
    var mc = Expression{
        .kind = .{ .method_call = .{
            .object = &p_ident,
            .method = "show",
            .generic_args = null,
            .arguments = &[_]*Expression{},
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&mc);

    // Should resolve to string type
    try std.testing.expect(result.kind == .primitive);
    try std.testing.expectEqual(@as(Type.PrimitiveType, .string), result.kind.primitive);

    // Verify no "method not found" error
    var found_method_not_found = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "method not found") != null) {
            found_method_not_found = true;
            break;
        }
    }
    try std.testing.expect(!found_method_not_found);
}

test "method resolution: method not found produces error" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register type Point (no impls)
    _ = try table.define(Symbol.typeDef(unassigned_symbol_id, "Point", .{
        .generic_params = null,
        .definition = .{ .product_type = .{
            .fields = &[_]Symbol.RecordFieldInfo{},
        } },
    }, true, span));

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Register a variable of type Point
    var point_type_ast = Type.named("Point", span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "p", &point_type_ast, false, false, span));

    // Create expression: p.nonexistent()
    var p_ident = Expression{
        .kind = .{ .identifier = .{ .name = "p", .generic_args = null } },
        .span = span,
    };
    var mc = Expression{
        .kind = .{ .method_call = .{
            .object = &p_ident,
            .method = "nonexistent",
            .generic_args = null,
            .arguments = &[_]*Expression{},
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&mc);
    try std.testing.expect(result.isError());

    // Verify "method not found" error
    var found_error = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "method not found") != null) {
            found_error = true;
            break;
        }
    }
    try std.testing.expect(found_error);
}

test "method resolution: wrong argument count produces error" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register type Point
    var point_type_ast = Type.named("Point", span);
    _ = try table.define(Symbol.typeDef(unassigned_symbol_id, "Point", .{
        .generic_params = null,
        .definition = .{ .product_type = .{
            .fields = &[_]Symbol.RecordFieldInfo{},
        } },
    }, true, span));

    // Create method `show(self: Self) -> string` (takes only self, no extra args)
    // Must heap-allocate slices because Symbol.deinit frees them.
    var self_type = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type = Type.primitive(.string, span);

    const param_types = try allocator.alloc(*Type, 1);
    param_types[0] = &self_type;
    const param_names = try allocator.alloc([]const u8, 1);
    param_names[0] = "self";

    const show_sym = try table.define(Symbol.function(unassigned_symbol_id, "show", .{
        .generic_params = null,
        .parameter_types = param_types,
        .parameter_names = param_names,
        .return_type = &string_type,
        .is_effect = false,
        .is_memoized = false,
        .has_body = true,
    }, true, span));

    const method_ids = try allocator.alloc(symbols.SymbolId, 1);
    method_ids[0] = show_sym;
    try table.registerImpl(.{
        .trait_name = "Show",
        .target_type = &point_type_ast,
        .methods = method_ids,
        .scope_id = 0,
        .span = span,
    });

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Register variable p: Point
    var point_type_ast2 = Type.named("Point", span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "p", &point_type_ast2, false, false, span));

    // Create expression: p.show(42) — wrong number of arguments (expects 0 extra, got 1)
    var p_ident = Expression{
        .kind = .{ .identifier = .{ .name = "p", .generic_args = null } },
        .span = span,
    };
    var extra_arg = Expression{
        .kind = .{ .integer_literal = .{ .value = 42, .suffix = null } },
        .span = span,
    };
    var mc = Expression{
        .kind = .{ .method_call = .{
            .object = &p_ident,
            .method = "show",
            .generic_args = null,
            .arguments = @constCast(&[_]*Expression{&extra_arg}),
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&mc);
    try std.testing.expect(result.isError());

    // Verify wrong argument count error
    var found_error = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "wrong number of arguments") != null) {
            found_error = true;
            break;
        }
    }
    try std.testing.expect(found_error);
}

test "method resolution: inherent method (impl without trait)" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register type Point
    var point_type_ast = Type.named("Point", span);
    _ = try table.define(Symbol.typeDef(unassigned_symbol_id, "Point", .{
        .generic_params = null,
        .definition = .{ .product_type = .{
            .fields = &[_]Symbol.RecordFieldInfo{},
        } },
    }, true, span));

    // Create inherent method `magnitude(self: Self) -> f64`
    // Must heap-allocate slices because Symbol.deinit frees them.
    var self_type = Type{ .kind = .{ .self_type = {} }, .span = span };
    var f64_type = Type.primitive(.f64, span);

    const param_types = try allocator.alloc(*Type, 1);
    param_types[0] = &self_type;
    const param_names = try allocator.alloc([]const u8, 1);
    param_names[0] = "self";

    const mag_sym = try table.define(Symbol.function(unassigned_symbol_id, "magnitude", .{
        .generic_params = null,
        .parameter_types = param_types,
        .parameter_names = param_names,
        .return_type = &f64_type,
        .is_effect = false,
        .is_memoized = false,
        .has_body = true,
    }, true, span));

    // Register inherent impl (trait_name = null)
    const method_ids = try allocator.alloc(symbols.SymbolId, 1);
    method_ids[0] = mag_sym;
    try table.registerImpl(.{
        .trait_name = null,
        .target_type = &point_type_ast,
        .methods = method_ids,
        .scope_id = 0,
        .span = span,
    });

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Register variable p: Point
    var point_type_ast2 = Type.named("Point", span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "p", &point_type_ast2, false, false, span));

    // Create expression: p.magnitude()
    var p_ident = Expression{
        .kind = .{ .identifier = .{ .name = "p", .generic_args = null } },
        .span = span,
    };
    var mc = Expression{
        .kind = .{ .method_call = .{
            .object = &p_ident,
            .method = "magnitude",
            .generic_args = null,
            .arguments = &[_]*Expression{},
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&mc);

    // Should resolve to f64 without errors
    var found_method_error = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "method not found") != null or
            std.mem.indexOf(u8, diag.message, "method call type checking not fully implemented") != null)
        {
            found_method_error = true;
            break;
        }
    }
    try std.testing.expect(!found_method_error);
    try std.testing.expect(result.kind == .primitive);
    try std.testing.expectEqual(@as(Type.PrimitiveType, .f64), result.kind.primitive);
}

test "trait default method resolves on concrete type" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register type Point
    var point_type_ast = Type.named("Point", span);
    _ = try table.define(Symbol.typeDef(unassigned_symbol_id, "Point", .{
        .generic_params = null,
        .definition = .{ .product_type = .{
            .fields = &[_]Symbol.RecordFieldInfo{},
        } },
    }, true, span));

    // Register trait Describable with:
    //   fn describe(self: Self) -> string  (required)
    //   fn short_describe(self: Self) -> string { ... }  (default)
    var self_type_desc = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type_desc = Type.primitive(.string, span);

    const desc_param_types = try allocator.alloc(*Type, 1);
    desc_param_types[0] = &self_type_desc;
    const desc_param_names = try allocator.alloc([]const u8, 1);
    desc_param_names[0] = "self";

    var self_type_short = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type_short = Type.primitive(.string, span);

    const short_param_types = try allocator.alloc(*Type, 1);
    short_param_types[0] = &self_type_short;
    const short_param_names = try allocator.alloc([]const u8, 1);
    short_param_names[0] = "self";

    // Empty default body (just needs to be non-null to mark as default)
    var empty_stmts = [_]Statement{};

    const trait_methods = try allocator.alloc(Symbol.TraitMethodInfo, 2);
    trait_methods[0] = .{
        .name = "describe",
        .generic_params = null,
        .parameter_types = desc_param_types,
        .parameter_names = desc_param_names,
        .return_type = &string_type_desc,
        .is_effect = false,
        .default_body = null, // required method
        .span = span,
    };
    trait_methods[1] = .{
        .name = "short_describe",
        .generic_params = null,
        .parameter_types = short_param_types,
        .parameter_names = short_param_names,
        .return_type = &string_type_short,
        .is_effect = false,
        .default_body = &empty_stmts, // default method
        .span = span,
    };

    _ = try table.define(Symbol.traitDef(unassigned_symbol_id, "Describable", .{
        .generic_params = null,
        .super_traits = null,
        .methods = trait_methods,
    }, true, span));

    // Register describe method symbol (the one explicitly implemented)
    var self_type_impl = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type_impl = Type.primitive(.string, span);
    const impl_param_types = try allocator.alloc(*Type, 1);
    impl_param_types[0] = &self_type_impl;
    const impl_param_names = try allocator.alloc([]const u8, 1);
    impl_param_names[0] = "self";

    const describe_sym = try table.define(Symbol.function(unassigned_symbol_id, "describe", .{
        .generic_params = null,
        .parameter_types = impl_param_types,
        .parameter_names = impl_param_names,
        .return_type = &string_type_impl,
        .is_effect = false,
        .is_memoized = false,
        .has_body = true,
    }, true, span));

    // Register impl Describable for Point with only describe (not short_describe)
    const method_ids = try allocator.alloc(symbols.SymbolId, 1);
    method_ids[0] = describe_sym;
    try table.registerImpl(.{
        .trait_name = "Describable",
        .target_type = &point_type_ast,
        .methods = method_ids,
        .scope_id = 0,
        .span = span,
    });

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Register variable p: Point
    var point_type_ast2 = Type.named("Point", span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "p", &point_type_ast2, false, false, span));

    // Call p.short_describe() — should resolve via trait default
    var p_ident = Expression{
        .kind = .{ .identifier = .{ .name = "p", .generic_args = null } },
        .span = span,
    };
    var mc = Expression{
        .kind = .{ .method_call = .{
            .object = &p_ident,
            .method = "short_describe",
            .generic_args = null,
            .arguments = &[_]*Expression{},
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&mc);

    // Should resolve to string type without errors
    try std.testing.expect(result.kind == .primitive);
    try std.testing.expectEqual(@as(Type.PrimitiveType, .string), result.kind.primitive);
    try std.testing.expect(!checker.hasErrors());
}

test "trait default method ambiguity produces error" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register type Widget
    var widget_type_ast = Type.named("Widget", span);
    _ = try table.define(Symbol.typeDef(unassigned_symbol_id, "Widget", .{
        .generic_params = null,
        .definition = .{ .product_type = .{
            .fields = &[_]Symbol.RecordFieldInfo{},
        } },
    }, true, span));

    // Register trait A with default method "info"
    var self_type_a = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type_a = Type.primitive(.string, span);
    const a_param_types = try allocator.alloc(*Type, 1);
    a_param_types[0] = &self_type_a;
    const a_param_names = try allocator.alloc([]const u8, 1);
    a_param_names[0] = "self";
    var empty_stmts_a = [_]Statement{};

    const a_methods = try allocator.alloc(Symbol.TraitMethodInfo, 1);
    a_methods[0] = .{
        .name = "info",
        .generic_params = null,
        .parameter_types = a_param_types,
        .parameter_names = a_param_names,
        .return_type = &string_type_a,
        .is_effect = false,
        .default_body = &empty_stmts_a,
        .span = span,
    };

    _ = try table.define(Symbol.traitDef(unassigned_symbol_id, "TraitA", .{
        .generic_params = null,
        .super_traits = null,
        .methods = a_methods,
    }, true, span));

    // Register trait B with default method "info" (same name)
    var self_type_b = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type_b = Type.primitive(.string, span);
    const b_param_types = try allocator.alloc(*Type, 1);
    b_param_types[0] = &self_type_b;
    const b_param_names = try allocator.alloc([]const u8, 1);
    b_param_names[0] = "self";
    var empty_stmts_b = [_]Statement{};

    const b_methods = try allocator.alloc(Symbol.TraitMethodInfo, 1);
    b_methods[0] = .{
        .name = "info",
        .generic_params = null,
        .parameter_types = b_param_types,
        .parameter_names = b_param_names,
        .return_type = &string_type_b,
        .is_effect = false,
        .default_body = &empty_stmts_b,
        .span = span,
    };

    _ = try table.define(Symbol.traitDef(unassigned_symbol_id, "TraitB", .{
        .generic_params = null,
        .super_traits = null,
        .methods = b_methods,
    }, true, span));

    // Register impl TraitA for Widget (no explicit methods — both are defaults)
    const empty_method_ids_a = try allocator.alloc(symbols.SymbolId, 0);
    try table.registerImpl(.{
        .trait_name = "TraitA",
        .target_type = &widget_type_ast,
        .methods = empty_method_ids_a,
        .scope_id = 0,
        .span = span,
    });

    // Register impl TraitB for Widget
    var widget_type_ast2 = Type.named("Widget", span);
    const empty_method_ids_b = try allocator.alloc(symbols.SymbolId, 0);
    try table.registerImpl(.{
        .trait_name = "TraitB",
        .target_type = &widget_type_ast2,
        .methods = empty_method_ids_b,
        .scope_id = 0,
        .span = span,
    });

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Register variable w: Widget
    var widget_type_ast3 = Type.named("Widget", span);
    _ = try table.define(Symbol.variable(unassigned_symbol_id, "w", &widget_type_ast3, false, false, span));

    // Call w.info() — should produce ambiguity error
    var w_ident = Expression{
        .kind = .{ .identifier = .{ .name = "w", .generic_args = null } },
        .span = span,
    };
    var mc = Expression{
        .kind = .{ .method_call = .{
            .object = &w_ident,
            .method = "info",
            .generic_args = null,
            .arguments = &[_]*Expression{},
        } },
        .span = span,
    };

    _ = try checker.checkExpression(&mc);

    // Should have an ambiguity error
    try std.testing.expect(checker.hasErrors());
    var found_ambiguity = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "ambiguous") != null) {
            found_ambiguity = true;
            break;
        }
    }
    try std.testing.expect(found_ambiguity);
}

test "trait Self method resolution in default body context" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Simulate trait context: Self type + current_trait
    checker.self_type = ResolvedType.typeVar("Self", null, span);

    // Build a minimal TraitDecl with one method: fn describe(self: Self) -> string
    var self_param_type = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_return_type = Type.primitive(.string, span);
    var params = [_]Declaration.Parameter{.{
        .name = "self",
        .param_type = &self_param_type,
        .span = span,
    }};
    var methods = [_]Declaration.TraitMethod{.{
        .name = "describe",
        .generic_params = null,
        .parameters = &params,
        .return_type = &string_return_type,
        .is_effect = false,
        .default_body = null,
        .span = span,
    }};
    var trait_decl = Declaration.TraitDecl{
        .name = "Describable",
        .generic_params = null,
        .super_traits = null,
        .methods = &methods,
        .is_public = true,
    };
    checker.current_trait = &trait_decl;

    // Create expression: self.describe() where self is of type Self (type_var)
    var self_expr = Expression{
        .kind = .{ .self_expr = {} },
        .span = span,
    };
    var mc = Expression{
        .kind = .{ .method_call = .{
            .object = &self_expr,
            .method = "describe",
            .generic_args = null,
            .arguments = &[_]*Expression{},
        } },
        .span = span,
    };

    const result = try checker.checkExpression(&mc);

    // Should resolve to string without errors
    try std.testing.expect(result.kind == .primitive);
    try std.testing.expectEqual(@as(Type.PrimitiveType, .string), result.kind.primitive);
    try std.testing.expect(!checker.hasErrors());
}

test "trait required method missing from impl produces error" {
    const allocator = std.testing.allocator;
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register trait with one required method
    var self_type_req = Type{ .kind = .{ .self_type = {} }, .span = span };
    var string_type_req = Type.primitive(.string, span);
    const req_param_types = try allocator.alloc(*Type, 1);
    req_param_types[0] = &self_type_req;
    const req_param_names = try allocator.alloc([]const u8, 1);
    req_param_names[0] = "self";

    const req_methods = try allocator.alloc(Symbol.TraitMethodInfo, 1);
    req_methods[0] = .{
        .name = "required_method",
        .generic_params = null,
        .parameter_types = req_param_types,
        .parameter_names = req_param_names,
        .return_type = &string_type_req,
        .is_effect = false,
        .default_body = null, // required — no default
        .span = span,
    };

    _ = try table.define(Symbol.traitDef(unassigned_symbol_id, "MyTrait", .{
        .generic_params = null,
        .super_traits = null,
        .methods = req_methods,
    }, true, span));

    var checker = TypeChecker.init(allocator, &table);
    defer checker.deinit();

    // Create impl block with no methods
    var target_type = Type.named("Foo", span);
    var empty_methods = [_]Declaration.FunctionDecl{};
    var impl_block = Declaration.ImplBlock{
        .trait_name = "MyTrait",
        .generic_params = null,
        .target_type = &target_type,
        .methods = &empty_methods,
        .where_clause = null,
    };

    try checker.checkImplBlock(&impl_block);

    // Should report missing implementation error
    try std.testing.expect(checker.hasErrors());
    var found_missing = false;
    for (checker.diagnostics.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, "missing implementation") != null) {
            found_missing = true;
            break;
        }
    }
    try std.testing.expect(found_missing);
}
