//! Symbol Table for the Kira language.
//!
//! The symbol table manages all symbols and scopes in the program.
//! It provides lookup with proper scoping rules, including shadowing
//! and visibility checks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const symbol_mod = @import("symbol.zig");
const scope_mod = @import("scope.zig");
const ast = @import("../ast/root.zig");

pub const Symbol = symbol_mod.Symbol;
pub const SymbolId = symbol_mod.SymbolId;
pub const ScopeId = symbol_mod.ScopeId;
pub const Scope = scope_mod.Scope;
pub const ScopeKind = scope_mod.ScopeKind;
pub const Span = ast.Span;
pub const Type = ast.Type;

/// Errors that can occur during symbol table operations
pub const SymbolError = error{
    DuplicateDefinition,
    UndefinedSymbol,
    InvalidScope,
    VisibilityViolation,
    OutOfMemory,
};

/// The symbol table managing all symbols and scopes
pub const SymbolTable = struct {
    allocator: Allocator,
    /// All symbols indexed by ID
    symbols: std.ArrayListUnmanaged(Symbol),
    /// All scopes indexed by ID
    scopes: std.ArrayListUnmanaged(Scope),
    /// The current scope ID
    current_scope_id: ScopeId,
    /// Module path -> scope ID mapping
    module_scopes: std.StringHashMapUnmanaged(ScopeId),
    /// Trait implementations: (trait_name, type_name) -> impl info
    implementations: std.ArrayListUnmanaged(ImplInfo),

    /// Information about a trait implementation
    pub const ImplInfo = struct {
        trait_name: ?[]const u8, // null for inherent impls
        target_type: *Type,
        methods: []SymbolId,
        scope_id: ScopeId,
        span: Span,
    };

    /// Create a new symbol table
    pub fn init(allocator: Allocator) SymbolTable {
        var table = SymbolTable{
            .allocator = allocator,
            .symbols = .{},
            .scopes = .{},
            .current_scope_id = 0,
            .module_scopes = .{},
            .implementations = .{},
        };

        // Create global scope
        table.scopes.append(allocator, Scope.init(0, .global, null)) catch unreachable;

        return table;
    }

    /// Free all resources
    pub fn deinit(self: *SymbolTable) void {
        // Free nested allocations in each symbol
        for (self.symbols.items) |*sym| {
            sym.deinit(self.allocator);
        }
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);

        // Free the string keys in module_scopes (duped in registerModule, owned by table)
        var key_iter = self.module_scopes.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.module_scopes.deinit(self.allocator);

        // Free the methods arrays in implementations
        for (self.implementations.items) |impl| {
            if (impl.methods.len > 0) {
                self.allocator.free(impl.methods);
            }
        }
        self.implementations.deinit(self.allocator);
    }

    // ========== Scope Management ==========

    /// Enter a new scope
    pub fn enterScope(self: *SymbolTable, kind: ScopeKind) !ScopeId {
        const new_id: ScopeId = @intCast(self.scopes.items.len);
        const new_scope = Scope.init(new_id, kind, self.current_scope_id);

        // Add as child of current scope
        try self.currentScope().addChild(self.allocator, new_id);

        try self.scopes.append(self.allocator, new_scope);
        self.current_scope_id = new_id;

        return new_id;
    }

    /// Leave the current scope, returning to parent
    pub fn leaveScope(self: *SymbolTable) !void {
        const current = self.currentScope();
        if (current.parent_id) |parent_id| {
            self.current_scope_id = parent_id;
        } else {
            return error.InvalidScope;
        }
    }

    /// Get the current scope
    pub fn currentScope(self: *SymbolTable) *Scope {
        return &self.scopes.items[self.current_scope_id];
    }

    /// Get a scope by ID
    pub fn getScope(self: *SymbolTable, id: ScopeId) ?*Scope {
        if (id >= self.scopes.items.len) return null;
        return &self.scopes.items[id];
    }

    /// Get the global scope
    pub fn globalScope(self: *SymbolTable) *Scope {
        return &self.scopes.items[0];
    }

    /// Set the current scope directly (for module/import resolution)
    pub fn setCurrentScope(self: *SymbolTable, scope_id: ScopeId) !void {
        if (scope_id >= self.scopes.items.len) {
            return error.InvalidScope;
        }
        self.current_scope_id = scope_id;
    }

    // ========== Symbol Definition ==========

    /// Define a new symbol in the current scope
    pub fn define(self: *SymbolTable, sym: Symbol) !SymbolId {
        const id: SymbolId = @intCast(self.symbols.items.len);

        // Check for duplicate in current scope
        const current = self.currentScope();
        if (current.contains(sym.name)) {
            return error.DuplicateDefinition;
        }

        // Add to symbols list
        var new_sym = sym;
        new_sym.id = id;
        try self.symbols.append(self.allocator, new_sym);

        // Add to current scope
        try current.define(self.allocator, sym.name, id);

        return id;
    }

    /// Define a symbol in a specific scope
    pub fn defineInScope(self: *SymbolTable, scope_id: ScopeId, sym: Symbol) !SymbolId {
        const scope = self.getScope(scope_id) orelse return error.InvalidScope;
        const id: SymbolId = @intCast(self.symbols.items.len);

        // Check for duplicate
        if (scope.contains(sym.name)) {
            return error.DuplicateDefinition;
        }

        // Add to symbols list
        var new_sym = sym;
        new_sym.id = id;
        try self.symbols.append(self.allocator, new_sym);

        // Add to specified scope
        try scope.define(self.allocator, sym.name, id);

        return id;
    }

    // ========== Symbol Lookup ==========

    /// Look up a symbol by name, searching up through parent scopes
    pub fn lookup(self: *SymbolTable, name: []const u8) ?*Symbol {
        var scope_id: ?ScopeId = self.current_scope_id;

        while (scope_id) |id| {
            const scope = &self.scopes.items[id];
            if (scope.lookupLocal(name)) |symbol_id| {
                return &self.symbols.items[symbol_id];
            }
            scope_id = scope.parent_id;
        }

        return null;
    }

    /// Look up a symbol only in the current scope (no parent search)
    pub fn lookupLocal(self: *SymbolTable, name: []const u8) ?*Symbol {
        if (self.currentScope().lookupLocal(name)) |symbol_id| {
            return &self.symbols.items[symbol_id];
        }
        return null;
    }

    /// Look up a symbol in a specific scope
    pub fn lookupInScope(self: *SymbolTable, scope_id: ScopeId, name: []const u8) ?*Symbol {
        const scope = self.getScope(scope_id) orelse return null;
        if (scope.lookupLocal(name)) |symbol_id| {
            return &self.symbols.items[symbol_id];
        }
        return null;
    }

    /// Look up a symbol by path (e.g., ["std", "list", "List"])
    pub fn lookupPath(self: *SymbolTable, path: [][]const u8) ?*Symbol {
        if (path.len == 0) return null;

        // Start from global scope for absolute paths
        var current_scope_id: ScopeId = 0;

        // Navigate through modules
        for (path[0 .. path.len - 1]) |segment| {
            const scope = &self.scopes.items[current_scope_id];
            if (scope.lookupLocal(segment)) |symbol_id| {
                const sym = &self.symbols.items[symbol_id];
                switch (sym.kind) {
                    .module => |mod| {
                        if (mod.scope_id) |mod_scope_id| {
                            current_scope_id = mod_scope_id;
                        } else {
                            return null;
                        }
                    },
                    else => return null,
                }
            } else {
                return null;
            }
        }

        // Look up final name in the reached scope
        return self.lookupInScope(current_scope_id, path[path.len - 1]);
    }

    /// Get a symbol by ID
    pub fn getSymbol(self: *SymbolTable, id: SymbolId) ?*Symbol {
        if (id >= self.symbols.items.len) return null;
        return &self.symbols.items[id];
    }

    // ========== Module Management ==========

    /// Register a module scope for cross-module lookups.
    /// The path is duped internally - caller retains ownership of the original.
    pub fn registerModule(self: *SymbolTable, path: []const u8, scope_id: ScopeId) !void {
        // Check if this path already exists - if so, just update the value without duping
        if (self.module_scopes.contains(path)) {
            try self.module_scopes.put(self.allocator, path, scope_id);
            return;
        }
        // Dupe the key so we have ownership and can safely free it in deinit
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.module_scopes.put(self.allocator, owned_path, scope_id);
    }

    /// Get a module's scope by path
    pub fn getModuleScope(self: *SymbolTable, path: []const u8) ?ScopeId {
        return self.module_scopes.get(path);
    }

    // ========== Trait Implementation Management ==========

    /// Register a trait implementation
    pub fn registerImpl(self: *SymbolTable, info: ImplInfo) !void {
        try self.implementations.append(self.allocator, info);
    }

    /// Find implementations for a given type
    pub fn findImplementations(
        self: *SymbolTable,
        allocator: Allocator,
        type_name: []const u8,
    ) ![]ImplInfo {
        var result = std.ArrayListUnmanaged(ImplInfo){};

        for (self.implementations.items) |impl| {
            // Simple name matching for now
            // TODO: proper type comparison
            switch (impl.target_type.kind) {
                .named => |n| {
                    if (std.mem.eql(u8, n.name, type_name)) {
                        try result.append(allocator, impl);
                    }
                },
                else => {},
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Find a specific trait implementation for a type
    pub fn findTraitImpl(
        self: *SymbolTable,
        trait_name: []const u8,
        type_name: []const u8,
    ) ?ImplInfo {
        for (self.implementations.items) |impl| {
            if (impl.trait_name) |tn| {
                if (!std.mem.eql(u8, tn, trait_name)) continue;

                switch (impl.target_type.kind) {
                    .named => |n| {
                        if (std.mem.eql(u8, n.name, type_name)) {
                            return impl;
                        }
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    // ========== Visibility Checking ==========

    /// Check if a symbol is accessible from the current scope
    pub fn isAccessible(self: *SymbolTable, symbol: *Symbol) bool {
        // Public symbols are always accessible
        if (symbol.is_public) return true;

        // Check if symbol is in current scope or ancestor
        const symbol_scope_id = self.findSymbolScope(symbol.id) orelse return false;

        var scope_id: ?ScopeId = self.current_scope_id;
        while (scope_id) |id| {
            if (id == symbol_scope_id) return true;

            // Check if we're in the same module
            const scope = &self.scopes.items[id];
            if (scope.kind == .module and symbol_scope_id == id) {
                return true;
            }

            scope_id = scope.parent_id;
        }

        return false;
    }

    /// Find which scope contains a symbol
    fn findSymbolScope(self: *SymbolTable, symbol_id: SymbolId) ?ScopeId {
        for (self.scopes.items, 0..) |scope, i| {
            var it = scope.symbols.valueIterator();
            while (it.next()) |id| {
                if (id.* == symbol_id) {
                    return @intCast(i);
                }
            }
        }
        return null;
    }

    // ========== Utility Functions ==========

    /// Get all public symbols from a scope
    pub fn getPublicSymbols(
        self: *SymbolTable,
        allocator: Allocator,
        scope_id: ScopeId,
    ) ![]Symbol {
        const scope = self.getScope(scope_id) orelse return error.InvalidScope;
        var result = std.ArrayListUnmanaged(Symbol){};

        var it = scope.symbols.valueIterator();
        while (it.next()) |symbol_id| {
            const sym = &self.symbols.items[symbol_id.*];
            if (sym.is_public) {
                try result.append(allocator, sym.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Check if we're inside an effect function
    pub fn isInEffectFunction(self: *SymbolTable) bool {
        var scope_id: ?ScopeId = self.current_scope_id;

        while (scope_id) |id| {
            const scope = &self.scopes.items[id];
            if (scope.kind == .function) {
                // Find the function symbol for this scope
                if (scope.parent_id) |parent_id| {
                    const parent = &self.scopes.items[parent_id];
                    var it = parent.symbols.valueIterator();
                    while (it.next()) |symbol_id| {
                        const sym = &self.symbols.items[symbol_id.*];
                        if (sym.kind == .function) {
                            return sym.kind.function.is_effect;
                        }
                    }
                }
            }
            scope_id = scope.parent_id;
        }

        return false;
    }

    /// Debug: Print the symbol table structure
    pub fn debugPrint(self: *SymbolTable, writer: anytype) !void {
        try writer.print("=== Symbol Table ===\n", .{});
        try writer.print("Total symbols: {d}\n", .{self.symbols.items.len});
        try writer.print("Total scopes: {d}\n", .{self.scopes.items.len});
        try writer.print("Current scope: {d}\n\n", .{self.current_scope_id});

        for (self.scopes.items, 0..) |scope, i| {
            try writer.print("Scope {d} ({s}):\n", .{ i, @tagName(scope.kind) });
            if (scope.parent_id) |pid| {
                try writer.print("  Parent: {d}\n", .{pid});
            }
            try writer.print("  Symbols:\n", .{});

            var it = scope.symbols.iterator();
            while (it.next()) |entry| {
                const sym = &self.symbols.items[entry.value_ptr.*];
                try writer.print("    {s}: {s} (id={d}, pub={s})\n", .{
                    entry.key_ptr.*,
                    @tagName(sym.kind),
                    sym.id,
                    if (sym.is_public) "yes" else "no",
                });
            }
            try writer.print("\n", .{});
        }
    }
};

test "symbol table basic operations" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    // Define a variable in global scope
    var int_type = Type.primitive(.i32, span);
    const sym = Symbol.variable(0, "x", &int_type, false, false, span);
    const id = try table.define(sym);

    try std.testing.expectEqual(@as(SymbolId, 0), id);

    // Look it up
    const found = table.lookup("x");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("x", found.?.name);

    // Undefined symbol
    try std.testing.expect(table.lookup("y") == null);
}

test "symbol table nested scopes" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var int_type = Type.primitive(.i32, span);

    // Define x in global scope
    _ = try table.define(Symbol.variable(0, "x", &int_type, false, false, span));

    // Enter a function scope
    _ = try table.enterScope(.function);

    // Define y in function scope
    _ = try table.define(Symbol.variable(0, "y", &int_type, false, false, span));

    // Can see both x (from parent) and y (local)
    try std.testing.expect(table.lookup("x") != null);
    try std.testing.expect(table.lookup("y") != null);

    // Leave function scope
    try table.leaveScope();

    // Can still see x
    try std.testing.expect(table.lookup("x") != null);
    // Cannot see y anymore
    try std.testing.expect(table.lookup("y") == null);
}

test "symbol table shadowing" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var int_type = Type.primitive(.i32, span);
    var str_type = Type.primitive(.string, span);

    // Define x as i32 in global scope
    _ = try table.define(Symbol.variable(0, "x", &int_type, false, false, span));

    // Enter block scope
    _ = try table.enterScope(.block);

    // Define x as string in block scope (shadows outer x)
    _ = try table.define(Symbol.variable(0, "x", &str_type, false, false, span));

    // Should find the inner x (string)
    const inner_x = table.lookup("x");
    try std.testing.expect(inner_x != null);
    try std.testing.expect(inner_x.?.kind.variable.binding_type.kind == .primitive);
    try std.testing.expectEqual(Type.PrimitiveType.string, inner_x.?.kind.variable.binding_type.kind.primitive);

    // Leave block scope
    try table.leaveScope();

    // Should find the outer x (i32)
    const outer_x = table.lookup("x");
    try std.testing.expect(outer_x != null);
    try std.testing.expectEqual(Type.PrimitiveType.i32, outer_x.?.kind.variable.binding_type.kind.primitive);
}

test "symbol table duplicate detection" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var int_type = Type.primitive(.i32, span);

    // Define x
    _ = try table.define(Symbol.variable(0, "x", &int_type, false, false, span));

    // Try to define x again - should fail
    try std.testing.expectError(
        error.DuplicateDefinition,
        table.define(Symbol.variable(0, "x", &int_type, false, false, span)),
    );
}
