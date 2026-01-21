//! Pattern Match Compiler for the Kira language.
//!
//! This module provides pattern analysis for exhaustiveness checking and
//! unreachable pattern detection. It operates on typed patterns after
//! the type checker has validated individual pattern types.
//!
//! The algorithm is based on the "usefulness" check from:
//! "Warnings for Pattern Matching" by Luc Maranget (2007)

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../ast/root.zig");
const symbols = @import("../symbols/root.zig");
const types_mod = @import("types.zig");
const errors_mod = @import("errors.zig");

pub const Pattern = ast.Pattern;
pub const Expression = ast.Expression;
pub const Span = ast.Span;
pub const Symbol = symbols.Symbol;
pub const SymbolId = symbols.SymbolId;
pub const SymbolTable = symbols.SymbolTable;
pub const ResolvedType = types_mod.ResolvedType;
pub const Diagnostic = errors_mod.Diagnostic;

/// Represents a pattern space for exhaustiveness analysis.
/// Each space represents a set of values that could potentially match.
pub const PatternSpace = union(enum) {
    /// Everything - matches all values of a type
    any: void,

    /// Nothing - empty pattern space
    empty: void,

    /// A specific boolean value
    bool_value: bool,

    /// A specific integer value
    int_value: i128,

    /// A specific character value
    char_value: u21,

    /// A specific string value
    string_value: []const u8,

    /// A specific float value
    float_value: f64,

    /// Constructor with nested spaces for fields
    constructor: ConstructorSpace,

    /// Tuple with element spaces
    tuple: []PatternSpace,

    /// Record with field spaces
    record: RecordSpace,

    /// Union of multiple spaces (from or-patterns)
    union_space: []PatternSpace,

    /// Range of values (integers or characters)
    range: RangeSpace,

    /// Constructor space for ADT variants
    pub const ConstructorSpace = struct {
        variant_name: []const u8,
        type_symbol_id: ?SymbolId,
        arguments: []PatternSpace,
    };

    /// Record space with named fields
    pub const RecordSpace = struct {
        type_symbol_id: ?SymbolId,
        fields: []FieldSpace,
    };

    /// Field space within a record
    pub const FieldSpace = struct {
        name: []const u8,
        space: PatternSpace,
    };

    /// Range of values
    pub const RangeSpace = struct {
        start: ?i128,
        end: ?i128,
        inclusive: bool,
    };

    /// Free all nested allocations in a PatternSpace
    pub fn deinit(self: *PatternSpace, allocator: Allocator) void {
        switch (self.*) {
            .constructor => |*c| {
                for (c.arguments) |*arg| {
                    var arg_copy = arg.*;
                    arg_copy.deinit(allocator);
                }
                if (c.arguments.len > 0) {
                    allocator.free(c.arguments);
                }
            },
            .tuple => |t| {
                for (t) |*elem| {
                    var elem_copy = elem.*;
                    elem_copy.deinit(allocator);
                }
                if (t.len > 0) {
                    allocator.free(t);
                }
            },
            .record => |*r| {
                for (r.fields) |*field| {
                    var space_copy = field.space;
                    space_copy.deinit(allocator);
                }
                if (r.fields.len > 0) {
                    allocator.free(r.fields);
                }
            },
            .union_space => |u| {
                for (u) |*alt| {
                    var alt_copy = alt.*;
                    alt_copy.deinit(allocator);
                }
                if (u.len > 0) {
                    allocator.free(u);
                }
            },
            // These don't have heap allocations
            .any, .empty, .bool_value, .int_value, .char_value, .string_value, .float_value, .range => {},
        }
    }
};

/// Result of exhaustiveness checking
pub const ExhaustivenessResult = struct {
    is_exhaustive: bool,
    missing_patterns: []MissingPattern,
    unreachable_arms: []usize,

    /// Clean up allocated slices
    pub fn deinit(self: *ExhaustivenessResult, allocator: Allocator) void {
        if (self.missing_patterns.len > 0) {
            allocator.free(self.missing_patterns);
        }
        if (self.unreachable_arms.len > 0) {
            allocator.free(self.unreachable_arms);
        }
    }
};

/// Describes a missing pattern for error reporting
pub const MissingPattern = struct {
    description: []const u8,
    variant_name: ?[]const u8,
};

/// Pattern match compiler and analyzer
pub const PatternCompiler = struct {
    allocator: Allocator,
    symbol_table: *SymbolTable,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),

    /// Initialize the pattern compiler
    pub fn init(
        allocator: Allocator,
        symbol_table: *SymbolTable,
        diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    ) PatternCompiler {
        return .{
            .allocator = allocator,
            .symbol_table = symbol_table,
            .diagnostics = diagnostics,
        };
    }

    /// Check if a match expression/statement is exhaustive
    pub fn checkExhaustiveness(
        self: *PatternCompiler,
        patterns: []const *const Pattern,
        subject_type: ResolvedType,
        _: Span, // Used for potential future error context
    ) !ExhaustivenessResult {
        var missing = std.ArrayListUnmanaged(MissingPattern){};
        var unreachable_arms = std.ArrayListUnmanaged(usize){};

        // Convert patterns to pattern spaces
        var spaces = std.ArrayListUnmanaged(PatternSpace){};
        defer {
            // Free nested allocations in each PatternSpace before freeing the list
            for (spaces.items) |*space| {
                space.deinit(self.allocator);
            }
            spaces.deinit(self.allocator);
        }
        for (patterns) |pattern| {
            try spaces.append(self.allocator, try self.patternToSpace(pattern));
        }

        // Check for unreachable patterns (each pattern should add new coverage)
        // Note: 'covered' contains copies/references to items from 'spaces', so we don't
        // deinit its items separately (they're cleaned up when spaces is cleaned up)
        var covered = std.ArrayListUnmanaged(PatternSpace){};
        defer covered.deinit(self.allocator);
        for (spaces.items, 0..) |space, i| {
            if (i > 0) {
                // Check if this pattern is subsumed by previous patterns
                if (self.isSubsumed(space, covered.items)) {
                    try unreachable_arms.append(self.allocator, i);
                }
            }
            try covered.append(self.allocator, space);
        }

        // Determine missing patterns based on type
        const is_exhaustive = try self.checkTypeExhaustiveness(
            subject_type,
            spaces.items,
            &missing,
        );

        return .{
            .is_exhaustive = is_exhaustive,
            .missing_patterns = try missing.toOwnedSlice(self.allocator),
            .unreachable_arms = try unreachable_arms.toOwnedSlice(self.allocator),
        };
    }

    /// Convert a Pattern AST node to a PatternSpace for analysis
    fn patternToSpace(self: *PatternCompiler, pattern: *const Pattern) !PatternSpace {
        return switch (pattern.kind) {
            .wildcard => .any,
            .identifier => .any, // Identifiers match anything

            .integer_literal => |v| .{ .int_value = v },
            .float_literal => |v| .{ .float_value = v },
            .string_literal => |v| .{ .string_value = v },
            .char_literal => |v| .{ .char_value = v },
            .bool_literal => |v| .{ .bool_value = v },

            .constructor => |ctor| blk: {
                var args = std.ArrayListUnmanaged(PatternSpace){};
                if (ctor.arguments) |arguments| {
                    for (arguments) |arg| {
                        const pat = switch (arg) {
                            .positional => |p| p,
                            .named => |n| n.pattern,
                        };
                        try args.append(self.allocator, try self.patternToSpace(pat));
                    }
                }
                break :blk .{ .constructor = .{
                    .variant_name = ctor.variant_name,
                    .type_symbol_id = null, // Will be resolved during checking
                    .arguments = try args.toOwnedSlice(self.allocator),
                } };
            },

            .record => |rec| blk: {
                var fields = std.ArrayListUnmanaged(PatternSpace.FieldSpace){};
                for (rec.fields) |field| {
                    const field_space = if (field.pattern) |p|
                        try self.patternToSpace(p)
                    else
                        PatternSpace.any; // Shorthand { x } means { x: x }

                    try fields.append(self.allocator, .{
                        .name = field.name,
                        .space = field_space,
                    });
                }
                break :blk .{ .record = .{
                    .type_symbol_id = null,
                    .fields = try fields.toOwnedSlice(self.allocator),
                } };
            },

            .tuple => |tup| blk: {
                var elements = std.ArrayListUnmanaged(PatternSpace){};
                for (tup.elements) |elem| {
                    try elements.append(self.allocator, try self.patternToSpace(elem));
                }
                break :blk .{ .tuple = try elements.toOwnedSlice(self.allocator) };
            },

            .or_pattern => |orp| blk: {
                var alternatives = std.ArrayListUnmanaged(PatternSpace){};
                for (orp.patterns) |alt| {
                    try alternatives.append(self.allocator, try self.patternToSpace(alt));
                }
                break :blk .{ .union_space = try alternatives.toOwnedSlice(self.allocator) };
            },

            .guarded => |g| {
                // Guarded patterns are conservatively treated as partial matches
                // (the guard may fail), so we treat them as matching but not
                // contributing to exhaustiveness without the wildcard fallback
                return try self.patternToSpace(g.pattern);
            },

            .range => |r| .{ .range = .{
                .start = if (r.start) |s| switch (s) {
                    .integer => |i| i,
                    .char => |c| @as(i128, @intCast(c)),
                } else null,
                .end = if (r.end) |e| switch (e) {
                    .integer => |i| i,
                    .char => |c| @as(i128, @intCast(c)),
                } else null,
                .inclusive = r.inclusive,
            } },

            .rest => .any, // Rest pattern matches remaining

            .typed => |t| try self.patternToSpace(t.pattern),
        };
    }

    /// Check if a pattern space is subsumed by a set of previous spaces
    fn isSubsumed(self: *PatternCompiler, space: PatternSpace, previous: []PatternSpace) bool {
        _ = self;
        for (previous) |prev| {
            if (spacesOverlap(space, prev)) {
                // Check if prev fully covers space
                if (spaceCovers(prev, space)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Check if type exhaustiveness is satisfied by the patterns
    fn checkTypeExhaustiveness(
        self: *PatternCompiler,
        subject_type: ResolvedType,
        spaces: []PatternSpace,
        missing: *std.ArrayListUnmanaged(MissingPattern),
    ) !bool {
        // Check for catch-all pattern (wildcard/identifier)
        for (spaces) |space| {
            if (space == .any) {
                return true; // Wildcard covers everything
            }
            // Check union spaces for any
            if (space == .union_space) {
                for (space.union_space) |alt| {
                    if (alt == .any) {
                        return true;
                    }
                }
            }
        }

        return switch (subject_type.kind) {
            .primitive => |p| switch (p) {
                .bool => self.checkBoolExhaustiveness(spaces, missing),
                else => {
                    // Other primitives (numbers, strings) are infinite
                    // and need a catch-all pattern
                    try missing.append(self.allocator, .{
                        .description = "_ (catch-all pattern needed)",
                        .variant_name = null,
                    });
                    return false;
                },
            },

            .named => |n| self.checkNamedTypeExhaustiveness(n.symbol_id, spaces, missing),

            .instantiated => |inst| self.checkNamedTypeExhaustiveness(inst.base_symbol_id, spaces, missing),

            .tuple => |t| self.checkTupleExhaustiveness(t.element_types, spaces, missing),

            .option => {
                // Option[T] is like a sum type with Some(T) and None
                return self.checkOptionExhaustiveness(spaces, missing);
            },

            .result => {
                // Result[T, E] is like a sum type with Ok(T) and Err(E)
                return self.checkResultExhaustiveness(spaces, missing);
            },

            else => {
                // For other types, need a catch-all
                try missing.append(self.allocator, .{
                    .description = "_ (catch-all pattern needed)",
                    .variant_name = null,
                });
                return false;
            },
        };
    }

    /// Check exhaustiveness for boolean type
    fn checkBoolExhaustiveness(
        self: *PatternCompiler,
        spaces: []PatternSpace,
        missing: *std.ArrayListUnmanaged(MissingPattern),
    ) !bool {
        var has_true = false;
        var has_false = false;

        for (spaces) |space| {
            switch (space) {
                .any => return true,
                .bool_value => |v| {
                    if (v) has_true = true else has_false = true;
                },
                .union_space => |alts| {
                    for (alts) |alt| {
                        switch (alt) {
                            .any => return true,
                            .bool_value => |v| {
                                if (v) has_true = true else has_false = true;
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        if (!has_true) {
            try missing.append(self.allocator, .{
                .description = "true",
                .variant_name = null,
            });
        }
        if (!has_false) {
            try missing.append(self.allocator, .{
                .description = "false",
                .variant_name = null,
            });
        }

        return has_true and has_false;
    }

    /// Check exhaustiveness for named types (sum types, product types)
    fn checkNamedTypeExhaustiveness(
        self: *PatternCompiler,
        symbol_id: SymbolId,
        spaces: []PatternSpace,
        missing: *std.ArrayListUnmanaged(MissingPattern),
    ) !bool {
        const sym = self.symbol_table.getSymbol(symbol_id) orelse {
            // Unknown type - conservatively require catch-all
            try missing.append(self.allocator, .{
                .description = "_ (catch-all pattern needed)",
                .variant_name = null,
            });
            return false;
        };

        if (sym.kind != .type_def) {
            try missing.append(self.allocator, .{
                .description = "_ (catch-all pattern needed)",
                .variant_name = null,
            });
            return false;
        }

        const type_def = sym.kind.type_def;

        return switch (type_def.definition) {
            .sum_type => |sum| self.checkSumTypeExhaustiveness(sum.variants, spaces, missing),
            .product_type => {
                // Product types always have exactly one "variant" - the struct itself
                // So we need a pattern that matches it
                for (spaces) |space| {
                    switch (space) {
                        .any, .record => return true,
                        .union_space => |alts| {
                            for (alts) |alt| {
                                if (alt == .any or alt == .record) return true;
                            }
                        },
                        else => {},
                    }
                }
                try missing.append(self.allocator, .{
                    .description = "_ (record pattern needed)",
                    .variant_name = null,
                });
                return false;
            },
            .alias => {
                // Type aliases need a catch-all
                try missing.append(self.allocator, .{
                    .description = "_ (catch-all pattern needed)",
                    .variant_name = null,
                });
                return false;
            },
        };
    }

    /// Check exhaustiveness for sum types (ADTs)
    fn checkSumTypeExhaustiveness(
        self: *PatternCompiler,
        variants: []const Symbol.VariantInfo,
        spaces: []PatternSpace,
        missing: *std.ArrayListUnmanaged(MissingPattern),
    ) !bool {
        // Track which variants are covered
        var covered = std.StringHashMapUnmanaged(void){};
        defer covered.deinit(self.allocator);

        for (spaces) |space| {
            try self.collectCoveredVariants(space, &covered);
        }

        // Check if all variants are covered
        var all_covered = true;
        for (variants) |variant| {
            if (!covered.contains(variant.name)) {
                all_covered = false;
                try missing.append(self.allocator, .{
                    .description = variant.name,
                    .variant_name = variant.name,
                });
            }
        }

        return all_covered;
    }

    /// Collect variant names covered by a pattern space
    fn collectCoveredVariants(
        self: *PatternCompiler,
        space: PatternSpace,
        covered: *std.StringHashMapUnmanaged(void),
    ) !void {
        switch (space) {
            .constructor => |ctor| {
                try covered.put(self.allocator, ctor.variant_name, {});
            },
            .union_space => |alts| {
                for (alts) |alt| {
                    try self.collectCoveredVariants(alt, covered);
                }
            },
            else => {},
        }
    }

    /// Check exhaustiveness for tuple types
    fn checkTupleExhaustiveness(
        self: *PatternCompiler,
        element_types: []ResolvedType,
        spaces: []PatternSpace,
        missing: *std.ArrayListUnmanaged(MissingPattern),
    ) !bool {
        // Check if there's a wildcard pattern or tuple that covers all elements
        for (spaces) |space| {
            switch (space) {
                .any => return true,
                .tuple => |elems| {
                    if (elems.len == element_types.len) {
                        var all_any = true;
                        for (elems) |elem| {
                            if (elem != .any) {
                                all_any = false;
                                break;
                            }
                        }
                        if (all_any) return true;
                    }
                },
                .union_space => |alts| {
                    for (alts) |alt| {
                        if (alt == .any) return true;
                    }
                },
                else => {},
            }
        }

        // TODO: More sophisticated tuple exhaustiveness checking
        // For now, require a catch-all pattern
        try missing.append(self.allocator, .{
            .description = "_ or (_, ...) tuple pattern",
            .variant_name = null,
        });
        return false;
    }

    /// Check exhaustiveness for Option types
    fn checkOptionExhaustiveness(
        self: *PatternCompiler,
        spaces: []PatternSpace,
        missing: *std.ArrayListUnmanaged(MissingPattern),
    ) !bool {
        var has_some = false;
        var has_none = false;

        for (spaces) |space| {
            switch (space) {
                .any => return true,
                .constructor => |ctor| {
                    if (std.mem.eql(u8, ctor.variant_name, "Some")) {
                        has_some = true;
                    } else if (std.mem.eql(u8, ctor.variant_name, "None")) {
                        has_none = true;
                    }
                },
                .union_space => |alts| {
                    for (alts) |alt| {
                        switch (alt) {
                            .any => return true,
                            .constructor => |ctor| {
                                if (std.mem.eql(u8, ctor.variant_name, "Some")) {
                                    has_some = true;
                                } else if (std.mem.eql(u8, ctor.variant_name, "None")) {
                                    has_none = true;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        if (!has_some) {
            try missing.append(self.allocator, .{
                .description = "Some(_)",
                .variant_name = "Some",
            });
        }
        if (!has_none) {
            try missing.append(self.allocator, .{
                .description = "None",
                .variant_name = "None",
            });
        }

        return has_some and has_none;
    }

    /// Check exhaustiveness for Result types
    fn checkResultExhaustiveness(
        self: *PatternCompiler,
        spaces: []PatternSpace,
        missing: *std.ArrayListUnmanaged(MissingPattern),
    ) !bool {
        var has_ok = false;
        var has_err = false;

        for (spaces) |space| {
            switch (space) {
                .any => return true,
                .constructor => |ctor| {
                    if (std.mem.eql(u8, ctor.variant_name, "Ok")) {
                        has_ok = true;
                    } else if (std.mem.eql(u8, ctor.variant_name, "Err")) {
                        has_err = true;
                    }
                },
                .union_space => |alts| {
                    for (alts) |alt| {
                        switch (alt) {
                            .any => return true,
                            .constructor => |ctor| {
                                if (std.mem.eql(u8, ctor.variant_name, "Ok")) {
                                    has_ok = true;
                                } else if (std.mem.eql(u8, ctor.variant_name, "Err")) {
                                    has_err = true;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        if (!has_ok) {
            try missing.append(self.allocator, .{
                .description = "Ok(_)",
                .variant_name = "Ok",
            });
        }
        if (!has_err) {
            try missing.append(self.allocator, .{
                .description = "Err(_)",
                .variant_name = "Err",
            });
        }

        return has_ok and has_err;
    }

    /// Report non-exhaustive match error
    pub fn reportNonExhaustive(
        self: *PatternCompiler,
        result: ExhaustivenessResult,
        span: Span,
    ) !void {
        if (!result.is_exhaustive and result.missing_patterns.len > 0) {
            var builder = errors_mod.DiagnosticBuilder.init(self.allocator, span, .err);
            errdefer builder.deinit();

            try builder.write("non-exhaustive match: missing patterns for ");

            for (result.missing_patterns, 0..) |mp, i| {
                if (i > 0) try builder.write(", ");
                try builder.write(mp.description);
            }

            try self.diagnostics.append(self.allocator, try builder.build());
        }
    }

    /// Report unreachable pattern warning
    pub fn reportUnreachablePatterns(
        self: *PatternCompiler,
        result: ExhaustivenessResult,
        patterns: []const *const Pattern,
    ) !void {
        for (result.unreachable_arms) |arm_idx| {
            if (arm_idx < patterns.len) {
                try self.diagnostics.append(
                    self.allocator,
                    try errors_mod.warning(
                        self.allocator,
                        "unreachable pattern: this pattern will never be matched",
                        patterns[arm_idx].span,
                    ),
                );
            }
        }
    }
};

/// Check if two pattern spaces overlap (could match the same value)
fn spacesOverlap(a: PatternSpace, b: PatternSpace) bool {
    // Any overlaps with everything
    if (a == .any or b == .any) return true;

    // Same type comparisons
    switch (a) {
        .bool_value => |av| {
            if (b == .bool_value) return av == b.bool_value;
        },
        .int_value => |av| {
            if (b == .int_value) return av == b.int_value;
            if (b == .range) return valueInRange(av, b.range);
        },
        .char_value => |av| {
            if (b == .char_value) return av == b.char_value;
            if (b == .range) return valueInRange(@intCast(av), b.range);
        },
        .string_value => |av| {
            if (b == .string_value) return std.mem.eql(u8, av, b.string_value);
        },
        .float_value => |av| {
            if (b == .float_value) return av == b.float_value;
        },
        .constructor => |ac| {
            if (b == .constructor) {
                return std.mem.eql(u8, ac.variant_name, b.constructor.variant_name);
            }
        },
        .range => |ar| {
            if (b == .int_value) return valueInRange(b.int_value, ar);
            if (b == .char_value) return valueInRange(@intCast(b.char_value), ar);
            if (b == .range) return rangesOverlap(ar, b.range);
        },
        .union_space => |alts| {
            for (alts) |alt| {
                if (spacesOverlap(alt, b)) return true;
            }
            return false;
        },
        else => {},
    }

    // Check b's union space
    if (b == .union_space) {
        for (b.union_space) |alt| {
            if (spacesOverlap(a, alt)) return true;
        }
    }

    return false;
}

/// Check if pattern space 'cover' fully covers pattern space 'covered'
fn spaceCovers(cover: PatternSpace, covered: PatternSpace) bool {
    // Any covers everything
    if (cover == .any) return true;

    // Nothing can cover any except any itself
    if (covered == .any) return false;

    switch (cover) {
        .bool_value => |cv| {
            if (covered == .bool_value) return cv == covered.bool_value;
        },
        .int_value => |cv| {
            if (covered == .int_value) return cv == covered.int_value;
        },
        .char_value => |cv| {
            if (covered == .char_value) return cv == covered.char_value;
        },
        .string_value => |cv| {
            if (covered == .string_value) return std.mem.eql(u8, cv, covered.string_value);
        },
        .float_value => |cv| {
            if (covered == .float_value) return cv == covered.float_value;
        },
        .constructor => |cc| {
            if (covered == .constructor) {
                if (!std.mem.eql(u8, cc.variant_name, covered.constructor.variant_name)) {
                    return false;
                }
                // Check all arguments are covered
                if (cc.arguments.len != covered.constructor.arguments.len) {
                    return false;
                }
                for (cc.arguments, covered.constructor.arguments) |ca, cova| {
                    if (!spaceCovers(ca, cova)) return false;
                }
                return true;
            }
        },
        .range => |cr| {
            if (covered == .int_value) return valueInRange(covered.int_value, cr);
            if (covered == .char_value) return valueInRange(@intCast(covered.char_value), cr);
            if (covered == .range) return rangeCovers(cr, covered.range);
        },
        .union_space => |alts| {
            // Union covers if any alternative covers
            for (alts) |alt| {
                if (spaceCovers(alt, covered)) return true;
            }
        },
        .tuple => |ct| {
            if (covered == .tuple) {
                if (ct.len != covered.tuple.len) return false;
                for (ct, covered.tuple) |ce, cove| {
                    if (!spaceCovers(ce, cove)) return false;
                }
                return true;
            }
        },
        else => {},
    }

    // Check if covered is a union and all alternatives are covered
    if (covered == .union_space) {
        for (covered.union_space) |alt| {
            if (!spaceCovers(cover, alt)) return false;
        }
        return true;
    }

    return false;
}

/// Check if a value is within a range
fn valueInRange(value: i128, range: PatternSpace.RangeSpace) bool {
    if (range.start) |start| {
        if (value < start) return false;
    }
    if (range.end) |end| {
        if (range.inclusive) {
            if (value > end) return false;
        } else {
            if (value >= end) return false;
        }
    }
    return true;
}

/// Check if two ranges overlap
fn rangesOverlap(a: PatternSpace.RangeSpace, b: PatternSpace.RangeSpace) bool {
    // Get effective bounds
    const a_start = a.start orelse std.math.minInt(i128);
    const a_end = if (a.inclusive)
        (a.end orelse std.math.maxInt(i128))
    else
        (a.end orelse std.math.maxInt(i128)) - 1;

    const b_start = b.start orelse std.math.minInt(i128);
    const b_end = if (b.inclusive)
        (b.end orelse std.math.maxInt(i128))
    else
        (b.end orelse std.math.maxInt(i128)) - 1;

    // Ranges overlap if neither is completely before the other
    return a_start <= b_end and b_start <= a_end;
}

/// Check if range 'cover' fully covers range 'covered'
fn rangeCovers(cover: PatternSpace.RangeSpace, covered: PatternSpace.RangeSpace) bool {
    const cover_start = cover.start orelse std.math.minInt(i128);
    const cover_end = if (cover.inclusive)
        (cover.end orelse std.math.maxInt(i128))
    else
        (cover.end orelse std.math.maxInt(i128)) - 1;

    const covered_start = covered.start orelse std.math.minInt(i128);
    const covered_end = if (covered.inclusive)
        (covered.end orelse std.math.maxInt(i128))
    else
        (covered.end orelse std.math.maxInt(i128)) - 1;

    return cover_start <= covered_start and cover_end >= covered_end;
}

// ============== Tests ==============

test "pattern space creation - wildcard" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 2, .offset = 1 },
    };

    var pattern = Pattern.wildcard(span);
    const space = try compiler.patternToSpace(&pattern);

    try std.testing.expect(space == .any);
}

test "pattern space creation - bool literal" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    var true_pattern = Pattern.init(.{ .bool_literal = true }, span);
    const true_space = try compiler.patternToSpace(&true_pattern);

    try std.testing.expect(true_space == .bool_value);
    try std.testing.expect(true_space.bool_value == true);
}

test "bool exhaustiveness - complete" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    var true_pattern = Pattern.init(.{ .bool_literal = true }, span);
    var false_pattern = Pattern.init(.{ .bool_literal = false }, span);

    const patterns = [_]*Pattern{ &true_pattern, &false_pattern };

    const bool_type = ResolvedType.primitive(.bool, span);

    const result = try compiler.checkExhaustiveness(&patterns, bool_type, span);
    defer allocator.free(result.missing_patterns);
    defer allocator.free(result.unreachable_arms);

    try std.testing.expect(result.is_exhaustive);
    try std.testing.expectEqual(@as(usize, 0), result.missing_patterns.len);
}

test "bool exhaustiveness - incomplete" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);
    defer {
        for (diagnostics.items) |d| {
            allocator.free(d.message);
        }
    }

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    var true_pattern = Pattern.init(.{ .bool_literal = true }, span);

    const patterns = [_]*Pattern{&true_pattern};

    const bool_type = ResolvedType.primitive(.bool, span);

    const result = try compiler.checkExhaustiveness(&patterns, bool_type, span);
    defer allocator.free(result.missing_patterns);
    defer allocator.free(result.unreachable_arms);

    try std.testing.expect(!result.is_exhaustive);
    try std.testing.expectEqual(@as(usize, 1), result.missing_patterns.len);
    try std.testing.expectEqualStrings("false", result.missing_patterns[0].description);
}

test "wildcard covers everything" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 2, .offset = 1 },
    };

    var wildcard_pat = Pattern.wildcard(span);

    const patterns = [_]*Pattern{&wildcard_pat};

    const bool_type = ResolvedType.primitive(.bool, span);

    const result = try compiler.checkExhaustiveness(&patterns, bool_type, span);
    defer allocator.free(result.missing_patterns);
    defer allocator.free(result.unreachable_arms);

    try std.testing.expect(result.is_exhaustive);
}

test "integer needs catch-all" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 2, .offset = 1 },
    };

    var lit_pattern = Pattern.init(.{ .integer_literal = 42 }, span);

    const patterns = [_]*Pattern{&lit_pattern};

    const int_type = ResolvedType.primitive(.i32, span);

    const result = try compiler.checkExhaustiveness(&patterns, int_type, span);
    defer allocator.free(result.missing_patterns);
    defer allocator.free(result.unreachable_arms);

    try std.testing.expect(!result.is_exhaustive);
    try std.testing.expect(result.missing_patterns.len > 0);
}

test "range overlap detection" {
    // Test overlapping ranges
    const range1 = PatternSpace.RangeSpace{ .start = 0, .end = 10, .inclusive = true };
    const range2 = PatternSpace.RangeSpace{ .start = 5, .end = 15, .inclusive = true };
    try std.testing.expect(rangesOverlap(range1, range2));

    // Test non-overlapping ranges
    const range3 = PatternSpace.RangeSpace{ .start = 0, .end = 5, .inclusive = true };
    const range4 = PatternSpace.RangeSpace{ .start = 10, .end = 15, .inclusive = true };
    try std.testing.expect(!rangesOverlap(range3, range4));

    // Test adjacent ranges (exclusive)
    const range5 = PatternSpace.RangeSpace{ .start = 0, .end = 5, .inclusive = false };
    const range6 = PatternSpace.RangeSpace{ .start = 5, .end = 10, .inclusive = true };
    try std.testing.expect(!rangesOverlap(range5, range6));

    // Test adjacent ranges (inclusive)
    const range7 = PatternSpace.RangeSpace{ .start = 0, .end = 5, .inclusive = true };
    const range8 = PatternSpace.RangeSpace{ .start = 5, .end = 10, .inclusive = true };
    try std.testing.expect(rangesOverlap(range7, range8));
}

test "space covers detection" {
    // Any covers everything
    try std.testing.expect(spaceCovers(.any, .{ .bool_value = true }));
    try std.testing.expect(spaceCovers(.any, .{ .int_value = 42 }));

    // Same value covers itself
    try std.testing.expect(spaceCovers(.{ .bool_value = true }, .{ .bool_value = true }));
    try std.testing.expect(!spaceCovers(.{ .bool_value = true }, .{ .bool_value = false }));

    // Nothing covers any except any
    try std.testing.expect(!spaceCovers(.{ .bool_value = true }, .any));
}

test "Option exhaustiveness checking" {
    // Verify direct PatternSpace-based Option checking works
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    // Test Option checking directly with pattern spaces
    var missing = std.ArrayListUnmanaged(MissingPattern){};
    defer missing.deinit(allocator);

    // Test complete coverage
    const some_space = PatternSpace{ .constructor = .{
        .variant_name = "Some",
        .type_symbol_id = null,
        .arguments = &.{},
    } };
    const none_space = PatternSpace{ .constructor = .{
        .variant_name = "None",
        .type_symbol_id = null,
        .arguments = &.{},
    } };

    var complete_spaces_arr = [_]PatternSpace{ some_space, none_space };
    const is_complete = try compiler.checkOptionExhaustiveness(complete_spaces_arr[0..], &missing);
    try std.testing.expect(is_complete);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);

    // Test incomplete coverage (missing Some)
    var missing2 = std.ArrayListUnmanaged(MissingPattern){};
    defer missing2.deinit(allocator);

    var incomplete_spaces_arr = [_]PatternSpace{none_space};
    const is_incomplete = try compiler.checkOptionExhaustiveness(incomplete_spaces_arr[0..], &missing2);
    try std.testing.expect(!is_incomplete);
    try std.testing.expectEqual(@as(usize, 1), missing2.items.len);
    try std.testing.expectEqualStrings("Some(_)", missing2.items[0].description);
}

test "Result exhaustiveness checking" {
    // Verify direct PatternSpace-based Result checking works
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    // Test Result checking directly with pattern spaces
    var missing = std.ArrayListUnmanaged(MissingPattern){};
    defer missing.deinit(allocator);

    // Test complete coverage
    const ok_space = PatternSpace{ .constructor = .{
        .variant_name = "Ok",
        .type_symbol_id = null,
        .arguments = &.{},
    } };
    const err_space = PatternSpace{ .constructor = .{
        .variant_name = "Err",
        .type_symbol_id = null,
        .arguments = &.{},
    } };

    var complete_spaces_arr = [_]PatternSpace{ ok_space, err_space };
    const is_complete = try compiler.checkResultExhaustiveness(complete_spaces_arr[0..], &missing);
    try std.testing.expect(is_complete);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);

    // Test incomplete coverage (missing Err)
    var missing2 = std.ArrayListUnmanaged(MissingPattern){};
    defer missing2.deinit(allocator);

    var incomplete_spaces_arr = [_]PatternSpace{ok_space};
    const is_incomplete = try compiler.checkResultExhaustiveness(incomplete_spaces_arr[0..], &missing2);
    try std.testing.expect(!is_incomplete);
    try std.testing.expectEqual(@as(usize, 1), missing2.items.len);
    try std.testing.expectEqualStrings("Err(_)", missing2.items[0].description);
}

test "union space for or-patterns" {
    // Test that union spaces work correctly for or-patterns
    const bool_true = PatternSpace{ .bool_value = true };
    const bool_false = PatternSpace{ .bool_value = false };

    // Union of true | false should cover both
    var union_alts_arr = [_]PatternSpace{ bool_true, bool_false };
    const union_space = PatternSpace{ .union_space = union_alts_arr[0..] };

    // Check that union space overlaps with individual values
    try std.testing.expect(spacesOverlap(union_space, bool_true));
    try std.testing.expect(spacesOverlap(union_space, bool_false));
}

test "identifier pattern covers like wildcard" {
    const allocator = std.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(allocator);

    var compiler = PatternCompiler.init(allocator, &table, &diagnostics);

    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 2, .offset = 1 },
    };

    // Identifier pattern "x" should cover all values like wildcard
    var ident_pattern = Pattern.identifier("x", span);

    const patterns = [_]*Pattern{&ident_pattern};

    const bool_type = ResolvedType.primitive(.bool, span);

    const result = try compiler.checkExhaustiveness(&patterns, bool_type, span);
    defer allocator.free(result.missing_patterns);
    defer allocator.free(result.unreachable_arms);

    try std.testing.expect(result.is_exhaustive);
}

test "tuple space structure" {
    // Test tuple PatternSpace operations directly
    const elem1 = PatternSpace.any;
    const elem2 = PatternSpace{ .bool_value = true };
    var elems_arr = [_]PatternSpace{ elem1, elem2 };

    const tuple_space = PatternSpace{ .tuple = elems_arr[0..] };

    // Verify structure
    try std.testing.expect(tuple_space == .tuple);
    try std.testing.expectEqual(@as(usize, 2), tuple_space.tuple.len);
    try std.testing.expect(tuple_space.tuple[0] == .any);
    try std.testing.expect(tuple_space.tuple[1] == .bool_value);
}
