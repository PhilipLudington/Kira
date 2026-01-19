//! Pattern AST nodes for the Kira language.
//!
//! Patterns are used in match statements, let bindings (destructuring),
//! and for loops.

const std = @import("std");
const lexer = @import("../lexer/root.zig");

pub const Span = lexer.Span;
pub const Expression = @import("expression.zig").Expression;
pub const Type = @import("types.zig").Type;

/// Represents a pattern in the Kira language.
pub const Pattern = struct {
    kind: PatternKind,
    span: Span,

    pub const PatternKind = union(enum) {
        // Wildcard pattern: `_`
        wildcard: void,

        // Identifier pattern: `x` (binds value to name)
        identifier: IdentifierPattern,

        // Literal patterns
        integer_literal: i128,
        float_literal: f64,
        string_literal: []const u8,
        char_literal: u21,
        bool_literal: bool,

        // Constructor pattern: `Some(x)`, `Cons(head, tail)`, `None`
        constructor: ConstructorPattern,

        // Record pattern: `Point { x: px, y: py }` or `Point { x, y }`
        record: RecordPattern,

        // Tuple pattern: `(a, b, c)`
        tuple: TuplePattern,

        // Or pattern: `1 | 2 | 3`
        or_pattern: OrPattern,

        // Guard pattern: `n if n > 0`
        guarded: GuardedPattern,

        // Range pattern: `1..10` or `'a'..='z'`
        range: RangePattern,

        // Rest pattern: `..` (in tuples/records to ignore remaining)
        rest: void,

        // Type-annotated pattern: `x: Type`
        typed: TypedPattern,
    };

    /// Identifier pattern with optional mutability
    pub const IdentifierPattern = struct {
        name: []const u8,
        is_mutable: bool, // `var x` pattern in for loops
    };

    /// Constructor pattern for matching ADT variants
    pub const ConstructorPattern = struct {
        type_path: ?[][]const u8, // Optional: `Option.Some` vs just `Some`
        variant_name: []const u8,
        arguments: ?[]PatternArg,
    };

    /// Pattern argument (can be positional or named)
    pub const PatternArg = union(enum) {
        positional: *Pattern,
        named: NamedPatternArg,
    };

    /// Named pattern argument: `value: x`
    pub const NamedPatternArg = struct {
        name: []const u8,
        pattern: *Pattern,
        span: Span,
    };

    /// Record pattern: `{ field1: pat1, field2 }`
    pub const RecordPattern = struct {
        type_name: ?[]const u8,
        fields: []RecordFieldPattern,
        has_rest: bool, // `{ x, .. }` ignores other fields
    };

    /// Record field pattern
    pub const RecordFieldPattern = struct {
        name: []const u8,
        pattern: ?*Pattern, // None means use name as pattern: `{ x }` == `{ x: x }`
        span: Span,
    };

    /// Tuple pattern
    pub const TuplePattern = struct {
        elements: []*Pattern,
    };

    /// Or pattern: matches if any sub-pattern matches
    pub const OrPattern = struct {
        patterns: []*Pattern,
    };

    /// Guarded pattern: pattern with condition
    pub const GuardedPattern = struct {
        pattern: *Pattern,
        guard: *Expression,
    };

    /// Range pattern for matching ranges of values
    pub const RangePattern = struct {
        start: ?RangeBound,
        end: ?RangeBound,
        inclusive: bool,
    };

    /// Range bound (value at start or end of range)
    pub const RangeBound = union(enum) {
        integer: i128,
        char: u21,
    };

    /// Type-annotated pattern
    pub const TypedPattern = struct {
        pattern: *Pattern,
        expected_type: *Type,
    };

    /// Create a new pattern with the given kind and span
    pub fn init(kind: PatternKind, span: Span) Pattern {
        return .{ .kind = kind, .span = span };
    }

    /// Create a wildcard pattern
    pub fn wildcard(span: Span) Pattern {
        return init(.wildcard, span);
    }

    /// Create an identifier pattern
    pub fn identifier(name: []const u8, span: Span) Pattern {
        return init(.{ .identifier = .{ .name = name, .is_mutable = false } }, span);
    }

    /// Create a mutable identifier pattern
    pub fn mutableIdentifier(name: []const u8, span: Span) Pattern {
        return init(.{ .identifier = .{ .name = name, .is_mutable = true } }, span);
    }

    /// Check if this pattern is irrefutable (always matches)
    pub fn isIrrefutable(self: Pattern) bool {
        return switch (self.kind) {
            .wildcard => true,
            .identifier => true,
            .typed => |t| t.pattern.isIrrefutable(),
            .tuple => |t| {
                for (t.elements) |elem| {
                    if (!elem.isIrrefutable()) return false;
                }
                return true;
            },
            .record => |r| {
                for (r.fields) |field| {
                    if (field.pattern) |pat| {
                        if (!pat.isIrrefutable()) return false;
                    }
                }
                return true;
            },
            else => false,
        };
    }

    /// Check if this pattern binds any names
    pub fn bindsNames(self: Pattern) bool {
        return switch (self.kind) {
            .wildcard, .rest => false,
            .identifier => true,
            .integer_literal, .float_literal, .string_literal, .char_literal, .bool_literal => false,
            .constructor => |c| {
                if (c.arguments) |args| {
                    for (args) |arg| {
                        const pat = switch (arg) {
                            .positional => |p| p,
                            .named => |n| n.pattern,
                        };
                        if (pat.bindsNames()) return true;
                    }
                }
                return false;
            },
            .record => |r| {
                for (r.fields) |field| {
                    if (field.pattern) |pat| {
                        if (pat.bindsNames()) return true;
                    } else {
                        return true; // Shorthand `{ x }` binds x
                    }
                }
                return false;
            },
            .tuple => |t| {
                for (t.elements) |elem| {
                    if (elem.bindsNames()) return true;
                }
                return false;
            },
            .or_pattern => |o| {
                // All branches must bind the same names
                if (o.patterns.len > 0) {
                    return o.patterns[0].bindsNames();
                }
                return false;
            },
            .guarded => |g| g.pattern.bindsNames(),
            .range => false,
            .typed => |t| t.pattern.bindsNames(),
        };
    }

    /// Get bound names from this pattern
    pub fn getBoundNames(self: Pattern, names: *std.ArrayList([]const u8)) !void {
        switch (self.kind) {
            .wildcard, .rest => {},
            .identifier => |id| try names.append(id.name),
            .integer_literal, .float_literal, .string_literal, .char_literal, .bool_literal, .range => {},
            .constructor => |c| {
                if (c.arguments) |args| {
                    for (args) |arg| {
                        const pat = switch (arg) {
                            .positional => |p| p,
                            .named => |n| n.pattern,
                        };
                        try pat.getBoundNames(names);
                    }
                }
            },
            .record => |r| {
                for (r.fields) |field| {
                    if (field.pattern) |pat| {
                        try pat.getBoundNames(names);
                    } else {
                        try names.append(field.name);
                    }
                }
            },
            .tuple => |t| {
                for (t.elements) |elem| {
                    try elem.getBoundNames(names);
                }
            },
            .or_pattern => |o| {
                // All branches bind the same names, just check first
                if (o.patterns.len > 0) {
                    try o.patterns[0].getBoundNames(names);
                }
            },
            .guarded => |g| try g.pattern.getBoundNames(names),
            .typed => |t| try t.pattern.getBoundNames(names),
        }
    }
};

test "pattern irrefutability" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 2, .offset = 1 },
    };

    // Wildcard is irrefutable
    const wild = Pattern.wildcard(span);
    try std.testing.expect(wild.isIrrefutable());

    // Identifier is irrefutable
    const ident = Pattern.identifier("x", span);
    try std.testing.expect(ident.isIrrefutable());

    // Literal is refutable
    const lit = Pattern.init(.{ .integer_literal = 42 }, span);
    try std.testing.expect(!lit.isIrrefutable());
}

test "pattern name binding" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 2, .offset = 1 },
    };

    // Wildcard doesn't bind
    const wild = Pattern.wildcard(span);
    try std.testing.expect(!wild.bindsNames());

    // Identifier binds
    const ident = Pattern.identifier("x", span);
    try std.testing.expect(ident.bindsNames());

    // Literal doesn't bind
    const lit = Pattern.init(.{ .bool_literal = true }, span);
    try std.testing.expect(!lit.bindsNames());
}
