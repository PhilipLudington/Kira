//! Declaration AST nodes for the Kira language.
//!
//! Declarations introduce new names: functions, types, traits, modules, etc.

const std = @import("std");
const lexer = @import("../lexer/root.zig");

pub const Span = lexer.Span;
pub const Type = @import("types.zig").Type;
pub const Expression = @import("expression.zig").Expression;
pub const Statement = @import("statement.zig").Statement;

/// Represents a top-level declaration in the Kira language.
pub const Declaration = struct {
    kind: DeclarationKind,
    span: Span,
    doc_comment: ?[]const u8,

    pub const DeclarationKind = union(enum) {
        // Function-related
        function_decl: FunctionDecl,

        // Type definitions
        type_decl: TypeDecl,

        // Trait and impl
        trait_decl: TraitDecl,
        impl_block: ImplBlock,

        // Module system
        module_decl: ModuleDecl,
        import_decl: ImportDecl,

        // Constants
        const_decl: ConstDecl,

        // Top-level let binding (for functions as values)
        let_decl: LetDecl,

        // Test declaration
        test_decl: TestDecl,
    };

    /// Function declaration
    /// `fn name[T](params) -> ReturnType { body }`
    /// or `effect fn name[T](params) -> IO[ReturnType] { body }`
    pub const FunctionDecl = struct {
        name: []const u8,
        generic_params: ?[]GenericParam,
        parameters: []Parameter,
        return_type: *Type,
        is_effect: bool,
        is_public: bool,
        body: ?[]Statement, // None for trait method signatures
        where_clause: ?[]WhereConstraint,
    };

    /// Generic type parameter with optional constraints
    pub const GenericParam = struct {
        name: []const u8,
        constraints: ?[][]const u8, // Trait bounds
        span: Span,
    };

    /// Function parameter
    pub const Parameter = struct {
        name: []const u8,
        param_type: *Type,
        span: Span,
    };

    /// Where clause constraint
    pub const WhereConstraint = struct {
        type_param: []const u8,
        bounds: [][]const u8,
        span: Span,
    };

    /// Type declaration
    /// Sum type: `type Option[T] = | Some(T) | None`
    /// Product type: `type Point = { x: f64, y: f64 }`
    pub const TypeDecl = struct {
        name: []const u8,
        generic_params: ?[]GenericParam,
        definition: TypeDefinition,
        is_public: bool,
    };

    /// Type definition (sum or product type)
    pub const TypeDefinition = union(enum) {
        sum_type: SumType,
        product_type: ProductType,
        type_alias: *Type,
    };

    /// Sum type (tagged union / ADT)
    /// `| Variant1(T) | Variant2 | Variant3(A, B)`
    pub const SumType = struct {
        variants: []Variant,
    };

    /// Sum type variant
    pub const Variant = struct {
        name: []const u8,
        fields: ?VariantFields,
        span: Span,
    };

    /// Variant fields (tuple-style or record-style)
    pub const VariantFields = union(enum) {
        tuple_fields: []*Type, // Some(T) -> tuple_fields = [T]
        record_fields: []RecordField, // Some { value: T } -> record_fields
    };

    /// Product type (record/struct)
    /// `{ field1: Type1, field2: Type2 }`
    pub const ProductType = struct {
        fields: []RecordField,
    };

    /// Record field
    pub const RecordField = struct {
        name: []const u8,
        field_type: *Type,
        span: Span,
    };

    /// Trait declaration
    /// `trait Name { ... }`
    pub const TraitDecl = struct {
        name: []const u8,
        generic_params: ?[]GenericParam,
        super_traits: ?[][]const u8, // `trait Ord: Eq`
        methods: []TraitMethod,
        is_public: bool,
    };

    /// Trait method (signature or default implementation)
    pub const TraitMethod = struct {
        name: []const u8,
        generic_params: ?[]GenericParam,
        parameters: []Parameter, // First is `self: Self`
        return_type: *Type,
        is_effect: bool,
        default_body: ?[]Statement,
        span: Span,
    };

    /// Impl block
    /// `impl Trait for Type { ... }` or `impl Type { ... }`
    pub const ImplBlock = struct {
        trait_name: ?[]const u8, // None for inherent impls
        generic_params: ?[]GenericParam,
        target_type: *Type,
        methods: []FunctionDecl,
        where_clause: ?[]WhereConstraint,
    };

    /// Module declaration
    /// `module path.to.module`
    pub const ModuleDecl = struct {
        path: [][]const u8,
    };

    /// Import declaration
    /// `import path.to.module.{ item1, item2 as alias }`
    pub const ImportDecl = struct {
        path: [][]const u8,
        items: ?[]ImportItem, // None means import entire module
    };

    /// Import item with optional alias
    pub const ImportItem = struct {
        name: []const u8,
        alias: ?[]const u8,
        span: Span,
    };

    /// Constant declaration
    /// `const NAME: Type = value`
    pub const ConstDecl = struct {
        name: []const u8,
        const_type: *Type,
        value: *Expression,
        is_public: bool,
    };

    /// Top-level let binding (functions as values)
    /// `let add: fn(i32, i32) -> i32 = fn(a: i32, b: i32) -> i32 { ... }`
    pub const LetDecl = struct {
        name: []const u8,
        generic_params: ?[]GenericParam,
        binding_type: *Type,
        value: *Expression,
        is_public: bool,
    };

    /// Test declaration
    /// `test "description" { body }`
    pub const TestDecl = struct {
        name: []const u8,
        body: []Statement,
    };

    /// Create a new declaration with the given kind and span
    pub fn init(kind: DeclarationKind, span: Span) Declaration {
        return .{ .kind = kind, .span = span, .doc_comment = null };
    }

    /// Create a new declaration with a doc comment
    pub fn initWithDoc(kind: DeclarationKind, span: Span, doc: []const u8) Declaration {
        return .{ .kind = kind, .span = span, .doc_comment = doc };
    }

    /// Check if this declaration is public
    pub fn isPublic(self: Declaration) bool {
        return switch (self.kind) {
            .function_decl => |f| f.is_public,
            .type_decl => |t| t.is_public,
            .trait_decl => |t| t.is_public,
            .const_decl => |c| c.is_public,
            .let_decl => |l| l.is_public,
            .impl_block, .module_decl, .import_decl, .test_decl => false,
        };
    }

    /// Get the name of this declaration if it has one
    pub fn name(self: Declaration) ?[]const u8 {
        return switch (self.kind) {
            .function_decl => |f| f.name,
            .type_decl => |t| t.name,
            .trait_decl => |t| t.name,
            .const_decl => |c| c.name,
            .let_decl => |l| l.name,
            .test_decl => |t| t.name,
            .impl_block, .module_decl, .import_decl => null,
        };
    }
};

test "declaration types" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    // Test module declaration
    var path = [_][]const u8{ "std", "list" };
    const mod_decl = Declaration.init(.{
        .module_decl = .{ .path = &path },
    }, span);

    try std.testing.expect(!mod_decl.isPublic());
    try std.testing.expect(mod_decl.name() == null);
}

test "declaration with doc comment" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    var path = [_][]const u8{"math"};
    const decl = Declaration.initWithDoc(
        .{ .module_decl = .{ .path = &path } },
        span,
        "This is a doc comment",
    );

    try std.testing.expect(decl.doc_comment != null);
    try std.testing.expectEqualStrings("This is a doc comment", decl.doc_comment.?);
}

test "test declaration properties" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    const test_decl = Declaration.init(.{
        .test_decl = .{
            .name = "my test",
            .body = &[_]Statement{},
        },
    }, span);

    // Tests are never public
    try std.testing.expect(!test_decl.isPublic());

    // Tests have a name
    try std.testing.expect(test_decl.name() != null);
    try std.testing.expectEqualStrings("my test", test_decl.name().?);
}
