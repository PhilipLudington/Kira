//! Scope management for the Kira language.
//!
//! Scopes represent lexical regions where names are defined. They form a tree
//! structure where child scopes can access names from parent scopes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const symbol_mod = @import("symbol.zig");

pub const Symbol = symbol_mod.Symbol;
pub const SymbolId = symbol_mod.SymbolId;
pub const ScopeId = symbol_mod.ScopeId;

/// The kind of scope
pub const ScopeKind = enum {
    /// Global/module scope
    global,
    /// Module scope (can contain public exports)
    module,
    /// Function body scope
    function,
    /// Block scope (if, for, match arm, etc.)
    block,
    /// Trait definition scope
    trait_def,
    /// Impl block scope
    impl_block,
    /// Generic scope (type parameters)
    generic,
};

/// A lexical scope containing symbol definitions.
pub const Scope = struct {
    id: ScopeId,
    kind: ScopeKind,
    parent_id: ?ScopeId,
    /// Symbols defined directly in this scope (name -> symbol id)
    symbols: std.StringHashMapUnmanaged(SymbolId),
    /// Child scope IDs
    children: std.ArrayListUnmanaged(ScopeId),

    /// Create a new scope
    pub fn init(id: ScopeId, kind: ScopeKind, parent_id: ?ScopeId) Scope {
        return .{
            .id = id,
            .kind = kind,
            .parent_id = parent_id,
            .symbols = .{},
            .children = .{},
        };
    }

    /// Free all resources
    pub fn deinit(self: *Scope, allocator: Allocator) void {
        self.symbols.deinit(allocator);
        self.children.deinit(allocator);
    }

    /// Define a symbol in this scope
    /// Returns error if name already exists
    pub fn define(
        self: *Scope,
        allocator: Allocator,
        name: []const u8,
        symbol_id: SymbolId,
    ) !void {
        const result = try self.symbols.getOrPut(allocator, name);
        if (result.found_existing) {
            return error.DuplicateDefinition;
        }
        result.value_ptr.* = symbol_id;
    }

    /// Look up a symbol by name in this scope only (no parent lookup)
    pub fn lookupLocal(self: Scope, name: []const u8) ?SymbolId {
        return self.symbols.get(name);
    }

    /// Check if a name is defined in this scope
    pub fn contains(self: Scope, name: []const u8) bool {
        return self.symbols.contains(name);
    }

    /// Add a child scope
    pub fn addChild(self: *Scope, allocator: Allocator, child_id: ScopeId) !void {
        try self.children.append(allocator, child_id);
    }

    /// Get all symbol names in this scope
    pub fn symbolNames(self: Scope, allocator: Allocator) ![][]const u8 {
        var names = std.ArrayListUnmanaged([]const u8){};
        var it = self.symbols.keyIterator();
        while (it.next()) |key| {
            try names.append(allocator, key.*);
        }
        return names.toOwnedSlice(allocator);
    }
};

test "scope basic operations" {
    const allocator = std.testing.allocator;

    var scope = Scope.init(0, .block, null);
    defer scope.deinit(allocator);

    // Define a symbol
    try scope.define(allocator, "x", 1);
    try std.testing.expectEqual(@as(?SymbolId, 1), scope.lookupLocal("x"));

    // Duplicate should fail
    try std.testing.expectError(error.DuplicateDefinition, scope.define(allocator, "x", 2));

    // Undefined should return null
    try std.testing.expect(scope.lookupLocal("y") == null);
}

test "scope child management" {
    const allocator = std.testing.allocator;

    var parent = Scope.init(0, .function, null);
    defer parent.deinit(allocator);

    try parent.addChild(allocator, 1);
    try parent.addChild(allocator, 2);

    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try std.testing.expectEqual(@as(ScopeId, 1), parent.children.items[0]);
    try std.testing.expectEqual(@as(ScopeId, 2), parent.children.items[1]);
}
