//! AST Resolver for the Kira language.
//!
//! The resolver walks the AST and populates the symbol table with all
//! declarations. It handles:
//! - Variable bindings (let, var)
//! - Function declarations
//! - Type definitions (sum types, product types, aliases)
//! - Trait definitions and implementations
//! - Module declarations and imports
//! - Generic type parameters
//!
//! The resolver performs two passes:
//! 1. First pass: Collect all top-level declarations (types, traits, functions)
//! 2. Second pass: Resolve bodies and validate references

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const symbol_mod = @import("symbol.zig");
const table_mod = @import("table.zig");
const modules = @import("../modules/root.zig");

pub const Declaration = ast.Declaration;
pub const Statement = ast.Statement;
pub const Expression = ast.Expression;
pub const Type = ast.Type;
pub const Pattern = ast.Pattern;
pub const Program = ast.Program;
pub const Span = ast.Span;

pub const Symbol = symbol_mod.Symbol;
pub const SymbolId = symbol_mod.SymbolId;
pub const ScopeId = symbol_mod.ScopeId;
pub const SymbolTable = table_mod.SymbolTable;
pub const ScopeKind = @import("scope.zig").ScopeKind;

/// Errors that can occur during resolution
pub const ResolveError = error{
    DuplicateDefinition,
    UndefinedSymbol,
    UndefinedType,
    UndefinedTrait,
    InvalidScope,
    VisibilityViolation,
    MutabilityViolation,
    EffectViolation,
    ImportNotFound,
    CircularDependency,
    ResolutionFailed, // Generic error when diagnostics contain errors
    OutOfMemory,
};

/// Diagnostic message for resolution errors
pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
    kind: DiagnosticKind,
    related: ?[]const RelatedInfo = null,

    pub const DiagnosticKind = enum {
        err,
        warning,
        hint,
    };

    pub const RelatedInfo = struct {
        message: []const u8,
        span: Span,
    };

    /// Free allocated memory
    pub fn deinit(self: *Diagnostic, allocator: Allocator) void {
        if (self.message.len > 0) {
            allocator.free(self.message);
        }
        if (self.related) |rel| {
            allocator.free(rel);
        }
    }
};

/// The AST resolver
pub const Resolver = struct {
    allocator: Allocator,
    table: *SymbolTable,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    /// Current module path (for qualified names)
    current_module: [][]const u8,
    /// Imports pending resolution
    pending_imports: std.ArrayListUnmanaged(PendingImport),
    /// Whether we're in the first (declaration) pass
    first_pass: bool,
    /// Optional module loader for cross-file imports
    module_loader: ?*modules.ModuleLoader,

    const PendingImport = struct {
        decl: Declaration.ImportDecl,
        scope_id: ScopeId,
        span: Span,
    };

    /// Create a new resolver
    pub fn init(allocator: Allocator, table: *SymbolTable) Resolver {
        return .{
            .allocator = allocator,
            .table = table,
            .diagnostics = .{},
            .current_module = &.{},
            .pending_imports = .{},
            .first_pass = true,
            .module_loader = null,
        };
    }

    /// Create a new resolver with a module loader for cross-file imports
    pub fn initWithLoader(allocator: Allocator, table: *SymbolTable, loader: *modules.ModuleLoader) Resolver {
        return .{
            .allocator = allocator,
            .table = table,
            .diagnostics = .{},
            .current_module = &.{},
            .pending_imports = .{},
            .first_pass = true,
            .module_loader = loader,
        };
    }

    /// Free all resources
    pub fn deinit(self: *Resolver) void {
        // Free each diagnostic's allocated message
        for (self.diagnostics.items) |*diag| {
            diag.deinit(self.allocator);
        }
        self.diagnostics.deinit(self.allocator);
        self.pending_imports.deinit(self.allocator);
    }

    /// Resolve an entire program
    pub fn resolve(self: *Resolver, program: *const Program) ResolveError!void {
        // First pass: collect all top-level declarations
        self.first_pass = true;

        // Handle module declaration if present
        if (program.module_decl) |mod| {
            const span = Span{
                .start = .{ .line = 1, .column = 1, .offset = 0 },
                .end = .{ .line = 1, .column = 1, .offset = 0 },
            };
            try self.resolveModuleDecl(&mod, span);
        }

        // Queue all imports for later resolution
        for (program.imports) |import_decl| {
            try self.pending_imports.append(self.allocator, .{
                .decl = import_decl,
                .scope_id = self.table.current_scope_id,
                .span = Span{
                    .start = .{ .line = 1, .column = 1, .offset = 0 },
                    .end = .{ .line = 1, .column = 1, .offset = 0 },
                },
            });
        }

        // Process other declarations
        for (program.declarations) |*decl| {
            try self.resolveDeclaration(decl);
        }

        // Resolve pending imports
        try self.resolveImports();

        // Second pass: resolve function bodies and validate references
        self.first_pass = false;
        for (program.declarations) |*decl| {
            try self.resolveDeclarationBodies(decl);
        }

        // Fail resolution if any errors were collected
        if (self.hasErrors()) {
            return error.ResolutionFailed;
        }
    }

    /// Resolve a single declaration (first pass - signatures only)
    fn resolveDeclaration(self: *Resolver, decl: *const Declaration) ResolveError!void {
        switch (decl.kind) {
            .function_decl => |f| try self.resolveFunctionDecl(&f, decl.span, decl.doc_comment),
            .type_decl => |t| try self.resolveTypeDecl(&t, decl.span, decl.doc_comment),
            .trait_decl => |t| try self.resolveTraitDecl(&t, decl.span, decl.doc_comment),
            .impl_block => |i| try self.resolveImplBlock(&i, decl.span),
            .module_decl => |m| try self.resolveModuleDecl(&m, decl.span),
            .import_decl => |i| {
                // Queue for later resolution
                try self.pending_imports.append(self.allocator, .{
                    .decl = i,
                    .scope_id = self.table.current_scope_id,
                    .span = decl.span,
                });
            },
            .const_decl => |c| try self.resolveConstDecl(&c, decl.span, decl.doc_comment),
            .let_decl => |l| try self.resolveLetDecl(&l, decl.span, decl.doc_comment),
            .test_decl => {
                // Tests don't introduce new symbols, they're just executed later
                // The test body will be resolved when the test is run
            },
        }
    }

    /// Resolve function declaration
    fn resolveFunctionDecl(
        self: *Resolver,
        func: *const Declaration.FunctionDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) ResolveError!void {
        // Convert generic params
        var generic_params: ?[]Symbol.GenericParamInfo = null;
        if (func.generic_params) |params| {
            var gp = std.ArrayListUnmanaged(Symbol.GenericParamInfo){};
            for (params) |p| {
                try gp.append(self.allocator, .{
                    .name = p.name,
                    .constraints = p.constraints,
                });
            }
            generic_params = try gp.toOwnedSlice(self.allocator);
        }

        // Collect parameter info
        var param_types = std.ArrayListUnmanaged(*Type){};
        var param_names = std.ArrayListUnmanaged([]const u8){};
        for (func.parameters) |p| {
            try param_types.append(self.allocator, p.param_type);
            try param_names.append(self.allocator, p.name);
        }

        const func_symbol = Symbol.FunctionSymbol{
            .generic_params = generic_params,
            .parameter_types = try param_types.toOwnedSlice(self.allocator),
            .parameter_names = try param_names.toOwnedSlice(self.allocator),
            .return_type = func.return_type,
            .is_effect = func.is_effect,
            .has_body = func.body != null,
        };

        var sym = Symbol.function(0, func.name, func_symbol, func.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch |err| {
            if (err == error.DuplicateDefinition) {
                try self.addError("Duplicate definition of '{s}'", .{func.name}, span);
                return error.DuplicateDefinition;
            }
            return err;
        };
    }

    /// Resolve type declaration
    fn resolveTypeDecl(
        self: *Resolver,
        type_decl: *const Declaration.TypeDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) ResolveError!void {
        // Convert generic params
        var generic_params: ?[]Symbol.GenericParamInfo = null;
        if (type_decl.generic_params) |params| {
            var gp = std.ArrayListUnmanaged(Symbol.GenericParamInfo){};
            for (params) |p| {
                try gp.append(self.allocator, .{
                    .name = p.name,
                    .constraints = p.constraints,
                });
            }
            generic_params = try gp.toOwnedSlice(self.allocator);
        }

        // Convert type definition
        const def_kind: Symbol.TypeDefKind = switch (type_decl.definition) {
            .sum_type => |s| blk: {
                var variants = std.ArrayListUnmanaged(Symbol.VariantInfo){};
                for (s.variants) |v| {
                    const fields: ?Symbol.VariantFields = if (v.fields) |vf| switch (vf) {
                        .tuple_fields => |tf| .{ .tuple_fields = tf },
                        .record_fields => |rf| inner: {
                            var record_fields = std.ArrayListUnmanaged(Symbol.RecordFieldInfo){};
                            for (rf) |f| {
                                try record_fields.append(self.allocator, .{
                                    .name = f.name,
                                    .field_type = f.field_type,
                                    .span = f.span,
                                });
                            }
                            break :inner .{ .record_fields = try record_fields.toOwnedSlice(self.allocator) };
                        },
                    } else null;

                    try variants.append(self.allocator, .{
                        .name = v.name,
                        .fields = fields,
                        .span = v.span,
                    });
                }
                break :blk .{ .sum_type = .{ .variants = try variants.toOwnedSlice(self.allocator) } };
            },
            .product_type => |p| blk: {
                var fields = std.ArrayListUnmanaged(Symbol.RecordFieldInfo){};
                for (p.fields) |f| {
                    try fields.append(self.allocator, .{
                        .name = f.name,
                        .field_type = f.field_type,
                        .span = f.span,
                    });
                }
                break :blk .{ .product_type = .{ .fields = try fields.toOwnedSlice(self.allocator) } };
            },
            .type_alias => |alias| .{ .alias = alias },
        };

        const type_def_symbol = Symbol.TypeDefSymbol{
            .generic_params = generic_params,
            .definition = def_kind,
        };

        var sym = Symbol.typeDef(0, type_decl.name, type_def_symbol, type_decl.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch |err| {
            if (err == error.DuplicateDefinition) {
                try self.addError("Duplicate definition of type '{s}'", .{type_decl.name}, span);
                return error.DuplicateDefinition;
            }
            return err;
        };
    }

    /// Resolve trait declaration
    fn resolveTraitDecl(
        self: *Resolver,
        trait_decl: *const Declaration.TraitDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) ResolveError!void {
        // Convert generic params
        var generic_params: ?[]Symbol.GenericParamInfo = null;
        if (trait_decl.generic_params) |params| {
            var gp = std.ArrayListUnmanaged(Symbol.GenericParamInfo){};
            for (params) |p| {
                try gp.append(self.allocator, .{
                    .name = p.name,
                    .constraints = p.constraints,
                });
            }
            generic_params = try gp.toOwnedSlice(self.allocator);
        }

        // Convert methods
        var methods = std.ArrayListUnmanaged(Symbol.TraitMethodInfo){};
        for (trait_decl.methods) |m| {
            var method_generic_params: ?[]Symbol.GenericParamInfo = null;
            if (m.generic_params) |params| {
                var mgp = std.ArrayListUnmanaged(Symbol.GenericParamInfo){};
                for (params) |p| {
                    try mgp.append(self.allocator, .{
                        .name = p.name,
                        .constraints = p.constraints,
                    });
                }
                method_generic_params = try mgp.toOwnedSlice(self.allocator);
            }

            var param_types = std.ArrayListUnmanaged(*Type){};
            var param_names = std.ArrayListUnmanaged([]const u8){};
            for (m.parameters) |p| {
                try param_types.append(self.allocator, p.param_type);
                try param_names.append(self.allocator, p.name);
            }

            try methods.append(self.allocator, .{
                .name = m.name,
                .generic_params = method_generic_params,
                .parameter_types = try param_types.toOwnedSlice(self.allocator),
                .parameter_names = try param_names.toOwnedSlice(self.allocator),
                .return_type = m.return_type,
                .is_effect = m.is_effect,
                .has_default = m.default_body != null,
                .span = m.span,
            });
        }

        const trait_def_symbol = Symbol.TraitDefSymbol{
            .generic_params = generic_params,
            .super_traits = trait_decl.super_traits,
            .methods = try methods.toOwnedSlice(self.allocator),
        };

        var sym = Symbol.traitDef(0, trait_decl.name, trait_def_symbol, trait_decl.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch |err| {
            if (err == error.DuplicateDefinition) {
                try self.addError("Duplicate definition of trait '{s}'", .{trait_decl.name}, span);
                return error.DuplicateDefinition;
            }
            return err;
        };
    }

    /// Resolve impl block
    fn resolveImplBlock(
        self: *Resolver,
        impl_block: *const Declaration.ImplBlock,
        span: Span,
    ) ResolveError!void {
        // Enter impl scope
        const impl_scope_id = try self.table.enterScope(.impl_block);

        // If there are generic params, add them to scope
        if (impl_block.generic_params) |params| {
            for (params) |p| {
                const type_param_sym = Symbol{
                    .id = 0,
                    .name = p.name,
                    .kind = .{ .type_param = .{ .constraints = p.constraints } },
                    .span = p.span,
                    .is_public = false,
                    .doc_comment = null,
                };
                _ = self.table.define(type_param_sym) catch |err| {
                    if (err == error.DuplicateDefinition) {
                        try self.addError("Duplicate type parameter '{s}'", .{p.name}, p.span);
                    }
                    return err;
                };
            }
        }

        // Resolve methods
        var method_ids = std.ArrayListUnmanaged(SymbolId){};
        for (impl_block.methods) |*method| {
            const method_span = Span{
                .start = method.parameters[0].span.start,
                .end = method.return_type.span.end,
            };
            try self.resolveFunctionDecl(method, method_span, null);
            // Get the ID of the just-defined method
            if (self.table.lookupLocal(method.name)) |sym| {
                try method_ids.append(self.allocator, sym.id);
            }
        }

        // Leave impl scope
        try self.table.leaveScope();

        // Register the implementation
        try self.table.registerImpl(.{
            .trait_name = impl_block.trait_name,
            .target_type = impl_block.target_type,
            .methods = try method_ids.toOwnedSlice(self.allocator),
            .scope_id = impl_scope_id,
            .span = span,
        });
    }

    /// Resolve module declaration - returns true if a module scope was entered (caller must leave it)
    fn resolveModuleDecl(
        self: *Resolver,
        module_decl: *const Declaration.ModuleDecl,
        span: Span,
    ) ResolveError!void {
        // Create module scope
        const module_scope_id = try self.table.enterScope(.module);

        // Build module path string for registration
        var path_builder = std.ArrayListUnmanaged(u8){};
        for (module_decl.path, 0..) |segment, i| {
            if (i > 0) try path_builder.append(self.allocator, '.');
            try path_builder.appendSlice(self.allocator, segment);
        }
        const path_str = try path_builder.toOwnedSlice(self.allocator);
        defer self.allocator.free(path_str); // registerModule dupes it internally

        // Register module scope
        try self.table.registerModule(path_str, module_scope_id);

        // Create module symbol in parent scope (temporarily leave to define it)
        try self.table.leaveScope();

        const module_name = module_decl.path[module_decl.path.len - 1];
        const module_sym = Symbol{
            .id = 0,
            .name = module_name,
            .kind = .{ .module = .{
                .path = module_decl.path,
                .scope_id = module_scope_id,
            } },
            .span = span,
            .is_public = true, // Modules are public by default
            .doc_comment = null,
        };

        _ = self.table.define(module_sym) catch |err| {
            if (err == error.DuplicateDefinition) {
                try self.addError("Duplicate module definition '{s}'", .{module_name}, span);
            }
            return err;
        };

        // Re-enter module scope so subsequent declarations are added there
        try self.table.setCurrentScope(module_scope_id);

        // Set current module
        self.current_module = module_decl.path;
    }

    /// Resolve constant declaration
    fn resolveConstDecl(
        self: *Resolver,
        const_decl: *const Declaration.ConstDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) ResolveError!void {
        var sym = Symbol.variable(0, const_decl.name, const_decl.const_type, false, const_decl.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch |err| {
            if (err == error.DuplicateDefinition) {
                try self.addError("Duplicate definition of constant '{s}'", .{const_decl.name}, span);
            }
            return err;
        };
    }

    /// Resolve let declaration (top-level)
    fn resolveLetDecl(
        self: *Resolver,
        let_decl: *const Declaration.LetDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) ResolveError!void {
        // If it has generic params, it's a generic function binding
        if (let_decl.generic_params) |params| {
            // Enter generic scope
            _ = try self.table.enterScope(.generic);
            for (params) |p| {
                const type_param_sym = Symbol{
                    .id = 0,
                    .name = p.name,
                    .kind = .{ .type_param = .{ .constraints = p.constraints } },
                    .span = p.span,
                    .is_public = false,
                    .doc_comment = null,
                };
                _ = self.table.define(type_param_sym) catch {};
            }
            try self.table.leaveScope();
        }

        var sym = Symbol.variable(0, let_decl.name, let_decl.binding_type, false, let_decl.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch |err| {
            if (err == error.DuplicateDefinition) {
                try self.addError("Duplicate definition of '{s}'", .{let_decl.name}, span);
            }
            return err;
        };
    }

    /// Resolve pending imports
    fn resolveImports(self: *Resolver) ResolveError!void {
        for (self.pending_imports.items) |pending| {
            try self.resolveImportDecl(&pending.decl, pending.scope_id, pending.span);
        }
    }

    /// Resolve a single import declaration
    fn resolveImportDecl(
        self: *Resolver,
        import_decl: *const Declaration.ImportDecl,
        scope_id: ScopeId,
        span: Span,
    ) ResolveError!void {
        // Look up the module being imported
        var path_builder = std.ArrayListUnmanaged(u8){};
        errdefer path_builder.deinit(self.allocator);
        for (import_decl.path, 0..) |segment, i| {
            if (i > 0) try path_builder.append(self.allocator, '.');
            try path_builder.appendSlice(self.allocator, segment);
        }
        const path_str = try path_builder.toOwnedSlice(self.allocator);
        defer self.allocator.free(path_str); // Free after use since this is just for lookup

        var module_scope_id = self.table.getModuleScope(path_str);

        // If not found and we have a loader, try to load it from file
        if (module_scope_id == null and self.module_loader != null) {
            module_scope_id = self.module_loader.?.loadModule(path_str) catch |err| {
                const err_name = @errorName(err);
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Failed to load module '{s}': {s}", .{ path_str, err_name }) catch "Failed to load module";
                try self.addError("{s}", .{err_msg}, span);
                return;
            };
        }

        if (module_scope_id == null) {
            // Module might not be loaded yet - add a warning but don't fail
            try self.addWarning("Module '{s}' not found", .{path_str}, span);
            return;
        }

        // Import specific items or entire module
        if (import_decl.items) |items| {
            for (items) |item| {
                const source_sym = self.table.lookupInScope(module_scope_id.?, item.name);
                if (source_sym) |sym| {
                    // Check visibility
                    if (!sym.is_public) {
                        try self.addError("Cannot import private symbol '{s}'", .{item.name}, item.span);
                        continue;
                    }

                    // Create import alias in target scope
                    const alias_name = item.alias orelse item.name;
                    const import_sym = Symbol{
                        .id = 0,
                        .name = alias_name,
                        .kind = .{ .import_alias = .{
                            .source_path = import_decl.path,
                            .resolved_id = sym.id,
                        } },
                        .span = item.span,
                        .is_public = false,
                        .doc_comment = null,
                    };

                    _ = self.table.defineInScope(scope_id, import_sym) catch |err| {
                        if (err == error.DuplicateDefinition) {
                            try self.addError("Import '{s}' conflicts with existing definition", .{alias_name}, item.span);
                        }
                    };
                } else {
                    try self.addError("'{s}' not found in module", .{item.name}, item.span);
                }
            }
        } else {
            // Import entire module - create module alias
            const module_name = import_decl.path[import_decl.path.len - 1];
            const module_sym = Symbol{
                .id = 0,
                .name = module_name,
                .kind = .{ .module = .{
                    .path = import_decl.path,
                    .scope_id = module_scope_id,
                } },
                .span = span,
                .is_public = false,
                .doc_comment = null,
            };

            _ = self.table.defineInScope(scope_id, module_sym) catch |err| {
                if (err == error.DuplicateDefinition) {
                    try self.addError("Import '{s}' conflicts with existing definition", .{module_name}, span);
                }
            };
        }
    }

    /// Second pass: resolve bodies and validate references
    fn resolveDeclarationBodies(self: *Resolver, decl: *const Declaration) ResolveError!void {
        switch (decl.kind) {
            .function_decl => |f| {
                if (f.body) |body| {
                    try self.resolveFunctionBody(&f, body);
                }
            },
            .impl_block => |i| {
                for (i.methods) |*method| {
                    if (method.body) |body| {
                        try self.resolveFunctionBody(method, body);
                    }
                }
            },
            .const_decl => |c| {
                try self.resolveExpression(c.value);
            },
            .let_decl => |l| {
                try self.resolveExpression(l.value);
            },
            else => {},
        }
    }

    /// Resolve a function body
    fn resolveFunctionBody(
        self: *Resolver,
        func: *const Declaration.FunctionDecl,
        body: []Statement,
    ) ResolveError!void {
        // Enter function scope
        _ = try self.table.enterScope(.function);

        // Add generic type parameters
        if (func.generic_params) |params| {
            for (params) |p| {
                const type_param_sym = Symbol{
                    .id = 0,
                    .name = p.name,
                    .kind = .{ .type_param = .{ .constraints = p.constraints } },
                    .span = p.span,
                    .is_public = false,
                    .doc_comment = null,
                };
                _ = self.table.define(type_param_sym) catch {};
            }
        }

        // Add parameters to scope
        for (func.parameters) |param| {
            const param_sym = Symbol.variable(0, param.name, param.param_type, false, false, param.span);
            _ = self.table.define(param_sym) catch |err| {
                if (err == error.DuplicateDefinition) {
                    try self.addError("Duplicate parameter '{s}'", .{param.name}, param.span);
                }
            };
        }

        // Resolve body statements
        for (body) |*stmt| {
            try self.resolveStatement(stmt);
        }

        // Leave function scope
        try self.table.leaveScope();
    }

    /// Resolve a statement
    fn resolveStatement(self: *Resolver, stmt: *const Statement) ResolveError!void {
        switch (stmt.kind) {
            .let_binding => |let_bind| {
                // Resolve the initializer first
                try self.resolveExpression(let_bind.initializer);

                // Add the binding to scope
                try self.resolvePattern(let_bind.pattern, let_bind.explicit_type, false);
            },
            .var_binding => |var_bind| {
                // Local mutation via var is allowed in pure functions —
                // only I/O and calling effect functions are true side effects.

                if (var_bind.initializer) |initializer| {
                    try self.resolveExpression(initializer);
                }

                const var_sym = Symbol.variable(0, var_bind.name, var_bind.explicit_type, true, false, stmt.span);
                _ = self.table.define(var_sym) catch |err| {
                    if (err == error.DuplicateDefinition) {
                        try self.addError("Duplicate variable '{s}'", .{var_bind.name}, stmt.span);
                    }
                    return err;
                };
            },
            .assignment => |assign| {
                // Check target exists and is mutable
                switch (assign.target) {
                    .identifier => |name| {
                        if (self.table.lookup(name)) |sym| {
                            if (sym.kind == .variable and !sym.kind.variable.is_mutable) {
                                try self.addError("Cannot assign to immutable binding '{s}'", .{name}, stmt.span);
                            }
                        } else {
                            try self.addError("Undefined variable '{s}'", .{name}, stmt.span);
                        }
                    },
                    .field_access => |fa| try self.resolveExpression(fa.object),
                    .index_access => |ia| {
                        try self.resolveExpression(ia.object);
                        try self.resolveExpression(ia.index);
                    },
                }
                try self.resolveExpression(assign.value);
            },
            .if_statement => |if_stmt| {
                try self.resolveExpression(if_stmt.condition);

                _ = try self.table.enterScope(.block);
                for (if_stmt.then_branch) |*s| {
                    try self.resolveStatement(s);
                }
                try self.table.leaveScope();

                if (if_stmt.else_branch) |else_branch| {
                    switch (else_branch) {
                        .block => |block| {
                            _ = try self.table.enterScope(.block);
                            for (block) |*s| {
                                try self.resolveStatement(s);
                            }
                            try self.table.leaveScope();
                        },
                        .else_if => |else_if| {
                            try self.resolveStatement(else_if);
                        },
                    }
                }
            },
            .for_loop => |for_loop| {
                try self.resolveExpression(for_loop.iterable);

                _ = try self.table.enterScope(.block);
                // Add loop variable
                try self.resolvePattern(for_loop.pattern, null, false);

                for (for_loop.body) |*s| {
                    try self.resolveStatement(s);
                }
                try self.table.leaveScope();
            },
            .while_loop => |while_loop| {
                try self.resolveExpression(while_loop.condition);

                _ = try self.table.enterScope(.block);
                for (while_loop.body) |*s| {
                    try self.resolveStatement(s);
                }
                try self.table.leaveScope();
            },
            .loop_statement => |loop_stmt| {
                _ = try self.table.enterScope(.block);
                for (loop_stmt.body) |*s| {
                    try self.resolveStatement(s);
                }
                try self.table.leaveScope();
            },
            .match_statement => |match_stmt| {
                try self.resolveExpression(match_stmt.subject);

                for (match_stmt.arms) |arm| {
                    _ = try self.table.enterScope(.block);
                    try self.resolvePattern(arm.pattern, null, false);

                    if (arm.guard) |guard| {
                        try self.resolveExpression(guard);
                    }

                    for (arm.body) |*s| {
                        try self.resolveStatement(s);
                    }
                    try self.table.leaveScope();
                }
            },
            .return_statement => |ret| {
                if (ret.value) |val| {
                    try self.resolveExpression(val);
                }
            },
            .break_statement => |brk| {
                if (brk.value) |val| {
                    try self.resolveExpression(val);
                }
            },
            .expression_statement => |expr| {
                try self.resolveExpression(expr);
            },
            .block => |block| {
                _ = try self.table.enterScope(.block);
                for (block) |*s| {
                    try self.resolveStatement(s);
                }
                try self.table.leaveScope();
            },
        }
    }

    /// Resolve an expression
    fn resolveExpression(self: *Resolver, expr: *const Expression) ResolveError!void {
        switch (expr.kind) {
            .identifier => |ident| {
                // Skip error for 'std' - it's a built-in namespace injected at runtime
                if (self.table.lookup(ident.name) == null and !std.mem.eql(u8, ident.name, "std")) {
                    try self.addError("Undefined identifier '{s}'", .{ident.name}, expr.span);
                }
            },
            .binary => |bin| {
                try self.resolveExpression(bin.left);
                try self.resolveExpression(bin.right);
            },
            .unary => |un| {
                try self.resolveExpression(un.operand);
            },
            .field_access => |fa| {
                try self.resolveExpression(fa.object);
            },
            .index_access => |ia| {
                try self.resolveExpression(ia.object);
                try self.resolveExpression(ia.index);
            },
            .tuple_access => |ta| {
                try self.resolveExpression(ta.tuple);
            },
            .function_call => |fc| {
                try self.resolveExpression(fc.callee);
                for (fc.arguments) |arg| {
                    try self.resolveExpression(arg);
                }
            },
            .method_call => |mc| {
                try self.resolveExpression(mc.object);
                for (mc.arguments) |arg| {
                    try self.resolveExpression(arg);
                }
            },
            .closure => |closure| {
                _ = try self.table.enterScope(.function);

                for (closure.parameters) |param| {
                    const param_sym = Symbol.variable(0, param.name, param.param_type, false, false, param.span);
                    _ = self.table.define(param_sym) catch {};
                }

                for (closure.body) |*stmt| {
                    try self.resolveStatement(stmt);
                }

                try self.table.leaveScope();
            },
            .match_expr => |match_expr| {
                try self.resolveExpression(match_expr.subject);
                for (match_expr.arms) |arm| {
                    _ = try self.table.enterScope(.block);
                    try self.resolvePattern(arm.pattern, null, false);
                    if (arm.guard) |guard| {
                        try self.resolveExpression(guard);
                    }
                    switch (arm.body) {
                        .expression => |e| try self.resolveExpression(e),
                        .block => |block| {
                            for (block) |*stmt| {
                                try self.resolveStatement(stmt);
                            }
                        },
                    }
                    try self.table.leaveScope();
                }
            },
            .if_expr => |if_expr| {
                try self.resolveExpression(if_expr.condition);
                // Resolve then branch
                _ = try self.table.enterScope(.block);
                switch (if_expr.then_branch) {
                    .expression => |e| try self.resolveExpression(e),
                    .block => |block| {
                        for (block) |*stmt| {
                            try self.resolveStatement(stmt);
                        }
                    },
                }
                try self.table.leaveScope();
                // Resolve else branch
                _ = try self.table.enterScope(.block);
                switch (if_expr.else_branch) {
                    .expression => |e| try self.resolveExpression(e),
                    .block => |block| {
                        for (block) |*stmt| {
                            try self.resolveStatement(stmt);
                        }
                    },
                }
                try self.table.leaveScope();
            },
            .tuple_literal => |tl| {
                for (tl.elements) |elem| {
                    try self.resolveExpression(elem);
                }
            },
            .array_literal => |al| {
                for (al.elements) |elem| {
                    try self.resolveExpression(elem);
                }
            },
            .record_literal => |rl| {
                if (rl.type_name) |tn| {
                    try self.resolveExpression(tn);
                }
                for (rl.fields) |field| {
                    try self.resolveExpression(field.value);
                }
            },
            .variant_constructor => |vc| {
                // Variant constructors are checked during type checking
                if (vc.arguments) |args| {
                    for (args) |arg| {
                        try self.resolveExpression(arg);
                    }
                }
            },
            .type_cast => |tc| {
                try self.resolveExpression(tc.expression);
            },
            .range => |range| {
                if (range.start) |start| {
                    try self.resolveExpression(start);
                }
                if (range.end) |end| {
                    try self.resolveExpression(end);
                }
            },
            .grouped => |g| {
                try self.resolveExpression(g);
            },
            .interpolated_string => |is| {
                for (is.parts) |part| {
                    switch (part) {
                        .expression => |e| try self.resolveExpression(e),
                        .literal => {},
                    }
                }
            },
            .try_expr => |te| {
                try self.resolveExpression(te);
            },
            .null_coalesce => |nc| {
                try self.resolveExpression(nc.left);
                try self.resolveExpression(nc.default);
            },
            // Literals and simple expressions don't need resolution
            .integer_literal,
            .float_literal,
            .string_literal,
            .char_literal,
            .bool_literal,
            .self_expr,
            .self_type_expr,
            => {},
        }
    }

    /// Resolve a pattern, adding any bound variables to scope
    fn resolvePattern(
        self: *Resolver,
        pattern: *const Pattern,
        explicit_type: ?*Type,
        _: bool,
    ) ResolveError!void {
        switch (pattern.kind) {
            .identifier => |ident| {
                // Create a placeholder type if none provided
                const binding_type = explicit_type orelse blk: {
                    // Type will be inferred by type checker
                    var inferred = Type.init(.{ .inferred = {} }, pattern.span);
                    break :blk &inferred;
                };

                const sym = Symbol.variable(0, ident.name, binding_type, ident.is_mutable, false, pattern.span);
                _ = self.table.define(sym) catch |err| {
                    if (err == error.DuplicateDefinition) {
                        try self.addError("Duplicate binding '{s}'", .{ident.name}, pattern.span);
                    }
                    return err;
                };
            },
            .constructor => |ctor| {
                // Verify constructor exists (check type name if provided)
                if (ctor.type_path) |path| {
                    if (path.len > 0) {
                        if (self.table.lookup(path[0]) == null) {
                            try self.addError("Unknown type '{s}'", .{path[0]}, pattern.span);
                        }
                    }
                }
                if (ctor.arguments) |args| {
                    for (args) |arg| {
                        switch (arg) {
                            .positional => |p| try self.resolvePattern(p, null, false),
                            .named => |n| try self.resolvePattern(n.pattern, null, false),
                        }
                    }
                }
            },
            .record => |rp| {
                if (rp.type_name) |tn| {
                    if (self.table.lookup(tn) == null) {
                        try self.addError("Unknown type '{s}'", .{tn}, pattern.span);
                    }
                }
                for (rp.fields) |field| {
                    if (field.pattern) |pat| {
                        try self.resolvePattern(pat, null, false);
                    } else {
                        // Shorthand: { x } binds x
                        var inferred = Type.init(.{ .inferred = {} }, field.span);
                        const sym = Symbol.variable(0, field.name, &inferred, false, false, field.span);
                        _ = self.table.define(sym) catch |err| {
                            if (err == error.DuplicateDefinition) {
                                try self.addError("Duplicate binding '{s}'", .{field.name}, field.span);
                            }
                            return err;
                        };
                    }
                }
            },
            .tuple => |tp| {
                for (tp.elements) |elem| {
                    try self.resolvePattern(elem, null, false);
                }
            },
            .or_pattern => |op| {
                // All alternatives must bind the same names
                for (op.patterns) |alt| {
                    try self.resolvePattern(alt, null, false);
                }
            },
            .guarded => |g| {
                try self.resolvePattern(g.pattern, explicit_type, false);
                try self.resolveExpression(g.guard);
            },
            .typed => |t| {
                try self.resolvePattern(t.pattern, t.expected_type, false);
            },
            // Literals, wildcards, rest, and ranges don't bind
            .wildcard,
            .rest,
            .range,
            .integer_literal,
            .float_literal,
            .string_literal,
            .char_literal,
            .bool_literal,
            => {},
        }
    }

    // ========== Diagnostic Helpers ==========

    fn addError(
        self: *Resolver,
        comptime fmt: []const u8,
        args: anytype,
        span: Span,
    ) ResolveError!void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
        const msg_copy = try self.allocator.dupe(u8, msg);

        try self.diagnostics.append(self.allocator, .{
            .message = msg_copy,
            .span = span,
            .kind = .err,
        });
    }

    fn addWarning(
        self: *Resolver,
        comptime fmt: []const u8,
        args: anytype,
        span: Span,
    ) ResolveError!void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
        const msg_copy = try self.allocator.dupe(u8, msg);

        try self.diagnostics.append(self.allocator, .{
            .message = msg_copy,
            .span = span,
            .kind = .warning,
        });
    }

    /// Check if there were any errors
    pub fn hasErrors(self: *Resolver) bool {
        for (self.diagnostics.items) |d| {
            if (d.kind == .err) return true;
        }
        return false;
    }

    /// Get all diagnostics
    pub fn getDiagnostics(self: *Resolver) []const Diagnostic {
        return self.diagnostics.items;
    }
};

test "resolver basic function" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var resolver = Resolver.init(allocator, &table);
    defer resolver.deinit();

    // The resolver is ready to use
    try std.testing.expect(!resolver.hasErrors());
}

test "resolver undefined identifier in expression" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var resolver = Resolver.init(allocator, &table);
    defer resolver.deinit();

    // Create a simple expression with an undefined identifier
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };
    const ident_expr = Expression.init(.{ .identifier = .{
        .name = "undefined_var",
        .generic_args = null,
    } }, span);

    // This should add an error diagnostic
    try resolver.resolveExpression(&ident_expr);

    // Should have an error now
    try std.testing.expect(resolver.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), resolver.diagnostics.items.len);
}

test "resolver catches undefined in full program" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var resolver = Resolver.init(allocator, &table);
    defer resolver.deinit();

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    // Create undefined identifier expression
    var ident_expr = Expression.init(.{ .identifier = .{
        .name = "undefined_var",
        .generic_args = null,
    } }, span);

    // Create a simple pattern
    var pattern = ast.Pattern.init(.{ .identifier = .{ .name = "x", .is_mutable = false } }, span);

    // Create a simple i64 type
    var i64_type = ast.Type.init(.{ .primitive = .i64 }, span);
    var return_type = ast.Type.init(.{ .primitive = .i64 }, span);

    // Create let binding statement
    const let_stmt = Statement.init(.{ .let_binding = .{
        .pattern = &pattern,
        .explicit_type = &i64_type,
        .initializer = &ident_expr,
        .is_public = false,
    } }, span);

    // Create function declaration with body
    var body = [_]Statement{let_stmt};
    const func_decl = Declaration.FunctionDecl{
        .name = "main",
        .generic_params = null,
        .parameters = &[_]Declaration.Parameter{},
        .return_type = &return_type,
        .is_effect = false,
        .is_public = false,
        .body = &body,
        .where_clause = null,
    };

    const decl = Declaration.init(.{ .function_decl = func_decl }, span);
    var declarations = [_]Declaration{decl};

    // Create the program
    const program = ast.Program{
        .module_decl = null,
        .imports = &[_]Declaration.ImportDecl{},
        .declarations = &declarations,
        .module_doc = null,
        .source_path = null,
        .arena = null,
    };

    // Resolve the program - should fail with ResolutionFailed
    const result = resolver.resolve(&program);
    try std.testing.expectError(error.ResolutionFailed, result);
    try std.testing.expect(resolver.hasErrors());
}

test "resolver catches undefined identifier in let binding" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var resolver = Resolver.init(allocator, &table);
    defer resolver.deinit();

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 20, .offset = 19 },
    };

    // Create undefined identifier expression
    var ident_expr = Expression.init(.{ .identifier = .{
        .name = "undefined_var",
        .generic_args = null,
    } }, span);

    // Create a simple pattern
    var pattern = ast.Pattern.init(.{ .identifier = .{ .name = "x", .is_mutable = false } }, span);

    // Create a simple i64 type
    var i64_type = ast.Type.init(.{ .primitive = .i64 }, span);

    // Create let binding statement
    var let_stmt = Statement.init(.{ .let_binding = .{
        .pattern = &pattern,
        .explicit_type = &i64_type,
        .initializer = &ident_expr,
        .is_public = false,
    } }, span);

    // Resolve the statement
    try resolver.resolveStatement(&let_stmt);

    // Should have an error for undefined_var
    try std.testing.expect(resolver.hasErrors());
}
