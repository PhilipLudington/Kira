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
    /// NOTE: This function is intentionally conservative about freeing memory.
    /// Some arrays (like parameter_types, parameter_names) are allocated by the
    /// resolver using toOwnedSlice(), but their contents (the actual types and
    /// names) point to AST data owned by the program arena.
    ///
    /// Due to complex ownership patterns between the symbol table, resolver,
    /// type checker, and program arena, we only free top-level arrays that we
    /// are confident are solely owned by the symbol table.
    pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // All symbol memory is owned by the program arena allocator.
        // Attempting to free here causes double-free on exit.
        // The arena frees everything at once when the program ends.
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
