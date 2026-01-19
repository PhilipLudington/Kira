//! Statement AST nodes for the Kira language.
//!
//! Statements do not produce values and are executed for their effects.
//! In Kira, control flow constructs are statements, not expressions.

const std = @import("std");
const lexer = @import("../lexer/root.zig");

pub const Span = lexer.Span;
pub const Expression = @import("expression.zig").Expression;
pub const Type = @import("types.zig").Type;
pub const Pattern = @import("pattern.zig").Pattern;

/// Represents a statement in the Kira language.
pub const Statement = struct {
    kind: StatementKind,
    span: Span,

    pub const StatementKind = union(enum) {
        // Bindings
        let_binding: LetBinding,
        var_binding: VarBinding,

        // Assignment (only valid for var bindings)
        assignment: Assignment,

        // Control flow
        if_statement: IfStatement,
        for_loop: ForLoop,
        match_statement: MatchStatement,
        return_statement: ReturnStatement,
        break_statement: BreakStatement,

        // Expression statement (expression evaluated for side effects)
        expression_statement: *Expression,

        // Block of statements
        block: []Statement,
    };

    /// Immutable binding: `let name: Type = value`
    pub const LetBinding = struct {
        pattern: *Pattern, // Can be simple identifier or destructuring pattern
        explicit_type: *Type, // Required in Kira
        initializer: *Expression,
        is_public: bool, // `pub let`
    };

    /// Mutable binding: `var name: Type = value`
    /// Only allowed in effect functions
    pub const VarBinding = struct {
        name: []const u8,
        explicit_type: *Type,
        initializer: ?*Expression, // May be uninitialized: `var x: i32`
    };

    /// Assignment: `name = value` or `obj.field = value`
    pub const Assignment = struct {
        target: AssignmentTarget,
        value: *Expression,
    };

    /// Target of an assignment
    pub const AssignmentTarget = union(enum) {
        identifier: []const u8,
        field_access: FieldTarget,
        index_access: IndexTarget,
    };

    pub const FieldTarget = struct {
        object: *Expression,
        field: []const u8,
    };

    pub const IndexTarget = struct {
        object: *Expression,
        index: *Expression,
    };

    /// If statement: `if cond { } else { }`
    pub const IfStatement = struct {
        condition: *Expression,
        then_branch: []Statement,
        else_branch: ?ElseBranch,
    };

    /// Else branch can be a block or another if statement (else if)
    pub const ElseBranch = union(enum) {
        block: []Statement,
        else_if: *Statement, // Must be another IfStatement
    };

    /// For loop: `for item in iterable { }`
    pub const ForLoop = struct {
        pattern: *Pattern, // Usually identifier, but can be destructuring
        iterable: *Expression,
        body: []Statement,
    };

    /// Match statement: `match expr { pattern => { ... } }`
    pub const MatchStatement = struct {
        subject: *Expression,
        arms: []MatchArm,
    };

    /// Match arm with pattern, optional guard, and body
    pub const MatchArm = struct {
        pattern: *Pattern,
        guard: ?*Expression, // Optional `if condition`
        body: []Statement,
        span: Span,
    };

    /// Return statement: `return` or `return expr`
    pub const ReturnStatement = struct {
        value: ?*Expression,
    };

    /// Break statement: `break` or `break expr` (for labeled blocks)
    pub const BreakStatement = struct {
        label: ?[]const u8,
        value: ?*Expression,
    };

    /// Create a new statement with the given kind and span
    pub fn init(kind: StatementKind, span: Span) Statement {
        return .{ .kind = kind, .span = span };
    }

    /// Check if this is a binding statement
    pub fn isBinding(self: Statement) bool {
        return switch (self.kind) {
            .let_binding, .var_binding => true,
            else => false,
        };
    }

    /// Check if this is a control flow statement
    pub fn isControlFlow(self: Statement) bool {
        return switch (self.kind) {
            .if_statement, .for_loop, .match_statement, .return_statement, .break_statement => true,
            else => false,
        };
    }
};

test "statement kinds" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    // Test return statement
    const ret_stmt = Statement.init(.{ .return_statement = .{ .value = null } }, span);
    try std.testing.expect(ret_stmt.isControlFlow());
    try std.testing.expect(!ret_stmt.isBinding());

    // Test break statement
    const break_stmt = Statement.init(.{ .break_statement = .{ .label = null, .value = null } }, span);
    try std.testing.expect(break_stmt.isControlFlow());
}
