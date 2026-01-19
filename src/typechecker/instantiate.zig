//! Generic type instantiation for the Kira language.
//!
//! This module handles substituting type variables with concrete type arguments
//! when instantiating generic types and functions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const symbols = @import("../symbols/root.zig");

pub const ResolvedType = types.ResolvedType;
pub const SymbolId = symbols.SymbolId;

/// Substitution map from type variable names to concrete types
pub const TypeSubstitution = std.StringHashMapUnmanaged(ResolvedType);

/// Instantiate a type by substituting type variables with concrete types
pub fn instantiate(
    allocator: Allocator,
    resolved_type: ResolvedType,
    substitution: *const TypeSubstitution,
) !ResolvedType {
    return switch (resolved_type.kind) {
        // Type variable - look up in substitution
        .type_var => |tv| {
            if (substitution.get(tv.name)) |concrete| {
                return concrete;
            }
            // Not found in substitution, keep as is
            return resolved_type;
        },

        // Primitives don't need substitution
        .primitive, .void_type, .error_type, .self_type => resolved_type,

        // Named types don't have type variables
        .named => resolved_type,

        // Instantiated types - substitute in type arguments
        .instantiated => |inst| {
            var new_args = std.ArrayListUnmanaged(ResolvedType){};
            for (inst.type_arguments) |arg| {
                try new_args.append(allocator, try instantiate(allocator, arg, substitution));
            }
            return .{
                .kind = .{ .instantiated = .{
                    .base_symbol_id = inst.base_symbol_id,
                    .base_name = inst.base_name,
                    .type_arguments = try new_args.toOwnedSlice(allocator),
                } },
                .span = resolved_type.span,
            };
        },

        // Function types - substitute in parameter and return types
        .function => |f| {
            var new_params = std.ArrayListUnmanaged(ResolvedType){};
            for (f.parameter_types) |param| {
                try new_params.append(allocator, try instantiate(allocator, param, substitution));
            }

            const new_return = try allocator.create(ResolvedType);
            new_return.* = try instantiate(allocator, f.return_type.*, substitution);

            return .{
                .kind = .{ .function = .{
                    .parameter_types = try new_params.toOwnedSlice(allocator),
                    .return_type = new_return,
                    .effect = f.effect,
                } },
                .span = resolved_type.span,
            };
        },

        // Tuple types - substitute in element types
        .tuple => |t| {
            var new_elements = std.ArrayListUnmanaged(ResolvedType){};
            for (t.element_types) |elem| {
                try new_elements.append(allocator, try instantiate(allocator, elem, substitution));
            }
            return .{
                .kind = .{ .tuple = .{
                    .element_types = try new_elements.toOwnedSlice(allocator),
                } },
                .span = resolved_type.span,
            };
        },

        // Array types - substitute in element type
        .array => |a| {
            const new_elem = try allocator.create(ResolvedType);
            new_elem.* = try instantiate(allocator, a.element_type.*, substitution);
            return .{
                .kind = .{ .array = .{
                    .element_type = new_elem,
                    .size = a.size,
                } },
                .span = resolved_type.span,
            };
        },

        // IO types - substitute in inner type
        .io => |inner| {
            const new_inner = try allocator.create(ResolvedType);
            new_inner.* = try instantiate(allocator, inner.*, substitution);
            return .{
                .kind = .{ .io = new_inner },
                .span = resolved_type.span,
            };
        },

        // Result types - substitute in both types
        .result => |r| {
            const new_ok = try allocator.create(ResolvedType);
            new_ok.* = try instantiate(allocator, r.ok_type.*, substitution);

            const new_err = try allocator.create(ResolvedType);
            new_err.* = try instantiate(allocator, r.err_type.*, substitution);

            return .{
                .kind = .{ .result = .{
                    .ok_type = new_ok,
                    .err_type = new_err,
                } },
                .span = resolved_type.span,
            };
        },

        // Option types - substitute in inner type
        .option => |inner| {
            const new_inner = try allocator.create(ResolvedType);
            new_inner.* = try instantiate(allocator, inner.*, substitution);
            return .{
                .kind = .{ .option = new_inner },
                .span = resolved_type.span,
            };
        },
    };
}

/// Create a type substitution from type parameter names and concrete arguments
pub fn createSubstitution(
    allocator: Allocator,
    param_names: []const []const u8,
    type_arguments: []const ResolvedType,
) !TypeSubstitution {
    var subst = TypeSubstitution{};

    const min_len = @min(param_names.len, type_arguments.len);
    for (param_names[0..min_len], type_arguments[0..min_len]) |name, arg| {
        try subst.put(allocator, name, arg);
    }

    return subst;
}

/// Check if type arguments satisfy constraints on type parameters
pub fn checkConstraints(
    type_arguments: []const ResolvedType,
    param_constraints: []const ?[][]const u8,
    trait_impl_checker: anytype, // Function that checks if a type implements a trait
) bool {
    if (type_arguments.len != param_constraints.len) return false;

    for (type_arguments, param_constraints) |arg, constraints_opt| {
        if (constraints_opt) |constraints| {
            for (constraints) |constraint| {
                if (!trait_impl_checker(arg, constraint)) {
                    return false;
                }
            }
        }
    }

    return true;
}

/// Extract type variable names from a type
pub fn collectTypeVariables(
    allocator: Allocator,
    resolved_type: ResolvedType,
) ![]const []const u8 {
    var vars = std.ArrayListUnmanaged([]const u8){};

    try collectTypeVariablesRecursive(allocator, resolved_type, &vars);

    return vars.toOwnedSlice(allocator);
}

fn collectTypeVariablesRecursive(
    allocator: Allocator,
    resolved_type: ResolvedType,
    vars: *std.ArrayListUnmanaged([]const u8),
) !void {
    switch (resolved_type.kind) {
        .type_var => |tv| {
            // Add if not already present
            for (vars.items) |v| {
                if (std.mem.eql(u8, v, tv.name)) return;
            }
            try vars.append(allocator, tv.name);
        },
        .instantiated => |inst| {
            for (inst.type_arguments) |arg| {
                try collectTypeVariablesRecursive(allocator, arg, vars);
            }
        },
        .function => |f| {
            for (f.parameter_types) |param| {
                try collectTypeVariablesRecursive(allocator, param, vars);
            }
            try collectTypeVariablesRecursive(allocator, f.return_type.*, vars);
        },
        .tuple => |t| {
            for (t.element_types) |elem| {
                try collectTypeVariablesRecursive(allocator, elem, vars);
            }
        },
        .array => |a| {
            try collectTypeVariablesRecursive(allocator, a.element_type.*, vars);
        },
        .io => |inner| {
            try collectTypeVariablesRecursive(allocator, inner.*, vars);
        },
        .result => |r| {
            try collectTypeVariablesRecursive(allocator, r.ok_type.*, vars);
            try collectTypeVariablesRecursive(allocator, r.err_type.*, vars);
        },
        .option => |inner| {
            try collectTypeVariablesRecursive(allocator, inner.*, vars);
        },
        .primitive, .named, .void_type, .error_type, .self_type => {},
    }
}

test "instantiate type variable" {
    const allocator = std.testing.allocator;
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    // Create a type variable T
    const type_var = ResolvedType.typeVar("T", null, span);

    // Create substitution T -> i32
    var subst = TypeSubstitution{};
    defer subst.deinit(allocator);
    try subst.put(allocator, "T", ResolvedType.primitive(.i32, span));

    // Instantiate
    const result = try instantiate(allocator, type_var, &subst);

    try std.testing.expect(result.isPrimitive());
    try std.testing.expectEqual(@as(types.Type.PrimitiveType, .i32), result.kind.primitive);
}

test "instantiate preserves non-variables" {
    const allocator = std.testing.allocator;
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    const i32_type = ResolvedType.primitive(.i32, span);

    var subst = TypeSubstitution{};
    defer subst.deinit(allocator);
    try subst.put(allocator, "T", ResolvedType.primitive(.bool, span));

    const result = try instantiate(allocator, i32_type, &subst);

    try std.testing.expect(result.isPrimitive());
    try std.testing.expectEqual(@as(types.Type.PrimitiveType, .i32), result.kind.primitive);
}

test "create substitution" {
    const allocator = std.testing.allocator;
    const span = @import("../ast/root.zig").Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 1, .offset = 0 },
    };

    const param_names = [_][]const u8{ "T", "U" };
    const type_args = [_]ResolvedType{
        ResolvedType.primitive(.i32, span),
        ResolvedType.primitive(.bool, span),
    };

    var subst = try createSubstitution(allocator, &param_names, &type_args);
    defer subst.deinit(allocator);

    try std.testing.expect(subst.get("T") != null);
    try std.testing.expect(subst.get("U") != null);
    try std.testing.expect(subst.get("V") == null);
}
