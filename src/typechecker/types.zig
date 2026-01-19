//! Resolved Type representation for the Kira language.
//!
//! While ast.Type represents parsed type annotations, ResolvedType represents
//! types after resolution - with named types resolved to symbol IDs, generic
//! types instantiated with concrete arguments, and all types in canonical form
//! for comparison.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const symbols = @import("../symbols/root.zig");

pub const Span = ast.Span;
pub const Type = ast.Type;
pub const SymbolId = symbols.SymbolId;

/// A resolved type with all names resolved to symbol IDs and
/// generic types instantiated with concrete arguments.
pub const ResolvedType = struct {
    kind: ResolvedTypeKind,
    span: Span,

    pub const ResolvedTypeKind = union(enum) {
        /// Primitive types (i32, bool, string, etc.)
        primitive: Type.PrimitiveType,

        /// Named type resolved to a symbol
        named: NamedTypeInfo,

        /// Instantiated generic type (e.g., List[i32])
        instantiated: InstantiatedTypeInfo,

        /// Function type
        function: FunctionTypeInfo,

        /// Tuple type (A, B, C)
        tuple: TupleTypeInfo,

        /// Array type [T; N]
        array: ArrayTypeInfo,

        /// IO effect type
        io: *ResolvedType,

        /// Result type
        result: ResultTypeInfo,

        /// Option type
        option: *ResolvedType,

        /// Type variable (for generics, before instantiation)
        type_var: TypeVarInfo,

        /// Self type (in trait/impl contexts)
        self_type: void,

        /// Void type
        void_type: void,

        /// Error type (for error recovery, propagates through type checking)
        error_type: void,
    };

    /// Named type information
    pub const NamedTypeInfo = struct {
        symbol_id: SymbolId,
        name: []const u8,
    };

    /// Instantiated generic type information
    pub const InstantiatedTypeInfo = struct {
        base_symbol_id: SymbolId,
        base_name: []const u8,
        type_arguments: []ResolvedType,
    };

    /// Function type information
    pub const FunctionTypeInfo = struct {
        parameter_types: []ResolvedType,
        return_type: *ResolvedType,
        effect: ?Type.EffectAnnotation,
    };

    /// Tuple type information
    pub const TupleTypeInfo = struct {
        element_types: []ResolvedType,
    };

    /// Array type information
    pub const ArrayTypeInfo = struct {
        element_type: *ResolvedType,
        size: ?u64,
    };

    /// Result type information
    pub const ResultTypeInfo = struct {
        ok_type: *ResolvedType,
        err_type: *ResolvedType,
    };

    /// Type variable information
    pub const TypeVarInfo = struct {
        name: []const u8,
        constraints: ?[][]const u8,
    };

    /// Create a primitive type
    pub fn primitive(prim: Type.PrimitiveType, span: Span) ResolvedType {
        return .{ .kind = .{ .primitive = prim }, .span = span };
    }

    /// Create a void type
    pub fn voidType(span: Span) ResolvedType {
        return .{ .kind = .void_type, .span = span };
    }

    /// Create an error type (for error recovery)
    pub fn errorType(span: Span) ResolvedType {
        return .{ .kind = .error_type, .span = span };
    }

    /// Create a named type
    pub fn named(symbol_id: SymbolId, name: []const u8, span: Span) ResolvedType {
        return .{
            .kind = .{ .named = .{ .symbol_id = symbol_id, .name = name } },
            .span = span,
        };
    }

    /// Create a type variable
    pub fn typeVar(name: []const u8, constraints: ?[][]const u8, span: Span) ResolvedType {
        return .{
            .kind = .{ .type_var = .{ .name = name, .constraints = constraints } },
            .span = span,
        };
    }

    /// Check if this is a primitive type
    pub fn isPrimitive(self: ResolvedType) bool {
        return self.kind == .primitive;
    }

    /// Check if this is a numeric type (integer or float)
    pub fn isNumeric(self: ResolvedType) bool {
        return switch (self.kind) {
            .primitive => |p| p.isInteger() or p.isFloat(),
            else => false,
        };
    }

    /// Check if this is an integer type
    pub fn isInteger(self: ResolvedType) bool {
        return switch (self.kind) {
            .primitive => |p| p.isInteger(),
            else => false,
        };
    }

    /// Check if this is a float type
    pub fn isFloat(self: ResolvedType) bool {
        return switch (self.kind) {
            .primitive => |p| p.isFloat(),
            else => false,
        };
    }

    /// Check if this is a boolean type
    pub fn isBool(self: ResolvedType) bool {
        return switch (self.kind) {
            .primitive => |p| p == .bool,
            else => false,
        };
    }

    /// Check if this is a string type
    pub fn isString(self: ResolvedType) bool {
        return switch (self.kind) {
            .primitive => |p| p == .string,
            else => false,
        };
    }

    /// Check if this is a char type
    pub fn isChar(self: ResolvedType) bool {
        return switch (self.kind) {
            .primitive => |p| p == .char,
            else => false,
        };
    }

    /// Check if this is void
    pub fn isVoid(self: ResolvedType) bool {
        return switch (self.kind) {
            .void_type => true,
            .primitive => |p| p == .void_type,
            else => false,
        };
    }

    /// Check if this is an error type (for error recovery)
    pub fn isError(self: ResolvedType) bool {
        return self.kind == .error_type;
    }

    /// Check if this is a function type
    pub fn isFunction(self: ResolvedType) bool {
        return self.kind == .function;
    }

    /// Check if this is a tuple type
    pub fn isTuple(self: ResolvedType) bool {
        return self.kind == .tuple;
    }

    /// Check if this is an array type
    pub fn isArray(self: ResolvedType) bool {
        return self.kind == .array;
    }

    /// Check if this is an Option type
    pub fn isOption(self: ResolvedType) bool {
        return self.kind == .option;
    }

    /// Check if this is a Result type
    pub fn isResult(self: ResolvedType) bool {
        return self.kind == .result;
    }

    /// Check if this is an IO type
    pub fn isIO(self: ResolvedType) bool {
        return self.kind == .io;
    }

    /// Get the inner type for Option, Result (ok), or IO types
    pub fn getInnerType(self: ResolvedType) ?*ResolvedType {
        return switch (self.kind) {
            .option => |inner| inner,
            .io => |inner| inner,
            .result => |r| r.ok_type,
            else => null,
        };
    }

    /// Format the type for display
    pub fn format(
        self: ResolvedType,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try self.writeTypeName(writer);
    }

    /// Write the type name to a writer
    pub fn writeTypeName(self: ResolvedType, writer: anytype) !void {
        switch (self.kind) {
            .primitive => |p| try writer.writeAll(p.toString()),
            .named => |n| try writer.writeAll(n.name),
            .instantiated => |inst| {
                try writer.writeAll(inst.base_name);
                try writer.writeAll("[");
                for (inst.type_arguments, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try arg.writeTypeName(writer);
                }
                try writer.writeAll("]");
            },
            .function => |f| {
                if (f.effect) |eff| {
                    try writer.writeAll(eff.toString());
                    try writer.writeAll(" ");
                }
                try writer.writeAll("fn(");
                for (f.parameter_types, 0..) |param, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try param.writeTypeName(writer);
                }
                try writer.writeAll(") -> ");
                try f.return_type.writeTypeName(writer);
            },
            .tuple => |t| {
                try writer.writeAll("(");
                for (t.element_types, 0..) |elem, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try elem.writeTypeName(writer);
                }
                try writer.writeAll(")");
            },
            .array => |a| {
                try writer.writeAll("[");
                try a.element_type.writeTypeName(writer);
                if (a.size) |s| {
                    try writer.print("; {d}]", .{s});
                } else {
                    try writer.writeAll("]");
                }
            },
            .io => |inner| {
                try writer.writeAll("IO[");
                try inner.writeTypeName(writer);
                try writer.writeAll("]");
            },
            .result => |r| {
                try writer.writeAll("Result[");
                try r.ok_type.writeTypeName(writer);
                try writer.writeAll(", ");
                try r.err_type.writeTypeName(writer);
                try writer.writeAll("]");
            },
            .option => |inner| {
                try writer.writeAll("Option[");
                try inner.writeTypeName(writer);
                try writer.writeAll("]");
            },
            .type_var => |tv| try writer.writeAll(tv.name),
            .self_type => try writer.writeAll("Self"),
            .void_type => try writer.writeAll("void"),
            .error_type => try writer.writeAll("<error>"),
        }
    }

    /// Convert to a string (allocates)
    pub fn toString(self: ResolvedType, allocator: Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        try self.writeTypeName(list.writer(allocator));
        return list.toOwnedSlice(allocator);
    }
};

test "resolved type basic operations" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    const int_type = ResolvedType.primitive(.i32, span);
    try std.testing.expect(int_type.isPrimitive());
    try std.testing.expect(int_type.isInteger());
    try std.testing.expect(int_type.isNumeric());
    try std.testing.expect(!int_type.isFloat());
    try std.testing.expect(!int_type.isBool());

    const bool_type = ResolvedType.primitive(.bool, span);
    try std.testing.expect(bool_type.isBool());
    try std.testing.expect(!bool_type.isNumeric());

    const void_type = ResolvedType.voidType(span);
    try std.testing.expect(void_type.isVoid());

    const error_type = ResolvedType.errorType(span);
    try std.testing.expect(error_type.isError());
}

test "resolved type named" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    const named_type = ResolvedType.named(42, "MyType", span);
    try std.testing.expect(!named_type.isPrimitive());
    try std.testing.expect(named_type.kind == .named);
    try std.testing.expectEqual(@as(SymbolId, 42), named_type.kind.named.symbol_id);
    try std.testing.expectEqualStrings("MyType", named_type.kind.named.name);
}
