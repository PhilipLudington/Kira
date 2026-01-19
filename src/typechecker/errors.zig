//! Type checking error definitions and formatting for the Kira language.
//!
//! Provides structured diagnostic messages with spans, related information,
//! and formatting support for clear error reporting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const types = @import("types.zig");

pub const Span = ast.Span;
pub const ResolvedType = types.ResolvedType;

/// Kind of diagnostic message
pub const DiagnosticKind = enum {
    err,
    warning,
    hint,

    pub fn toString(self: DiagnosticKind) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .hint => "hint",
        };
    }
};

/// Related information for a diagnostic
pub const RelatedInfo = struct {
    message: []const u8,
    span: Span,
};

/// A type checking diagnostic message
pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
    kind: DiagnosticKind,
    related: ?[]const RelatedInfo,

    /// Format the diagnostic for display
    pub fn format(
        self: Diagnostic,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s}: {s} at {d}:{d}\n", .{
            self.kind.toString(),
            self.message,
            self.span.start.line,
            self.span.start.column,
        });

        if (self.related) |related| {
            for (related) |info| {
                try writer.print("  note: {s} at {d}:{d}\n", .{
                    info.message,
                    info.span.start.line,
                    info.span.start.column,
                });
            }
        }
    }
};

/// Type error codes for categorization
pub const TypeErrorCode = enum {
    // Type mismatch errors
    type_mismatch,
    expected_type,
    incompatible_types,

    // Operator errors
    invalid_binary_operand,
    invalid_unary_operand,

    // Call errors
    not_callable,
    wrong_argument_count,
    argument_type_mismatch,

    // Access errors
    no_such_field,
    no_such_method,
    invalid_tuple_index,
    invalid_index_type,

    // Pattern errors
    pattern_type_mismatch,
    non_exhaustive_match,
    unreachable_pattern,

    // Generic errors
    wrong_type_argument_count,
    constraint_not_satisfied,
    cannot_infer_type,

    // Effect errors
    effect_violation,
    missing_try,
    invalid_try,

    // Declaration errors
    duplicate_definition,
    undefined_symbol,
    undefined_type,

    // Other
    invalid_cast,
    cyclic_type,
    self_outside_impl,
};

/// Builder for constructing diagnostic messages
pub const DiagnosticBuilder = struct {
    allocator: Allocator,
    message_parts: std.ArrayListUnmanaged(u8),
    span: Span,
    kind: DiagnosticKind,
    related: std.ArrayListUnmanaged(RelatedInfo),

    pub fn init(allocator: Allocator, span: Span, kind: DiagnosticKind) DiagnosticBuilder {
        return .{
            .allocator = allocator,
            .message_parts = .{},
            .span = span,
            .kind = kind,
            .related = .{},
        };
    }

    pub fn deinit(self: *DiagnosticBuilder) void {
        self.message_parts.deinit(self.allocator);
        self.related.deinit(self.allocator);
    }

    /// Append text to the message
    pub fn write(self: *DiagnosticBuilder, text: []const u8) !void {
        try self.message_parts.appendSlice(self.allocator, text);
    }

    /// Append formatted text to the message
    pub fn print(self: *DiagnosticBuilder, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
        try self.message_parts.appendSlice(self.allocator, text);
    }

    /// Write a type name to the message
    pub fn writeType(self: *DiagnosticBuilder, resolved_type: ResolvedType) !void {
        try resolved_type.writeTypeName(self.message_parts.writer(self.allocator));
    }

    /// Add related information
    pub fn addRelated(self: *DiagnosticBuilder, message: []const u8, span: Span) !void {
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.related.append(self.allocator, .{
            .message = msg_copy,
            .span = span,
        });
    }

    /// Build the final diagnostic
    pub fn build(self: *DiagnosticBuilder) !Diagnostic {
        const message = try self.message_parts.toOwnedSlice(self.allocator);
        const related = if (self.related.items.len > 0)
            try self.related.toOwnedSlice(self.allocator)
        else
            null;

        return .{
            .message = message,
            .span = self.span,
            .kind = self.kind,
            .related = related,
        };
    }
};

/// Create a type mismatch error
pub fn typeMismatch(
    allocator: Allocator,
    expected: ResolvedType,
    actual: ResolvedType,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.write("type mismatch: expected '");
    try builder.writeType(expected);
    try builder.write("', found '");
    try builder.writeType(actual);
    try builder.write("'");

    return builder.build();
}

/// Create an invalid binary operand error
pub fn invalidBinaryOperand(
    allocator: Allocator,
    operator: []const u8,
    left_type: ResolvedType,
    right_type: ResolvedType,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.write("invalid operands to binary '");
    try builder.write(operator);
    try builder.write("': '");
    try builder.writeType(left_type);
    try builder.write("' and '");
    try builder.writeType(right_type);
    try builder.write("'");

    return builder.build();
}

/// Create an invalid unary operand error
pub fn invalidUnaryOperand(
    allocator: Allocator,
    operator: []const u8,
    operand_type: ResolvedType,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.write("invalid operand to unary '");
    try builder.write(operator);
    try builder.write("': '");
    try builder.writeType(operand_type);
    try builder.write("'");

    return builder.build();
}

/// Create a not callable error
pub fn notCallable(
    allocator: Allocator,
    callee_type: ResolvedType,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.write("type '");
    try builder.writeType(callee_type);
    try builder.write("' is not callable");

    return builder.build();
}

/// Create a wrong argument count error
pub fn wrongArgumentCount(
    allocator: Allocator,
    expected: usize,
    actual: usize,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.print("expected {d} argument(s), found {d}", .{ expected, actual });

    return builder.build();
}

/// Create a no such field error
pub fn noSuchField(
    allocator: Allocator,
    type_name: []const u8,
    field_name: []const u8,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.write("type '");
    try builder.write(type_name);
    try builder.write("' has no field '");
    try builder.write(field_name);
    try builder.write("'");

    return builder.build();
}

/// Create an undefined symbol error
pub fn undefinedSymbol(
    allocator: Allocator,
    name: []const u8,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.write("undefined symbol '");
    try builder.write(name);
    try builder.write("'");

    return builder.build();
}

/// Create an undefined type error
pub fn undefinedType(
    allocator: Allocator,
    name: []const u8,
    span: Span,
) !Diagnostic {
    var builder = DiagnosticBuilder.init(allocator, span, .err);
    errdefer builder.deinit();

    try builder.write("undefined type '");
    try builder.write(name);
    try builder.write("'");

    return builder.build();
}

/// Create an effect violation error
pub fn effectViolation(
    allocator: Allocator,
    message: []const u8,
    span: Span,
) !Diagnostic {
    return .{
        .message = try allocator.dupe(u8, message),
        .span = span,
        .kind = .err,
        .related = null,
    };
}

/// Create a simple error with a message
pub fn simpleError(
    allocator: Allocator,
    message: []const u8,
    span: Span,
) !Diagnostic {
    return .{
        .message = try allocator.dupe(u8, message),
        .span = span,
        .kind = .err,
        .related = null,
    };
}

/// Create a warning
pub fn warning(
    allocator: Allocator,
    message: []const u8,
    span: Span,
) !Diagnostic {
    return .{
        .message = try allocator.dupe(u8, message),
        .span = span,
        .kind = .warning,
        .related = null,
    };
}

test "diagnostic formatting" {
    const span = Span{
        .start = .{ .line = 10, .column = 5, .offset = 100 },
        .end = .{ .line = 10, .column = 15, .offset = 110 },
    };

    const diag = Diagnostic{
        .message = "test error message",
        .span = span,
        .kind = .err,
        .related = null,
    };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try diag.format("", .{}, fbs.writer());
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test error message") != null);
}
