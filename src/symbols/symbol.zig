//! Symbol definitions for the Kira language.
//!
//! Symbols represent named entities in the program: variables, functions,
//! types, traits, and modules. Each symbol carries type information and
//! metadata about visibility and mutability.

const std = @import("std");
const ast = @import("../ast/root.zig");

pub const Type = ast.Type;
pub const Span = ast.Span;
pub const Declaration = ast.Declaration;

/// Unique identifier for a symbol
pub const SymbolId = u32;

/// Represents a symbol (named entity) in the Kira language.
pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    kind: SymbolKind,
    span: Span,
    is_public: bool,
    doc_comment: ?[]const u8,

    pub const SymbolKind = union(enum) {
        /// Variable binding (let or var)
        variable: VariableSymbol,

        /// Function declaration
        function: FunctionSymbol,

        /// Type definition (sum type, product type, alias)
        type_def: TypeDefSymbol,

        /// Trait definition
        trait_def: TraitDefSymbol,

        /// Module
        module: ModuleSymbol,

        /// Generic type parameter
        type_param: TypeParamSymbol,

        /// Imported symbol (alias to another symbol)
        import_alias: ImportAliasSymbol,
    };

    /// Variable symbol (let or var binding)
    pub const VariableSymbol = struct {
        binding_type: *Type,
        is_mutable: bool, // var vs let
        is_initialized: bool,
    };

    /// Function symbol
    pub const FunctionSymbol = struct {
        generic_params: ?[]GenericParamInfo,
        parameter_types: []*Type,
        parameter_names: [][]const u8,
        return_type: *Type,
        is_effect: bool,
        has_body: bool, // false for trait method signatures
    };

    /// Generic parameter info for functions and types
    pub const GenericParamInfo = struct {
        name: []const u8,
        constraints: ?[][]const u8, // Trait bounds
    };

    /// Type definition symbol
    pub const TypeDefSymbol = struct {
        generic_params: ?[]GenericParamInfo,
        definition: TypeDefKind,
    };

    /// Kind of type definition
    pub const TypeDefKind = union(enum) {
        /// Sum type (tagged union / ADT)
        sum_type: SumTypeInfo,
        /// Product type (record/struct)
        product_type: ProductTypeInfo,
        /// Type alias
        alias: *Type,
    };

    /// Sum type information
    pub const SumTypeInfo = struct {
        variants: []VariantInfo,
    };

    /// Variant information for sum types
    pub const VariantInfo = struct {
        name: []const u8,
        fields: ?VariantFields,
        span: Span,
    };

    /// Variant fields (tuple-style or record-style)
    pub const VariantFields = union(enum) {
        tuple_fields: []*Type,
        record_fields: []RecordFieldInfo,
    };

    /// Record field information
    pub const RecordFieldInfo = struct {
        name: []const u8,
        field_type: *Type,
        span: Span,
    };

    /// Product type information
    pub const ProductTypeInfo = struct {
        fields: []RecordFieldInfo,
    };

    /// Trait definition symbol
    pub const TraitDefSymbol = struct {
        generic_params: ?[]GenericParamInfo,
        super_traits: ?[][]const u8,
        methods: []TraitMethodInfo,
    };

    /// Trait method information
    pub const TraitMethodInfo = struct {
        name: []const u8,
        generic_params: ?[]GenericParamInfo,
        parameter_types: []*Type,
        parameter_names: [][]const u8,
        return_type: *Type,
        is_effect: bool,
        has_default: bool,
        span: Span,
    };

    /// Module symbol
    pub const ModuleSymbol = struct {
        path: [][]const u8,
        /// Child scope containing module members
        scope_id: ?ScopeId,
    };

    /// Type parameter symbol (for generics)
    pub const TypeParamSymbol = struct {
        constraints: ?[][]const u8,
    };

    /// Import alias symbol
    pub const ImportAliasSymbol = struct {
        /// Full path to the imported symbol
        source_path: [][]const u8,
        /// The resolved symbol id (if resolved)
        resolved_id: ?SymbolId,
    };

    /// Create a new variable symbol
    pub fn variable(
        id: SymbolId,
        name: []const u8,
        binding_type: *Type,
        is_mutable: bool,
        is_public: bool,
        span: Span,
    ) Symbol {
        return .{
            .id = id,
            .name = name,
            .kind = .{ .variable = .{
                .binding_type = binding_type,
                .is_mutable = is_mutable,
                .is_initialized = true,
            } },
            .span = span,
            .is_public = is_public,
            .doc_comment = null,
        };
    }

    /// Create a new function symbol
    pub fn function(
        id: SymbolId,
        name: []const u8,
        func: FunctionSymbol,
        is_public: bool,
        span: Span,
    ) Symbol {
        return .{
            .id = id,
            .name = name,
            .kind = .{ .function = func },
            .span = span,
            .is_public = is_public,
            .doc_comment = null,
        };
    }

    /// Create a new type definition symbol
    pub fn typeDef(
        id: SymbolId,
        name: []const u8,
        type_def: TypeDefSymbol,
        is_public: bool,
        span: Span,
    ) Symbol {
        return .{
            .id = id,
            .name = name,
            .kind = .{ .type_def = type_def },
            .span = span,
            .is_public = is_public,
            .doc_comment = null,
        };
    }

    /// Create a new trait definition symbol
    pub fn traitDef(
        id: SymbolId,
        name: []const u8,
        trait_def: TraitDefSymbol,
        is_public: bool,
        span: Span,
    ) Symbol {
        return .{
            .id = id,
            .name = name,
            .kind = .{ .trait_def = trait_def },
            .span = span,
            .is_public = is_public,
            .doc_comment = null,
        };
    }

    /// Check if this symbol represents a type
    pub fn isType(self: Symbol) bool {
        return switch (self.kind) {
            .type_def, .type_param => true,
            else => false,
        };
    }

    /// Check if this symbol is callable
    pub fn isCallable(self: Symbol) bool {
        return switch (self.kind) {
            .function => true,
            .variable => |v| v.binding_type.kind == .function,
            else => false,
        };
    }

    /// Free all nested allocations in this symbol.
    ///
    /// This frees the slices created by toOwnedSlice() during symbol resolution.
    /// The contents of these slices (strings, type pointers) point to AST data
    /// owned by the program arena and are NOT freed here.
    pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .function => |func| {
                // Free the slice containers (not their string/type contents)
                if (func.generic_params) |gp| {
                    allocator.free(gp);
                }
                if (func.parameter_types.len > 0) {
                    allocator.free(func.parameter_types);
                }
                if (func.parameter_names.len > 0) {
                    allocator.free(func.parameter_names);
                }
            },
            .type_def => |td| {
                if (td.generic_params) |gp| {
                    allocator.free(gp);
                }
                switch (td.definition) {
                    .sum_type => |st| {
                        // Free record_fields slices inside variants
                        for (st.variants) |v| {
                            if (v.fields) |fields| {
                                switch (fields) {
                                    .record_fields => |rf| {
                                        if (rf.len > 0) {
                                            allocator.free(rf);
                                        }
                                    },
                                    .tuple_fields => {}, // Points to AST, don't free
                                }
                            }
                        }
                        // Free the variants slice itself
                        if (st.variants.len > 0) {
                            allocator.free(st.variants);
                        }
                    },
                    .product_type => |pt| {
                        if (pt.fields.len > 0) {
                            allocator.free(pt.fields);
                        }
                    },
                    .alias => {}, // Points to AST, don't free
                }
            },
            .trait_def => |trait| {
                if (trait.generic_params) |gp| {
                    allocator.free(gp);
                }
                // Free nested allocations in each method
                for (trait.methods) |m| {
                    if (m.generic_params) |mgp| {
                        allocator.free(mgp);
                    }
                    if (m.parameter_types.len > 0) {
                        allocator.free(m.parameter_types);
                    }
                    if (m.parameter_names.len > 0) {
                        allocator.free(m.parameter_names);
                    }
                }
                // Free the methods slice itself
                if (trait.methods.len > 0) {
                    allocator.free(trait.methods);
                }
            },
            // These don't have owned slice allocations
            .variable, .module, .type_param, .import_alias => {},
        }
    }
};

/// Scope identifier
pub const ScopeId = u32;

test "symbol creation" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    // Create a dummy type for testing
    var int_type = Type.primitive(.i32, span);

    const sym = Symbol.variable(
        0,
        "x",
        &int_type,
        false,
        false,
        span,
    );

    try std.testing.expectEqual(@as(SymbolId, 0), sym.id);
    try std.testing.expectEqualStrings("x", sym.name);
    try std.testing.expect(!sym.is_public);
    try std.testing.expect(!sym.isType());
}
