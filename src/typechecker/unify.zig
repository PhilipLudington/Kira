//! Type unification and equality checking for the Kira language.
//!
//! This module provides functions for comparing resolved types for equality,
//! checking type compatibility, and determining if types can be unified.

const std = @import("std");
const types = @import("types.zig");
const ast = @import("../ast/root.zig");

pub const ResolvedType = types.ResolvedType;
pub const Type = ast.Type;

/// Check if two resolved types are structurally equal.
/// Error types are considered equal to any type (for error recovery).
pub fn typesEqual(a: ResolvedType, b: ResolvedType) bool {
    // Error types unify with anything (for error recovery)
    if (a.isError() or b.isError()) return true;

    // Check kind match
    if (@intFromEnum(a.kind) != @intFromEnum(b.kind)) return false;

    return switch (a.kind) {
        .primitive => |pa| switch (b.kind) {
            .primitive => |pb| pa == pb,
            else => false,
        },
        .named => |na| switch (b.kind) {
            .named => |nb| na.symbol_id == nb.symbol_id,
            else => false,
        },
        .instantiated => |ia| switch (b.kind) {
            .instantiated => |ib| {
                if (ia.base_symbol_id != ib.base_symbol_id) return false;
                if (ia.type_arguments.len != ib.type_arguments.len) return false;
                for (ia.type_arguments, ib.type_arguments) |arg_a, arg_b| {
                    if (!typesEqual(arg_a, arg_b)) return false;
                }
                return true;
            },
            else => false,
        },
        .function => |fa| switch (b.kind) {
            .function => |fb| {
                if (fa.parameter_types.len != fb.parameter_types.len) return false;
                if (fa.effect != fb.effect) return false;
                for (fa.parameter_types, fb.parameter_types) |pa, pb| {
                    if (!typesEqual(pa, pb)) return false;
                }
                return typesEqual(fa.return_type.*, fb.return_type.*);
            },
            else => false,
        },
        .tuple => |ta| switch (b.kind) {
            .tuple => |tb| {
                if (ta.element_types.len != tb.element_types.len) return false;
                for (ta.element_types, tb.element_types) |ea, eb| {
                    if (!typesEqual(ea, eb)) return false;
                }
                return true;
            },
            else => false,
        },
        .array => |aa| switch (b.kind) {
            .array => |ab| {
                if (aa.size != ab.size) return false;
                return typesEqual(aa.element_type.*, ab.element_type.*);
            },
            else => false,
        },
        .io => |ia| switch (b.kind) {
            .io => |ib| typesEqual(ia.*, ib.*),
            else => false,
        },
        .result => |ra| switch (b.kind) {
            .result => |rb| {
                return typesEqual(ra.ok_type.*, rb.ok_type.*) and
                    typesEqual(ra.err_type.*, rb.err_type.*);
            },
            else => false,
        },
        .option => |oa| switch (b.kind) {
            .option => |ob| typesEqual(oa.*, ob.*),
            else => false,
        },
        .type_var => |tva| switch (b.kind) {
            .type_var => |tvb| std.mem.eql(u8, tva.name, tvb.name),
            else => false,
        },
        .self_type => b.kind == .self_type,
        .void_type => b.kind == .void_type,
        .error_type => true, // Already handled above
    };
}

/// Check if source type is assignable to target type.
/// Allows coercions that are safe: fixed-size arrays [T; N] → dynamic [T].
pub fn isAssignable(target: ResolvedType, source: ResolvedType) bool {
    // Error types are assignable to anything (for error recovery)
    if (target.isError() or source.isError()) return true;

    // Array coercion: [T; N] is assignable to [T]
    if (target.kind == .array and source.kind == .array) {
        const ta = target.kind.array;
        const sa = source.kind.array;
        if (ta.size == null and sa.size != null) {
            // Fixed-size → dynamic: allowed if element types match
            return typesEqual(ta.element_type.*, sa.element_type.*);
        }
    }

    // Integer compatibility: allow assignment between integer widths/signedness.
    // Kira runtime integers are represented uniformly; checker width differences
    // should not block common assignments in user code.
    if (target.kind == .primitive and source.kind == .primitive) {
        const tp = target.kind.primitive;
        const sp = source.kind.primitive;
        if (tp.isInteger() and sp.isInteger()) {
            return true;
        }
    }

    return typesEqual(target, source);
}

/// Check if a type is compatible with a numeric operation
pub fn isNumericCompatible(resolved_type: ResolvedType) bool {
    return resolved_type.isNumeric();
}

/// Check if a type is compatible with comparison operations
pub fn isComparable(resolved_type: ResolvedType) bool {
    return switch (resolved_type.kind) {
        .primitive => |p| switch (p) {
            .i8, .i16, .i32, .i64, .i128 => true,
            .u8, .u16, .u32, .u64, .u128 => true,
            .f32, .f64 => true,
            .char => true,
            .string => true,
            else => false,
        },
        else => false,
    };
}

/// Check if a type supports equality comparison
pub fn isEquatable(resolved_type: ResolvedType) bool {
    return switch (resolved_type.kind) {
        .primitive => true,
        .named => true, // Assume named types are equatable (should check trait impl)
        .tuple => |t| {
            for (t.element_types) |elem| {
                if (!isEquatable(elem)) return false;
            }
            return true;
        },
        .array => |a| isEquatable(a.element_type.*),
        .option => |o| isEquatable(o.*),
        .result => |r| isEquatable(r.ok_type.*) and isEquatable(r.err_type.*),
        .instantiated => true, // Assume instantiated types are equatable
        else => false,
    };
}

/// Check if a type is iterable (can be used in for loops)
pub fn isIterable(resolved_type: ResolvedType) bool {
    return switch (resolved_type.kind) {
        .array => true,
        .primitive => |p| p == .string, // Strings are iterable over chars
        .instantiated => true, // Generic collections are iterable
        .named => true, // Named types might implement Iterator
        else => false,
    };
}

/// Get the element type of an iterable
pub fn getIterableElement(resolved_type: ResolvedType) ?ResolvedType {
    return switch (resolved_type.kind) {
        .array => |a| a.element_type.*,
        .primitive => |p| if (p == .string)
            ResolvedType.primitive(.char, resolved_type.span)
        else
            null,
        .instantiated => |inst| {
            // Generic collections: first type argument is the element type
            // e.g., List[i32] → i32, List[string] → string
            if (inst.type_arguments.len > 0) {
                return inst.type_arguments[0];
            }
            return null;
        },
        else => null,
    };
}

/// Check if a cast from source to target is valid
pub fn isValidCast(source: ResolvedType, target: ResolvedType) bool {
    // Same types are always valid
    if (typesEqual(source, target)) return true;

    // Error types allow any cast (for error recovery)
    if (source.isError() or target.isError()) return true;

    // Numeric casts
    if (source.isNumeric() and target.isNumeric()) return true;

    // Char to/from integers
    if (source.isChar() and target.isInteger()) return true;
    if (source.isInteger() and target.isChar()) return true;

    // No other casts allowed in Kira
    return false;
}

/// Check if two primitive types are compatible for arithmetic
pub fn areArithmeticCompatible(a: Type.PrimitiveType, b: Type.PrimitiveType) bool {
    // Both must be numeric
    if (!a.isInteger() and !a.isFloat()) return false;
    if (!b.isInteger() and !b.isFloat()) return false;

    // Must be exactly the same type (no implicit conversions)
    return a == b;
}

test "types equal - primitives" {
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    const i32_a = ResolvedType.primitive(.i32, span);
    const i32_b = ResolvedType.primitive(.i32, span);
    const i64_type = ResolvedType.primitive(.i64, span);

    try std.testing.expect(typesEqual(i32_a, i32_b));
    try std.testing.expect(!typesEqual(i32_a, i64_type));
}

test "types equal - error type unifies with anything" {
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    const error_type = ResolvedType.errorType(span);
    const i32_type = ResolvedType.primitive(.i32, span);
    const bool_type = ResolvedType.primitive(.bool, span);

    try std.testing.expect(typesEqual(error_type, i32_type));
    try std.testing.expect(typesEqual(i32_type, error_type));
    try std.testing.expect(typesEqual(error_type, bool_type));
}

test "types equal - void" {
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    const void_a = ResolvedType.voidType(span);
    const void_b = ResolvedType.voidType(span);
    const i32_type = ResolvedType.primitive(.i32, span);

    try std.testing.expect(typesEqual(void_a, void_b));
    try std.testing.expect(!typesEqual(void_a, i32_type));
}

test "is valid cast" {
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    const i32_type = ResolvedType.primitive(.i32, span);
    const i64_type = ResolvedType.primitive(.i64, span);
    const f64_type = ResolvedType.primitive(.f64, span);
    const bool_type = ResolvedType.primitive(.bool, span);

    // Numeric casts are valid
    try std.testing.expect(isValidCast(i32_type, i64_type));
    try std.testing.expect(isValidCast(i32_type, f64_type));

    // Non-numeric to non-numeric is invalid
    try std.testing.expect(!isValidCast(bool_type, i32_type));
}

test "integer assignability ignores width differences" {
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    const i32_type = ResolvedType.primitive(.i32, span);
    const i64_type = ResolvedType.primitive(.i64, span);

    try std.testing.expect(isAssignable(i32_type, i64_type));
    try std.testing.expect(isAssignable(i64_type, i32_type));
}
