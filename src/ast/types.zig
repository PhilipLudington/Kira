//! Type AST nodes for the Kira language.
//!
//! Types in Kira are always explicit. This module defines the AST
//! representation of type annotations.

const std = @import("std");
const lexer = @import("../lexer/root.zig");

pub const Span = lexer.Span;

/// Represents a type in the Kira language.
pub const Type = struct {
    kind: TypeKind,
    span: Span,

    pub const TypeKind = union(enum) {
        // Primitive types
        primitive: PrimitiveType,

        // Named type (user-defined or imported)
        named: NamedType,

        // Generic type instantiation: `List[T]`, `Result[T, E]`
        generic: GenericType,

        // Function type: `fn(A, B) -> C`
        function: FunctionType,

        // Tuple type: `(A, B, C)`
        tuple: TupleType,

        // Array type: `[T; N]`
        array: ArrayType,

        // Effect types
        io_type: *Type, // `IO[T]`
        result_type: ResultType, // `Result[T, E]`
        option_type: *Type, // `Option[T]`

        // Self type (in traits/impls)
        self_type: void,

        // Type variable (generic parameter)
        type_variable: TypeVariable,

        // Path type (qualified name): `std.list.List`
        path: PathType,

        // Inferred (placeholder, should be resolved by type checker)
        // Note: Kira doesn't allow inference, but we need this for error recovery
        inferred: void,
    };

    /// Primitive types
    pub const PrimitiveType = enum {
        // Signed integers
        i8,
        i16,
        i32,
        i64,
        i128,

        // Unsigned integers
        u8,
        u16,
        u32,
        u64,
        u128,

        // Floating point
        f32,
        f64,

        // Other primitives
        bool,
        char,
        string,
        void_type,

        pub fn toString(self: PrimitiveType) []const u8 {
            return switch (self) {
                .i8 => "i8",
                .i16 => "i16",
                .i32 => "i32",
                .i64 => "i64",
                .i128 => "i128",
                .u8 => "u8",
                .u16 => "u16",
                .u32 => "u32",
                .u64 => "u64",
                .u128 => "u128",
                .f32 => "f32",
                .f64 => "f64",
                .bool => "bool",
                .char => "char",
                .string => "string",
                .void_type => "void",
            };
        }

        pub fn fromString(s: []const u8) ?PrimitiveType {
            const map = std.StaticStringMap(PrimitiveType).initComptime(.{
                .{ "i8", .i8 },
                .{ "i16", .i16 },
                .{ "i32", .i32 },
                .{ "i64", .i64 },
                .{ "i128", .i128 },
                .{ "u8", .u8 },
                .{ "u16", .u16 },
                .{ "u32", .u32 },
                .{ "u64", .u64 },
                .{ "u128", .u128 },
                .{ "f32", .f32 },
                .{ "f64", .f64 },
                .{ "bool", .bool },
                .{ "char", .char },
                .{ "string", .string },
                .{ "void", .void_type },
            });
            return map.get(s);
        }

        pub fn isInteger(self: PrimitiveType) bool {
            return switch (self) {
                .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128 => true,
                else => false,
            };
        }

        pub fn isFloat(self: PrimitiveType) bool {
            return switch (self) {
                .f32, .f64 => true,
                else => false,
            };
        }

        pub fn isSigned(self: PrimitiveType) bool {
            return switch (self) {
                .i8, .i16, .i32, .i64, .i128 => true,
                else => false,
            };
        }

        pub fn bitSize(self: PrimitiveType) ?u16 {
            return switch (self) {
                .i8, .u8 => 8,
                .i16, .u16 => 16,
                .i32, .u32, .f32 => 32,
                .i64, .u64, .f64 => 64,
                .i128, .u128 => 128,
                .bool => 1,
                .char => 32, // Unicode scalar value
                else => null,
            };
        }
    };

    /// Named type (simple identifier)
    pub const NamedType = struct {
        name: []const u8,
    };

    /// Generic type: `TypeName[Arg1, Arg2]`
    pub const GenericType = struct {
        base: []const u8,
        type_arguments: []*Type,
    };

    /// Function type: `fn(A, B) -> C` or `effect fn(A, B) -> IO[C]`
    pub const FunctionType = struct {
        parameter_types: []*Type,
        return_type: *Type,
        effect_type: ?EffectAnnotation,
    };

    /// Effect annotation on function types
    pub const EffectAnnotation = enum {
        pure, // No effect (default for regular functions)
        io, // IO effect
        result, // Can fail
        io_result, // IO + can fail

        pub fn toString(self: EffectAnnotation) []const u8 {
            return switch (self) {
                .pure => "pure",
                .io => "IO",
                .result => "Result",
                .io_result => "IO[Result]",
            };
        }
    };

    /// Tuple type: `(T1, T2, T3)`
    pub const TupleType = struct {
        element_types: []*Type,
    };

    /// Array type: `[T; N]`
    pub const ArrayType = struct {
        element_type: *Type,
        size: ?u64, // Optional for dynamic arrays
    };

    /// Result type: `Result[T, E]`
    pub const ResultType = struct {
        ok_type: *Type,
        err_type: *Type,
    };

    /// Type variable (in generic definitions)
    pub const TypeVariable = struct {
        name: []const u8,
        constraints: ?[]TypeConstraint, // Optional trait bounds
    };

    /// Type constraint (trait bound)
    pub const TypeConstraint = struct {
        trait_name: []const u8,
        span: Span,
    };

    /// Path type: `path.to.Type`
    pub const PathType = struct {
        segments: [][]const u8,
        generic_args: ?[]*Type,
    };

    /// Create a new type with the given kind and span
    pub fn init(kind: TypeKind, span: Span) Type {
        return .{ .kind = kind, .span = span };
    }

    /// Create a primitive type
    pub fn primitive(prim: PrimitiveType, span: Span) Type {
        return init(.{ .primitive = prim }, span);
    }

    /// Create a named type
    pub fn named(name: []const u8, span: Span) Type {
        return init(.{ .named = .{ .name = name } }, span);
    }

    /// Check if this is a primitive type
    pub fn isPrimitive(self: Type) bool {
        return self.kind == .primitive;
    }

    /// Check if this is a function type
    pub fn isFunction(self: Type) bool {
        return self.kind == .function;
    }

    /// Check if this is an effect type (IO, Result)
    pub fn isEffectType(self: Type) bool {
        return switch (self.kind) {
            .io_type, .result_type => true,
            else => false,
        };
    }

    /// Check if this type represents void
    pub fn isVoid(self: Type) bool {
        return switch (self.kind) {
            .primitive => |p| p == .void_type,
            else => false,
        };
    }
};

test "primitive type properties" {
    try std.testing.expect(Type.PrimitiveType.i32.isInteger());
    try std.testing.expect(Type.PrimitiveType.i32.isSigned());
    try std.testing.expect(!Type.PrimitiveType.u32.isSigned());
    try std.testing.expect(Type.PrimitiveType.f64.isFloat());
    try std.testing.expect(!Type.PrimitiveType.bool.isInteger());
}

test "primitive type from string" {
    try std.testing.expectEqual(Type.PrimitiveType.i32, Type.PrimitiveType.fromString("i32").?);
    try std.testing.expectEqual(Type.PrimitiveType.string, Type.PrimitiveType.fromString("string").?);
    try std.testing.expect(Type.PrimitiveType.fromString("invalid") == null);
}

test "type creation" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 4, .offset = 3 },
    };

    const i32_type = Type.primitive(.i32, span);
    try std.testing.expect(i32_type.isPrimitive());
    try std.testing.expect(!i32_type.isVoid());

    const void_type = Type.primitive(.void_type, span);
    try std.testing.expect(void_type.isVoid());
}
